import Foundation
import Darwin

protocol AGYCommandRunning {
    func run() async throws -> Data
}

struct AGYCLICommandRunner: AGYCommandRunning {
    let executableURL: URL?
    let timeout: TimeInterval

    init(executableURL: URL? = nil, timeout: TimeInterval = 20) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func run() async throws -> Data {
        try await Task.detached(priority: .utility) { try runSynchronously() }.value
    }

    private func runSynchronously() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let settings = try? Data(contentsOf: settingsURL),
                  let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else {
                throw ExternalProviderError.invalidResponse
            }
            if object["disableSlashCommands"] as? Bool == true {
                // Otherwise /usage could be sent to a model as an ordinary prompt.
                throw ExternalProviderError.unsupported
            }
        }
        guard let executable = executableURL ?? Self.findCLI() else { throw ExternalProviderError.cliUnavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw ExternalProviderError.cliUnavailable }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()

        let lock = NSLock()
        var timedOut = false
        let timeoutWork = DispatchWorkItem {
            lock.lock(); timedOut = true; lock.unlock()
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        let group = DispatchGroup()
        var output: Data?
        var diagnostics: Data?
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            output = Self.readLimited(stdout.fileHandleForReading, process: process)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            diagnostics = Self.readLimited(stderr.fileHandleForReading, process: process)
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        timeoutWork.cancel()
        lock.lock(); let expired = timedOut; lock.unlock()
        if expired { throw ExternalProviderError.timeout }
        guard let output, let diagnostics else { throw ExternalProviderError.invalidResponse }
        if process.terminationStatus != 0 {
            let lower = String(decoding: diagnostics, as: UTF8.self).lowercased()
            if lower.contains("authentication required") || lower.contains("sign in") || lower.contains("login") {
                throw ExternalProviderError.cliAuthenticationRequired
            }
            throw ExternalProviderError.connection
        }
        return output
    }

    private static func readLimited(_ handle: FileHandle, process: Process) -> Data? {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count + chunk.count <= 2_000_000 else {
                if process.isRunning { process.terminate() }
                return nil
            }
            data.append(chunk)
        }
        return data
    }

    private static func findCLI() -> URL? {
        let paths = ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/agy" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}

struct AGYDirectUsageProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    let runner: any AGYCommandRunning
    let now: () -> Date

    init(runner: any AGYCommandRunning = AGYCLICommandRunner(), now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.now = now
    }

    func fetch() async throws -> ExternalUsageSnapshot {
        try AGYDirectUsageParser.parse(await runner.run(), fetchedAt: now())
    }
}

struct AGYCombinedProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    let direct: any ExternalUsageProvider
    let statusLine: any ExternalUsageProvider

    init(direct: any ExternalUsageProvider = AGYDirectUsageProvider(),
         statusLine: any ExternalUsageProvider = AGYStatusLineProvider()) {
        self.direct = direct
        self.statusLine = statusLine
    }

    func fetch() async throws -> ExternalUsageSnapshot {
        var directResult: ExternalUsageSnapshot?
        var directError: Error?
        do { directResult = try await direct.fetch() }
        catch { directError = error }
        let feedResult = try? await statusLine.fetch()
        if var directResult {
            if let feedResult { directResult.sourceTimes[.statusLine] = feedResult.fetchedAt }
            return directResult
        }
        if var feedResult {
            feedResult.sourceTimes[.statusLine] = feedResult.fetchedAt
            return feedResult
        }
        throw directError ?? ExternalProviderError.noData
    }

    func storedQuotaRecord() -> [QuotaMetric]? { statusLine.storedQuotaRecord() }
}

enum AGYDirectUsageParser {
    private static let knownWeeklyIDs: Set<String> = ["3p-weekly", "gemini-weekly"]

    static func parse(_ data: Data, fetchedAt: Date) throws -> ExternalUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "SUCCESS",
              root["num_turns"] as? Int == 0,
              let usage = root["usage"] as? [String: Any],
              ["input_tokens", "output_tokens", "thinking_tokens", "cache_read_tokens", "total_tokens"]
                .allSatisfy({ (usage[$0] as? Int) == 0 }),
              let command = root["command"] as? [String: Any],
              command["name"] is String,
              let payload = command["data"] as? [String: Any] else {
            throw ExternalProviderError.invalidResponse
        }
        let groups = payload.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
        guard !groups.isEmpty else { throw ExternalProviderError.noData }
        var quotas: [String: QuotaMetric] = [:]
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                let candidates = [bucket["id"] as? String, bucket["name"] as? String].compactMap { $0 }
                guard let identifier = candidates.first(where: { knownWeeklyIDs.contains($0) }) else { continue }
                guard quotas[identifier] == nil,
                      bucket["window"] is String,
                      let fraction = bucket["remaining_fraction"] as? Double,
                      fraction.isFinite, (0...1).contains(fraction),
                      let resetText = bucket["reset_time"] as? String,
                      let reset = parseReset(resetText) else {
                    throw ExternalProviderError.invalidResponse
                }
                quotas[identifier] = QuotaMetric(name: identifier, remainingPercent: fraction * 100, resetsAt: reset)
            }
        }
        guard !quotas.isEmpty else { throw ExternalProviderError.noData }
        return ExternalUsageSnapshot(metrics: .quotas(quotas.values.sorted { $0.name < $1.name }),
                                     fetchedAt: fetchedAt, source: .directCLI,
                                     sourceTimes: [.directCLI: fetchedAt])
    }

    private static func parseReset(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
