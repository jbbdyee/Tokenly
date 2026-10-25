import Darwin
import Foundation

/// Native replacement for `ClaudeStatusLineBridge.py` / `AGYStatusLineBridge.py`.
/// Claude Code and AGY run `Tokenly --statusline claude|agy` with their status-line JSON on stdin.
/// The bridge stores only the documented quota fields, then — if the user had a status line before
/// connecting — runs that original command with the same stdin and passes its output through.
enum StatusLineSource: String, CaseIterable {
    case claude, agy

    var quotaFileName: String { self == .claude ? "claude-quota.json" : "agy-quota.json" }
    var displayName: String { self == .claude ? "Claude Code" : "Google Antigravity CLI" }
}

/// Paths used by the bridge and the connector. `TOKENLY_HOME` replaces the home folder (tests and
/// isolated checks only); without it everything lives in the user's real home.
struct TokenlyPaths {
    let home: URL

    init(home: URL) { self.home = home }

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> TokenlyPaths {
        if let custom = environment["TOKENLY_HOME"], !custom.isEmpty {
            return TokenlyPaths(home: URL(fileURLWithPath: custom, isDirectory: true))
        }
        return TokenlyPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    var dataFolder: URL { home.appendingPathComponent("Library/Application Support/Tokenly", isDirectory: true) }
    var connectionFolder: URL { dataFolder.appendingPathComponent("statusline", isDirectory: true) }
    var backupFolder: URL { dataFolder.appendingPathComponent("backups", isDirectory: true) }
    func quotaFile(_ source: StatusLineSource) -> URL { dataFolder.appendingPathComponent(source.quotaFileName) }
    func connectionRecord(_ source: StatusLineSource) -> URL {
        connectionFolder.appendingPathComponent("\(source.rawValue).json")
    }
    func settingsFile(_ source: StatusLineSource) -> URL {
        switch source {
        case .claude: home.appendingPathComponent(".claude/settings.json")
        case .agy: home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        }
    }
}

// MARK: - Receiving (same allow-list and limits as the Python bridges)

enum StatusLineReceiver {
    static let maxInputBytes = 2_000_000

    /// Reads until EOF. Returns nil when the input exceeds the limit (the rest is not read).
    static func readInput(from handle: FileHandle) -> Data? {
        var data = Data()
        while true {
            let chunk = handle.readData(ofLength: 65_536)
            if chunk.isEmpty { return data }
            data.append(chunk)
            if data.count > maxInputBytes { return nil }
        }
    }

    struct ClaudeRecord: Encodable {
        struct Window: Encodable {
            let usedPercentage: Double
            let resetsAt: Double?
            enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(usedPercentage, forKey: .usedPercentage)
                try c.encode(resetsAt, forKey: .resetsAt)          // explicit null, like the Python bridge
            }
        }
        let capturedAt: String
        let rateLimits: [String: Window]
        enum CodingKeys: String, CodingKey { case capturedAt = "captured_at", rateLimits = "rate_limits" }
    }

