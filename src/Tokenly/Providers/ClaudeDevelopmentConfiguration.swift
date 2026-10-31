import Foundation

/// Compiled into a separately identified development app only. No default app path creates
/// the SDK runner, and missing runtime paths leave Claude on the existing statusLine feed.
enum ClaudeDevelopmentConfiguration {
#if TOKENLY_CLAUDE_DEV
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TOKENLY_CLAUDE_DEV_ENABLE"] == "1"
    }

    static func makeProvider(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> ClaudeOptionalUsageProvider {
        guard environment["TOKENLY_CLAUDE_DEV_ENABLE"] == "1",
              let node = environment["TOKENLY_CLAUDE_DEV_NODE"],
              let helper = environment["TOKENLY_CLAUDE_DEV_HELPER"],
              let cli = environment["TOKENLY_CLAUDE_DEV_CLI"],
              [node, helper, cli].allSatisfy({ $0.hasPrefix("/") }) else {
            return ClaudeOptionalUsageProvider()
        }
        let executor = ClaudeSubprocessExecutor(runtimeURL: URL(fileURLWithPath: node),
                                               helperURL: URL(fileURLWithPath: helper),
                                               cliURL: URL(fileURLWithPath: cli))
        let direct = ClaudeDirectUsageProvider(runner: ClaudeSDKProcessRunner(executor: executor))
        return ClaudeOptionalUsageProvider(route: .experimentalDirect(provider: direct, maxAge: 900))
    }
#else
    static let isEnabled = false
#endif
}
