import Foundation

struct CodexUsageProvider: UsageProvider {
    let name = "Codex"
    private let executableURL: URL?
    private let timeout: TimeInterval

    init(executableURL: URL? = nil, timeout: TimeInterval = 20) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func fetch() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            try fetchSynchronously()
        }.value
    }

    private func fetchSynchronously() throws -> UsageSnapshot {
        guard let executable = executableURL ?? Self.findCLI() else {
            throw UsageProviderError.cliUnavailable
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never log raw account or diagnostic output.

        do { try process.run() }
        catch { throw UsageProviderError.cliUnavailable }

        let deadline = Date().addingTimeInterval(timeout)
        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        defer {
            timeoutWork.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        var reader = JSONLineReader(handle: output.fileHandleForReading)
        try send(["method": "initialize", "id": 1,
                  "params": ["clientInfo": ["name": "tokenly", "title": "Tokenly", "version": "0.1.0"]]],
                 to: input.fileHandleForWriting)
        let initialized = try readResponse(id: 1, from: &reader, deadline: deadline)
        guard initialized["error"] == nil else { throw UsageProviderError.requestFailed }

        try send(["method": "initialized"], to: input.fileHandleForWriting)
        try send(["method": "account/rateLimits/read", "id": 2], to: input.fileHandleForWriting)
        let response = try readResponse(id: 2, from: &reader, deadline: deadline)
        guard response["error"] == nil else { throw UsageProviderError.requestFailed }
        let data = try JSONSerialization.data(withJSONObject: response)
        return try CodexRateLimitParser.parse(data)
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch { throw UsageProviderError.connection }
    }

    private func readResponse(id: Int, from reader: inout JSONLineReader,
                              deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            guard let line = try reader.nextLine() else {
                throw Date() >= deadline ? UsageProviderError.timeout : UsageProviderError.connection
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            if object["id"] as? Int == id { return object }
        }
        throw UsageProviderError.timeout
    }

    static func findCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // Finder-launched apps often have a minimal PATH. Search common user installs too.
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin"]
        for directory in paths + fallback {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("codex").path
            if isExecutable(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

private struct JSONLineReader {
    let handle: FileHandle
    private var buffer = Data()

    mutating func nextLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                return Data(line)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            if buffer.count > 2_000_000 { throw UsageProviderError.invalidResponse }
        }
    }
}

enum CodexRateLimitParser {
    static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw UsageProviderError.invalidResponse }
        guard envelope.error == nil, let result = envelope.result else {
            throw UsageProviderError.requestFailed
        }
        let bucket = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        let resetCredits = result.rateLimitResetCredits.flatMap { summary -> RateLimitResetCredits? in
            guard let count = summary.availableCount, count >= 0 else { return nil }
            let credits = summary.credits.map { rows in
                rows.compactMap { row -> RateLimitResetCredit? in
                    // Only Codex rate-limit resets belong in the Codex section.
                    guard row.resetType == nil || row.resetType == "codexRateLimits" else { return nil }
                    return RateLimitResetCredit(
                        expiresAt: row.expiresAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                        status: RateLimitResetCredit.Status(rawValue: row.status ?? "") ?? .unknown,
                        title: row.title)
                }
            }
            return RateLimitResetCredits(availableCount: count, credits: credits)
        }
        guard let bucket else {
            return UsageSnapshot(providerName: "Codex", windows: [], fetchedAt: fetchedAt, resetCredits: resetCredits)
        }
        let windows = [bucket.primary, bucket.secondary].compactMap { window -> UsageWindow? in
            guard let window,
                  let kind = UsageWindowKind.allCases.first(where: { $0.durationMinutes == window.windowDurationMins }),
                  let used = window.usedPercent, used.isFinite, (0...100).contains(used) else { return nil }
            let reset = window.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return UsageWindow(kind: kind, usedPercent: used, resetsAt: reset)
        }
        return UsageSnapshot(providerName: "Codex", windows: windows, fetchedAt: fetchedAt, resetCredits: resetCredits)
    }

    private struct Envelope: Decodable {
        let result: Result?
        let error: RPCError?
    }
    private struct RPCError: Decodable { let code: Int? }
    private struct Result: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        let rateLimitResetCredits: ResetCreditsSummary?
    }
    /// Official app-server schema: `RateLimitResetCreditsSummary` / `RateLimitResetCredit`.
    private struct ResetCreditsSummary: Decodable {
        let availableCount: Int?
        let credits: [ResetCredit]?
    }
    private struct ResetCredit: Decodable {
        let expiresAt: Int64?
        let status: String?
        let resetType: String?
        let title: String?
    }
    private struct Bucket: Decodable {
        let limitId: String?
        let primary: Window?
        let secondary: Window?
    }
    private struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Double?
    }
}