    struct AGYRecord: Encodable {
        struct Bucket: Encodable {
            let remainingFraction: Double
            let resetTime: String?
            enum CodingKeys: String, CodingKey { case remainingFraction = "remaining_fraction", resetTime = "reset_time" }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(remainingFraction, forKey: .remainingFraction)
                try c.encode(resetTime, forKey: .resetTime)
            }
        }
        let capturedAt: String
        let quota: [String: Bucket]
        enum CodingKeys: String, CodingKey { case capturedAt = "captured_at", quota }
    }

    /// Returns the bytes to store, or nil when nothing should be written (invalid or unusable input).
    /// Claude: any JSON object is recorded (possibly with no windows), exactly like the Python bridge.
    /// AGY: written only when at least one valid bucket exists.
    static func record(for source: StatusLineSource, input: Data, now: Date = Date()) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: input),
              let payload = object as? [String: Any] else { return nil }
        let captured = timestamp(now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch source {
        case .claude:
            let limits = payload["rate_limits"] as? [String: Any] ?? [:]
            var windows: [String: ClaudeRecord.Window] = [:]
            for name in ["five_hour", "seven_day"] {
                guard let entry = limits[name] as? [String: Any], let used = number(entry["used_percentage"]),
                      used.isFinite, (0...100).contains(used) else { continue }
                let reset = number(entry["resets_at"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                windows[name] = ClaudeRecord.Window(usedPercentage: used, resetsAt: reset)
            }
            return try? encoder.encode(ClaudeRecord(capturedAt: captured, rateLimits: windows))
        case .agy:
            var buckets: [String: AGYRecord.Bucket] = [:]
            for (name, value) in payload["quota"] as? [String: Any] ?? [:] {
                guard let item = value as? [String: Any], let fraction = number(item["remaining_fraction"]),
                      fraction.isFinite, (0...1).contains(fraction) else { continue }
                buckets[name] = AGYRecord.Bucket(remainingFraction: fraction, resetTime: item["reset_time"] as? String)
            }
            guard !buckets.isEmpty else { return nil }
            return try? encoder.encode(AGYRecord(capturedAt: captured, quota: buckets))
        }
    }

    /// JSON numbers only. JSONSerialization also maps true/false to NSNumber; those are rejected
    /// (the Python Claude bridge rejects booleans; for AGY this is a deliberate tightening).
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - Private files (0700 folders, 0600 files, atomic replace)

enum PrivateFile {
    static func ensureFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(folder.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    /// Writes `data` to a temporary file in the destination folder and renames it over `url`.
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        var template = Array(url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tokenly-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let temp = String(cString: template)
        var ok = fchmod(fd, mode) == 0
        ok = ok && data.withUnsafeBytes { buffer in
            buffer.count == 0 || write(fd, buffer.baseAddress, buffer.count) == buffer.count
        }
        ok = ok && fsync(fd) == 0
        ok = close(fd) == 0 && ok
        guard ok, rename(temp, url.path) == 0 else {
            unlink(temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - Bridge run

enum StatusLineBridge {
    /// Set for the original command so a status line that calls Tokenly again stops at once.
    static let activeEnvironmentKey = "TOKENLY_STATUSLINE_ACTIVE"
    static let defaultTimeout: TimeInterval = 10

    struct Outcome { let output: Data; let status: Int32 }

    static func run(source: StatusLineSource, input: Data?, paths: TokenlyPaths,
                    environment: [String: String], now: Date = Date()) -> Outcome {
        // Recursion guard: we are being run by our own wrapped command. Do nothing.
        if environment[activeEnvironmentKey] != nil {
            return Outcome(output: Data("\n".utf8), status: 0)
        }
        // 1. Store first: Claude Code cancels a status line that is still running when a new update comes.
        if let input, let record = StatusLineReceiver.record(for: source, input: input, now: now) {
            if (try? PrivateFile.ensureFolder(paths.dataFolder)) != nil {
                try? PrivateFile.writeAtomically(record, to: paths.quotaFile(source))
            }
        }
        // 2. The user's original status line, if Tokenly wrapped one when connecting.
        guard let original = StatusLineConnector.originalCommand(for: source, paths: paths) else {
            return Outcome(output: Data("\n".utf8), status: 0)      // same output as the Python bridge
        }
        var childEnvironment = environment
        childEnvironment[activeEnvironmentKey] = "1"
        let timeout = environment["TOKENLY_STATUSLINE_TIMEOUT"].flatMap(TimeInterval.init)
            .map { min(max($0, 0.1), 60) } ?? defaultTimeout
        return ChildCommand.run(original, input: input ?? Data(), environment: childEnvironment, timeout: timeout)
    }
}

// MARK: - Running the original command

/// Runs `/bin/sh -c <command>` (how Claude Code runs status lines) in its own process group, feeds stdin,
/// collects stdout, enforces a timeout and kills the whole group if we are cancelled.
enum ChildCommand {
    static let timedOutStatus: Int32 = 124
    private static var activeGroup: pid_t = 0

    static func installCancellationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { received in
                let group = ChildCommand.activeGroup
                if group > 0 { kill(-group, SIGKILL) }
                _exit(128 + received)
            }
        }
    }

    static func run(_ command: String, input: Data, environment: [String: String],
                    timeout: TimeInterval) -> StatusLineBridge.Outcome {
        var stdinPipe: [Int32] = [0, 0], stdoutPipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0 else { return .init(output: Data(), status: 1) }
        guard pipe(&stdoutPipe) == 0 else {
            close(stdinPipe[0]); close(stdinPipe[1]); return .init(output: Data(), status: 1)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        for fd in stdinPipe + stdoutPipe { posix_spawn_file_actions_addclose(&actions, fd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Own process group so a timeout or cancellation reaches grandchildren too; default signal
        // handling and mask in the child (we ignore SIGPIPE ourselves).
        var defaults = sigset_t(); sigfillset(&defaults)
        var empty = sigset_t(); sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        argv.forEach { free($0) }; envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
        close(stdinPipe[0]); close(stdoutPipe[1])
        guard spawned == 0 else {
            close(stdinPipe[1]); close(stdoutPipe[0])
            return .init(output: Data(), status: 127)
        }
        activeGroup = pid

        let writer = stdinPipe[1]
        let feeding = DispatchGroup()
        feeding.enter()
        DispatchQueue.global().async {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(writer, buffer.baseAddress! + offset, buffer.count - offset)
                    if n <= 0 { break }            // child closed its stdin (SIGPIPE is ignored)
                    offset += n
                }
            }
            close(writer)
            feeding.leave()
        }
        let timedOut = Atomic()
        let timer = DispatchWorkItem { timedOut.set(); kill(-pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        let output = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        timer.cancel()
        kill(-pid, SIGKILL)            // anything the command left running in its group
        activeGroup = 0
        feeding.wait()

        if timedOut.value { return .init(output: output, status: timedOutStatus) }
        let signalNumber = status & 0x7f
        if signalNumber == 0 { return .init(output: output, status: (status >> 8) & 0xff) }
        return .init(output: output, status: 128 + signalNumber)
    }

    private final class Atomic: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
