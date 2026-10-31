import Darwin
import Foundation

/// Explicitly constructed only by a future opt-in integration. The app's default Claude
/// provider still reads statusLine and never creates this runner.
protocol ClaudeProcessExecuting {
    func execute() async throws -> Data
}

actor ClaudeSDKProcessRunner: ClaudeUsageRunning {
    private let executor: any ClaudeProcessExecuting
    private var inFlight = false

    init(executor: any ClaudeProcessExecuting) { self.executor = executor }

    func getUsage() async throws -> Data {
        guard !inFlight else { throw ClaudeUsageRunnerError.inProgress }
        inFlight = true
        defer { inFlight = false }
        return try await executor.execute()
    }
}

struct ClaudeSubprocessExecutor: ClaudeProcessExecuting {
    let runtimeURL: URL
    let helperURL: URL
    let cliURL: URL
    let timeout: TimeInterval
    let maxOutputBytes: Int
    let environment: [String: String]

    init(runtimeURL: URL, helperURL: URL, cliURL: URL,
         timeout: TimeInterval = 30, maxOutputBytes: Int = 16_384,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runtimeURL = runtimeURL
        self.helperURL = helperURL
        self.cliURL = cliURL
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.environment = environment
    }

    func execute() async throws -> Data {
        let control = ClaudeProcessControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try run(control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    private func run(_ control: ClaudeProcessControl) throws -> Data {
        guard timeout > 0, maxOutputBytes > 0,
              [runtimeURL, helperURL, cliURL].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") &&
                  FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ClaudeUsageRunnerError.unavailable
        }
        if control.reason != nil { throw CancellationError() }

        var stdoutPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else { throw ClaudeUsageRunnerError.transport }
        defer { close(stdoutPipe[0]) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[1])
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        defer { posix_spawnattr_destroy(&attributes) }

        let args = [runtimeURL.path, helperURL.path, cliURL.path].map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        var environment = self.environment
        for key in ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "ANTHROPIC_API_KEY",
                    "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "NODE_OPTIONS", "NODE_PATH"] { environment.removeValue(forKey: key) }
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, runtimeURL.path, &actions, &attributes, args, env)
        close(stdoutPipe[1])
        guard spawned == 0 else { throw ClaudeUsageRunnerError.unavailable }
        control.register(pid)
        let timer = DispatchWorkItem { control.stop(.timeout) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = read(stdoutPipe[0], &buffer, buffer.count)
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                control.stop(.transport)
                break
            }
            if output.count + readCount > maxOutputBytes {
                control.stop(.unsafeOutput)
                break
            }
            output.append(contentsOf: buffer[..<readCount])
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        timer.cancel()
        kill(-pid, SIGKILL) // Clean up any SDK child left in this dedicated process group.
        let reason = control.finish()
        switch reason {
        case .cancelled: throw CancellationError()
        case .timeout: throw ClaudeUsageRunnerError.timeout
        case .unsafeOutput: throw ClaudeUsageRunnerError.unsafeOutput
        case .transport: throw ClaudeUsageRunnerError.transport
        case nil: break
        }
        guard status & 0x7f == 0 else { throw ClaudeUsageRunnerError.transport }
        switch (status >> 8) & 0xff {
        case 0: return output
        case 20: throw ClaudeUsageRunnerError.unavailable
        case 22: throw ClaudeUsageRunnerError.sdkFailure
        case 23: throw ClaudeUsageRunnerError.incompatibleSDK
        case 24: throw ClaudeUsageRunnerError.authenticationRequired
        case 25: throw ClaudeUsageRunnerError.permissionDenied
        case 26: throw ClaudeUsageRunnerError.rateLimited
        default: throw ClaudeUsageRunnerError.transport
        }
    }
}

private final class ClaudeProcessControl: @unchecked Sendable {
    enum Reason { case cancelled, timeout, unsafeOutput, transport }
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopped: Reason?

    var reason: Reason? { lock.lock(); defer { lock.unlock() }; return stopped }
    func register(_ value: pid_t) {
        lock.lock(); pid = value; let shouldKill = stopped != nil; lock.unlock()
        if shouldKill { kill(-value, SIGKILL) }
    }
    func stop(_ reason: Reason) {
        lock.lock()
        if stopped == nil { stopped = reason }
        let group = pid
        lock.unlock()
        if group > 0 { kill(-group, SIGKILL) }
    }
    func finish() -> Reason? {
        lock.lock(); defer { lock.unlock() }
        pid = 0
        return stopped
    }
}
