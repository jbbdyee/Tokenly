import Foundation

/// Compiled into a separately identified development app only. No default app path creates
/// the SDK runner, and missing runtime paths leave Claude on the existing statusLine feed.
enum ClaudeDevelopmentConfiguration {
#if TOKENLY_CLAUDE_DEV
    struct DisabledCodexProvider: UsageProvider {
        let name = "Codex"
        func fetch() async throws -> UsageSnapshot { throw UsageProviderError.cliUnavailable }
    }
    static var isMock: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_MOCK"] == "1"
    }

    static var isRealOnce: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_REAL_ONCE"] == "1"
            && Bundle.main.bundleIdentifier == "io.github.jbbdyee.tokenly.clauderealone.20261031"
    }

    static var isRealTwo: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_REAL_TWO"] == "1"
            && Bundle.main.bundleIdentifier == "io.github.jbbdyee.tokenly.claudereal2.20261031"
    }

    static func recordAttempt(result: ClaudeDirectResult?, error: Error?, elapsed: TimeInterval) {
        guard isRealOnce || isRealTwo else { return }
        let code: String
        switch error as? ClaudeUsageRunnerError {
        case .authenticationRequired: code = "authentication_required"
        case .permissionDenied: code = "permission_denied"
        case .rateLimited: code = "rate_limited"
        case .timeout: code = "timeout"
        case .unavailable: code = "unavailable"
        case .incompatibleSDK: code = "incompatible_sdk"
        case .sdkFailure: code = "sdk_failure"
        case .transport: code = "transport"
        case .inProgress: code = "in_progress"
        case .unsafeOutput: code = "unsafe_output"
        case .unexpectedModelActivity: code = "unexpected_model_activity"
        case nil: code = error == nil ? "none" : "invalid_response"
        }
        let lines = ["status=\(result == nil ? "failure" : "success")",
                     "five_hour_valid=\(result?.windows[.fiveHour] != nil)",
                     "seven_day_valid=\(result?.windows[.sevenDay] != nil)",
                     "error=\(code)",
                     "elapsed_ms=\(Int((elapsed * 1000).rounded()))",
                     "completed_uptime_ms=\(Int((ProcessInfo.processInfo.systemUptime * 1000).rounded()))"]
        write(lines.joined(separator: "\n") + "\n", filename: "attempt.txt")
    }

    static func recordStore(_ snapshot: ExternalUsageSnapshot) {
        guard isRealOnce || isRealTwo else { return }
        let names: Set<String>
        if case .quotas(let quotas) = snapshot.metrics { names = Set(quotas.map(\.name)) }
        else { names = [] }
        let lines = ["source=\(snapshot.source == .directCLI ? "direct_cli" : "status_line")",
                     "five_hour_present=\(names.contains(ClaudeWindow.fiveHour.label))",
                     "seven_day_present=\(names.contains(ClaudeWindow.sevenDay.label))",
                     "direct_success_time_present=\(snapshot.sourceTimes[.directCLI] != nil)"]
        write(lines.joined(separator: "\n") + "\n", filename: "store.txt")
    }

    private static func write(_ value: String, filename: String) {
        let root = isRealTwo ? "/private/tmp/tokenly-claude-real-two-20261031"
                             : "/private/tmp/tokenly-claude-real-once-20261031"
        let url = URL(fileURLWithPath: "\(root)/\(filename)")
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(value.utf8))
        try? handle.close()
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_ENABLE"] == "1"
    }

    static func makeProvider(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> ClaudeOptionalUsageProvider {
        let statusLine: ClaudeSubscriptionProvider
        if environment["TOKENLY_CLAUDE_DEV_MOCK"] == "1",
           let path = environment["TOKENLY_CLAUDE_DEV_STATUSLINE"],
           path.hasPrefix("/private/tmp/") {
            statusLine = ClaudeSubscriptionProvider(fileURL: URL(fileURLWithPath: path))
        } else {
            statusLine = ClaudeSubscriptionProvider()
        }
        guard environment["TOKENLY_CLAUDE_DEV_ENABLE"] == "1",
              let node = environment["TOKENLY_CLAUDE_DEV_NODE"],
              let helper = environment["TOKENLY_CLAUDE_DEV_HELPER"],
              let cli = environment["TOKENLY_CLAUDE_DEV_CLI"],
              [node, helper, cli].allSatisfy({ $0.hasPrefix("/") }) else {
            return ClaudeOptionalUsageProvider(statusLine: statusLine)
        }
        if environment["TOKENLY_CLAUDE_DEV_MOCK"] == "1" {
            guard node == "/bin/sh", cli == "/usr/bin/true",
                  helper.hasPrefix("/private/tmp/tokenly-claude-dev-mock-"),
                  environment["TOKENLY_CLAUDE_DEV_STATUSLINE"]?.hasPrefix("/private/tmp/") == true else {
                return ClaudeOptionalUsageProvider(statusLine: statusLine)
            }
        } else if !isRealOnce && !isRealTwo {
            return ClaudeOptionalUsageProvider(statusLine: statusLine)
        }
        let executor = ClaudeSubprocessExecutor(runtimeURL: URL(fileURLWithPath: node),
                                               helperURL: URL(fileURLWithPath: helper),
                                               cliURL: URL(fileURLWithPath: cli))
        let direct = ClaudeDirectUsageProvider(runner: ClaudeSDKProcessRunner(executor: executor))
        return ClaudeOptionalUsageProvider(statusLine: statusLine,
            route: .experimentalDirect(provider: direct, maxAge: 900),
            gate: ClaudeDirectRefreshGate(maxAttempts: isRealOnce ? 1 : isRealTwo ? 2 : nil,
                                          stopOnFailure: isRealTwo,
                                          reservationDirectory: isRealTwo
                                              ? URL(fileURLWithPath: "/private/tmp/tokenly-claude-real-two-20261031")
                                              : nil))
    }
#else
    static let isEnabled = false
#endif
}
