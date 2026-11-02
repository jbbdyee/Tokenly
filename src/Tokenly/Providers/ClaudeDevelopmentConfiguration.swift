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

    static let mockSixtyBundleID = "io.github.jbbdyee.tokenly.claudemock60.20261101"
    static var isMockSixty: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_MOCK_SIXTY"] == "1"
            && isMock && Bundle.main.bundleIdentifier == mockSixtyBundleID
    }

    static var isRealOnce: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_REAL_ONCE"] == "1"
            && Bundle.main.bundleIdentifier == "io.github.jbbdyee.tokenly.clauderealone.20261101"
    }

    static var isRealTwo: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_REAL_TWO"] == "1"
            && Bundle.main.bundleIdentifier == "io.github.jbbdyee.tokenly.claudereal2.20261101"
    }

    static var isRealSixty: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_REAL_SIXTY"] == "1"
            && Bundle.main.bundleIdentifier == "io.github.jbbdyee.tokenly.claudereal60.20261101"
    }

    static let realThreeBundleID = "io.github.jbbdyee.tokenly.claudereal3.20261102"
    static var isRealThree: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_REAL_THREE"] == "1"
            && Bundle.main.bundleIdentifier == realThreeBundleID
    }

    static var isBundledDevelopment: Bool {
        bundledRouteAllowed(environment: ProcessInfo.processInfo.environment,
                            bundleID: Bundle.main.bundleIdentifier)
    }

    static let portableBundleID = "io.github.jbbdyee.tokenly.claudebundle.20261101"

    static func bundledRouteAllowed(environment: [String: String], bundleID: String?) -> Bool {
        bundleID == portableBundleID && environment["TOKENLY_CLAUDE_DEV_BUNDLED_ENABLE"] == "1"
            && environment["TOKENLY_CLAUDE_DEV_MOCK"] != "1"
    }

    /// 60 seconds is a guarded development trial, never an implicit production default.
    static func refreshInterval(selected: Int, bundleID: String?,
                                environment: [String: String]) -> TimeInterval {
        if bundleID == mockSixtyBundleID,
           environment["TOKENLY_CLAUDE_DEV_MOCK"] == "1",
           environment["TOKENLY_CLAUDE_DEV_MOCK_SIXTY"] == "1" { return 60 }
        if bundleID == realThreeBundleID,
           environment["TOKENLY_CLAUDE_DEV_REAL_THREE"] == "1" { return 60 }
        guard bundleID == portableBundleID, selected == 60,
              environment["TOKENLY_CLAUDE_DEV_MOCK"] == "1" ||
              environment["TOKENLY_CLAUDE_DEV_ALLOW_60"] == "1" else { return 300 }
        return 60
    }

    static func recordAttempt(result: ClaudeDirectResult?, error: Error?, elapsed: TimeInterval) {
        guard isRealOnce || isRealTwo || isRealSixty || isRealThree else { return }
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
        guard isRealOnce || isRealTwo || isRealSixty || isRealThree else { return }
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
        let root = isRealThree ? "/private/tmp/tokenly-claude-real-three-20261102"
            : isRealSixty ? "/private/tmp/tokenly-claude-real-sixty-20261101"
            : isRealTwo ? "/private/tmp/tokenly-claude-real-two-20261101"
                        : "/private/tmp/tokenly-claude-real-once-20261101"
        let url = URL(fileURLWithPath: "\(root)/\(filename)")
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(value.utf8))
        try? handle.close()
    }

    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TOKENLY_CLAUDE_DEV_ENABLE"] == "1" else { return false }
        if isBundledDevelopment {
            guard let cli = environment["TOKENLY_CLAUDE_DEV_CLI"], cli.hasPrefix("/") else {
                return false
            }
            return ClaudeBundledRuntime.executor(bundleURL: Bundle.main.bundleURL,
                cliURL: URL(fileURLWithPath: cli), environment: environment) != nil
        }
        return true
    }

    static func makeProvider(environment: [String: String] = ProcessInfo.processInfo.environment,
                             refreshInterval: TimeInterval = 300)
        -> ClaudeOptionalUsageProvider {
        let statusLine: ClaudeSubscriptionProvider
        if environment["TOKENLY_CLAUDE_DEV_MOCK"] == "1",
           let path = environment["TOKENLY_CLAUDE_DEV_STATUSLINE"],
           path.hasPrefix("/private/tmp/") {
            statusLine = ClaudeSubscriptionProvider(fileURL: URL(fileURLWithPath: path))
        } else {
            statusLine = ClaudeSubscriptionProvider()
        }
        if environment["TOKENLY_CLAUDE_DEV_ENABLE"] == "1", isBundledDevelopment {
            guard let cli = environment["TOKENLY_CLAUDE_DEV_CLI"], cli.hasPrefix("/"),
                  let executor = ClaudeBundledRuntime.executor(
                    bundleURL: Bundle.main.bundleURL, cliURL: URL(fileURLWithPath: cli),
                    environment: environment),
                  let bundleID = Bundle.main.bundleIdentifier,
                  let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
                return ClaudeOptionalUsageProvider(statusLine: statusLine)
            }
            let directory = support.appendingPathComponent("Tokenly Claude Experiment", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true)
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700]) }
            catch { return ClaudeOptionalUsageProvider(statusLine: statusLine) }
            let direct = ClaudeDirectUsageProvider(runner: ClaudeSDKProcessRunner(executor: executor))
            let limitedSixty = refreshInterval == 60
            return ClaudeOptionalUsageProvider(statusLine: statusLine,
                route: .experimentalDirect(provider: direct, maxAge: 900),
                gate: ClaudeDirectRefreshGate(maxAttempts: limitedSixty ? 2 : nil,
                    successInterval: refreshInterval,
                    reservationDirectory: limitedSixty ? directory : nil,
                    checkpointURL: directory.appendingPathComponent("refresh-checkpoint.json")))
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
        } else if !isRealOnce && !isRealTwo && !isRealSixty && !isRealThree {
            return ClaudeOptionalUsageProvider(statusLine: statusLine)
        }
        let executor = ClaudeSubprocessExecutor(runtimeURL: URL(fileURLWithPath: node),
                                               helperURL: URL(fileURLWithPath: helper),
                                               cliURL: URL(fileURLWithPath: cli))
        let direct = ClaudeDirectUsageProvider(runner: ClaudeSDKProcessRunner(executor: executor))
        if isMockSixty {
            guard let root = environment["TOKENLY_CLAUDE_DEV_MOCK_SIXTY_ROOT"],
                  root.hasPrefix("/private/tmp/tokenly-claude-dev-mock-sixty-") else {
                return ClaudeOptionalUsageProvider(statusLine: statusLine)
            }
            let directory = URL(fileURLWithPath: root)
            guard (try? FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
                return ClaudeOptionalUsageProvider(statusLine: statusLine)
            }
            return ClaudeOptionalUsageProvider(statusLine: statusLine,
                route: .experimentalDirect(provider: direct, maxAge: 900),
                gate: ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
                    successInterval: 60, reservationDirectory: directory,
                    checkpointURL: directory.appendingPathComponent("refresh-checkpoint.json")))
        }
        let reservationDirectory: URL? = isRealThree
            ? URL(fileURLWithPath: "/private/tmp/tokenly-claude-real-three-20261102")
            : isRealOnce
            ? URL(fileURLWithPath: "/private/tmp/tokenly-claude-real-once-20261101")
            : isRealTwo
                ? URL(fileURLWithPath: "/private/tmp/tokenly-claude-real-two-20261101")
                : isRealSixty
                    ? URL(fileURLWithPath: "/private/tmp/tokenly-claude-real-sixty-20261101")
                    : nil
        let checkpointURL: URL?
        if reservationDirectory != nil {
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
                return ClaudeOptionalUsageProvider(statusLine: statusLine)
            }
            let directory = support.appendingPathComponent("Tokenly Claude Experiment", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            checkpointURL = directory.appendingPathComponent("refresh-checkpoint.json")
        } else {
            checkpointURL = nil
        }
        return ClaudeOptionalUsageProvider(statusLine: statusLine,
            route: .experimentalDirect(provider: direct, maxAge: 900),
            gate: ClaudeDirectRefreshGate(maxAttempts: isRealThree ? 3 : isRealOnce ? 1 : isRealTwo || isRealSixty ? 2 : nil,
                                          stopOnFailure: isRealTwo || isRealSixty || isRealThree,
                                          successInterval: isRealSixty || isRealThree ? 60 : refreshInterval,
                                          reservationDirectory: reservationDirectory,
                                          checkpointURL: checkpointURL))
    }
#else
    static let isEnabled = false
#endif
}
