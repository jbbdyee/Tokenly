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
        }
        let executor = ClaudeSubprocessExecutor(runtimeURL: URL(fileURLWithPath: node),
                                               helperURL: URL(fileURLWithPath: helper),
                                               cliURL: URL(fileURLWithPath: cli))
        let direct = ClaudeDirectUsageProvider(runner: ClaudeSDKProcessRunner(executor: executor))
        return ClaudeOptionalUsageProvider(statusLine: statusLine,
            route: .experimentalDirect(provider: direct, maxAge: 900))
    }
#else
    static let isEnabled = false
#endif
}
