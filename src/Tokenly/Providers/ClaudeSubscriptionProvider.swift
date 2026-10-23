import Foundation

struct ClaudeSubscriptionProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .claude
    let fileURL: URL
    let now: () -> Date

    init(fileURL: URL = Self.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tokenly/claude-quota.json")
    }

    var hasFeed: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    func fetch() async throws -> ExternalUsageSnapshot {
        guard hasFeed else { throw ExternalProviderError.setupRequired }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw ExternalProviderError.connection }
        return try ClaudeQuotaParser.parse(data, now: now())
    }

    func storedQuotaRecord() -> [QuotaMetric]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return ClaudeQuotaParser.storedRecord(data)
    }
}

enum ClaudeQuotaParser {
    static func parse(_ data: Data, now: Date, maxAge: TimeInterval = 900) throws -> ExternalUsageSnapshot {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw ExternalProviderError.invalidResponse }
        guard let captured = ISO8601DateFormatter().date(from: payload.capturedAt),
              captured <= now.addingTimeInterval(60),
              now.timeIntervalSince(captured) <= maxAge else { throw ExternalProviderError.claudeStaleData }
        let names = [("five_hour", "5시간 한도"), ("seven_day", "7일 한도")]
        let quotas = names.compactMap { key, label -> QuotaMetric? in
            guard let window = payload.rateLimits[key],
                  let used = window.usedPercentage, used.isFinite,
                  (0...100).contains(used) else { return nil }
            let reset = window.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            // A window that already reset is not a current quota.
            if let reset, reset <= now { return nil }
            return QuotaMetric(name: label, remainingPercent: 100 - used, resetsAt: reset)
        }
        guard !quotas.isEmpty else { throw ExternalProviderError.noData }
        return ExternalUsageSnapshot(metrics: .quotas(quotas), fetchedAt: captured)
    }

    /// Valid windows in a received file regardless of age or reset, used only as "previously received" evidence.
    static func storedRecord(_ data: Data) -> [QuotaMetric]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              ISO8601DateFormatter().date(from: payload.capturedAt) != nil else { return nil }
        let quotas = [("five_hour", "5시간 한도"), ("seven_day", "7일 한도")].compactMap { key, label -> QuotaMetric? in
            guard let used = payload.rateLimits[key]?.usedPercentage, used.isFinite, (0...100).contains(used) else { return nil }
            return QuotaMetric(name: label, remainingPercent: 100 - used, resetsAt: nil)
        }
        return quotas.isEmpty ? nil : quotas
    }

    private struct Payload: Decodable {
        let capturedAt: String
        let rateLimits: [String: Window]
        enum CodingKeys: String, CodingKey { case capturedAt = "captured_at", rateLimits = "rate_limits" }
    }
    private struct Window: Decodable {
        let usedPercentage: Double?
        let resetsAt: Double?
        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }
    }
}
