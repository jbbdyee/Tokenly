import Foundation

/// Product wiring. This never reads credentials or invokes the CLI during setup.
/// An incomplete bundle or missing executable leaves Claude on the existing statusLine feed.
enum ClaudeProductConfiguration {
    static let successInterval: TimeInterval = 60

    static func cliCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent(".local/bin/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
         URL(fileURLWithPath: "/usr/local/bin/claude")]
    }

    static func makeProvider(bundleURL: URL = Bundle.main.bundleURL,
                             candidates: [URL] = cliCandidates(),
                             statusLine: any ExternalUsageProvider = ClaudeSubscriptionProvider(),
                             now: @escaping () -> Date = Date.init,
                             supportDirectory: URL? = FileManager.default.urls(
                                for: .applicationSupportDirectory, in: .userDomainMask).first,
                             checkpointNamespace: String = Bundle.main.bundleIdentifier ?? "Tokenly",
                             environment: [String: String] = ProcessInfo.processInfo.environment)
        -> ClaudeOptionalUsageProvider? {
        guard let supportDirectory,
              checkpointNamespace.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        let checkpointDirectory = supportDirectory.appendingPathComponent(checkpointNamespace,
            isDirectory: true).appendingPathComponent("Claude Direct Refresh",
                                                                         isDirectory: true)
        guard let executor = candidates.lazy.compactMap({ ClaudeBundledRuntime.executor(
            bundleURL: bundleURL, cliURL: $0, environment: environment) }).first else { return nil }
        do {
            try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let direct = ClaudeDirectUsageProvider(runner: ClaudeSDKProcessRunner(executor: executor), now: now)
        return ClaudeOptionalUsageProvider(statusLine: statusLine,
            route: .experimentalDirect(provider: direct, maxAge: 900), now: now,
            gate: ClaudeDirectRefreshGate(pauseOnUnknownError: true, successInterval: successInterval,
                checkpointURL: checkpointDirectory.appendingPathComponent("refresh-checkpoint.json")))
    }
}
