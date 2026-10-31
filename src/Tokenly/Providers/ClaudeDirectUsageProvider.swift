import CoreFoundation
import Foundation

// Intentionally no SDK process implementation in this phase. A later, reviewed adapter can
// implement this boundary without changing response validation or touching authentication here.
protocol ClaudeUsageRunning {
    func getUsage() async throws -> Data
}

enum ClaudeUsageRunnerError: Error, Equatable {
    case authenticationRequired
    case permissionDenied
    case rateLimited
    case timeout
    case unavailable
    case incompatibleSDK
    case sdkFailure
    case transport
    case inProgress
    case unsafeOutput
}

struct DisabledClaudeUsageRunner: ClaudeUsageRunning {
    func getUsage() async throws -> Data { throw ClaudeUsageRunnerError.unavailable }
}

enum ClaudeWindow: String, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    var label: String { self == .fiveHour ? "5시간 한도" : "7일 한도" }
}

struct ClaudeWindowValue: Equatable {
    let quota: QuotaMetric
    let source: ExternalUsageSource
    /// Local completion/receipt time, never presented as the server's own refresh time.
    let receivedAt: Date
}

struct ClaudeDirectResult {
    let windows: [ClaudeWindow: ClaudeWindowValue]
    let receivedAt: Date
}

struct ClaudeDirectUsageProvider {
    let runner: any ClaudeUsageRunning
    let now: () -> Date

    init(runner: any ClaudeUsageRunning = DisabledClaudeUsageRunner(), now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.now = now
    }

    func fetch() async throws -> ClaudeDirectResult {
        let data = try await runner.getUsage()
        return try ClaudeDirectUsageParser.parse(data, receivedAt: now())
    }
}

enum ClaudeDirectUsageParser {
    static func parse(_ data: Data, receivedAt: Date) throws -> ClaudeDirectResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExternalProviderError.invalidResponse
        }
        guard root["rate_limits_available"] as? Bool == true else {
            throw ExternalProviderError.noData
        }
        // `true` with a null/missing container is data unavailable, not a plan unsupported verdict.
        guard let limits = root["rate_limits"] as? [String: Any] else {
            throw ExternalProviderError.noData
        }
        var windows: [ClaudeWindow: ClaudeWindowValue] = [:]
        for window in ClaudeWindow.allCases {
            guard let raw = limits[window.rawValue] as? [String: Any],
                  let number = raw["utilization"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let utilization = number.doubleValue
            guard utilization.isFinite, (0...100).contains(utilization) else { continue }
            let reset = (raw["resets_at"] as? String).flatMap(parseReset)
            windows[window] = ClaudeWindowValue(
                quota: QuotaMetric(name: window.label, remainingPercent: 100 - utilization, resetsAt: reset),
                source: .directCLI, receivedAt: receivedAt)
        }
        guard !windows.isEmpty else { throw ExternalProviderError.noData }
        return ClaudeDirectResult(windows: windows, receivedAt: receivedAt)
    }

    private static func parseReset(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#,
                          options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Testable connection policy. Not wired to ExternalProviderStore or any timer in this phase.
struct ClaudeUsageSelection {
    private(set) var directWindows: [ClaudeWindow: ClaudeWindowValue] = [:]
    private(set) var lastDirectSuccessAt: Date?
    private(set) var lastDirectError: ClaudeUsageRunnerError?

    mutating func accept(_ result: ClaudeDirectResult) {
        directWindows.merge(result.windows) { _, incoming in incoming }
        lastDirectSuccessAt = result.receivedAt
        lastDirectError = nil
    }

    mutating func fail(_ error: ClaudeUsageRunnerError) {
        lastDirectError = error
    }

    func displayed(statusLine: ExternalUsageSnapshot?, now: Date,
                   directMaxAge: TimeInterval, statusLineMaxAge: TimeInterval = 900)
        -> [ClaudeWindow: (value: ClaudeWindowValue, stale: Bool)] {
        var statusWindows: [ClaudeWindow: ClaudeWindowValue] = [:]
        if let statusLine, case .quotas(let quotas) = statusLine.metrics {
            for window in ClaudeWindow.allCases {
                if let quota = quotas.first(where: { $0.name == window.label }) {
                    statusWindows[window] = ClaudeWindowValue(quota: quota, source: .statusLine,
                                                             receivedAt: statusLine.fetchedAt)
                }
            }
        }
        func fresh(_ value: ClaudeWindowValue?, maxAge: TimeInterval) -> Bool {
            guard let value, maxAge >= 0 else { return false }
            let age = now.timeIntervalSince(value.receivedAt)
            return age >= 0 && age <= maxAge
        }
        var selected: [ClaudeWindow: (value: ClaudeWindowValue, stale: Bool)] = [:]
        for window in ClaudeWindow.allCases {
            let direct = directWindows[window], status = statusWindows[window]
            if fresh(direct, maxAge: directMaxAge), let direct {
                selected[window] = (direct, false)
            } else if fresh(status, maxAge: statusLineMaxAge), let status {
                selected[window] = (status, false)
            } else if let last = [direct, status].compactMap({ $0 }).max(by: { $0.receivedAt < $1.receivedAt }) {
                selected[window] = (last, true)
            }
        }
        return selected
    }
}
