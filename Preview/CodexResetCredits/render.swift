// Renders the app's real popover (UsageMenuView) with a stubbed Codex response holding two reset
// credits, Codex expanded vs. collapsed. Preview-only; no network, no account. Run ./run.sh.
import AppKit
import SwiftUI

struct StubProvider: UsageProvider {
    let name = "Codex"
    func fetch() async throws -> UsageSnapshot {
        let now = Date()
        let json = """
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":\(Int(now.timeIntervalSince1970) + 9000)},
        "secondary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":\(Int(now.timeIntervalSince1970) + 400000)}},
        "rateLimitResetCredits":{"availableCount":2,"credits":[
        {"id":"x","grantedAt":1,"expiresAt":\(Int(now.timeIntervalSince1970) + 570000),"status":"available","resetType":"codexRateLimits"},
        {"id":"y","grantedAt":1,"expiresAt":\(Int(now.timeIntervalSince1970) + 1270000),"status":"available","resetType":"codexRateLimits"}]}}}
        """
        return try CodexRateLimitParser.parse(Data(json.utf8), fetchedAt: now)
    }
}

@main struct Main { @MainActor static func main() async {
    let suite = "TokenlyPreview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ProviderDisplaySettings(defaults: defaults)
    let store = UsageStore(provider: StubProvider())
    await store.refresh()?.value
    // Claude and AGY with stubbed quotas too, so all three detail sections can be checked.
    struct StubExternal: ExternalUsageProvider {
        let id: ExternalProviderID
        let quotas: [QuotaMetric]
        func fetch() async throws -> ExternalUsageSnapshot { ExternalUsageSnapshot(metrics: .quotas(quotas), fetchedAt: Date()) }
    }
    settings.showsClaude = true
    settings.showsAGY = true
    let reset = Date().addingTimeInterval(7200)
    let external = ExternalProviderStore(displaySettings: settings, providers: [
        .claude: StubExternal(id: .claude, quotas: [QuotaMetric(name: "5시간 한도", remainingPercent: 72, resetsAt: reset),
                                                    QuotaMetric(name: "7일 한도", remainingPercent: 91, resetsAt: reset.addingTimeInterval(400000))]),
        .antigravity: StubExternal(id: .antigravity, quotas: [QuotaMetric(name: "gemini-weekly", remainingPercent: 54, resetsAt: reset)])
    ])
    await external.refresh(.claude)?.value
    await external.refresh(.antigravity)?.value
    for (label, expanded) in [("expanded", true), ("collapsed", false), ("all-expanded", true)] {
        settings.codexExpanded = expanded
        settings.claudeExpanded = label == "all-expanded"
        settings.agyExpanded = label == "all-expanded"
        let view = UsageMenuView(store: store, externalStore: external, displaySettings: settings, settingsWindow: SettingsWindowManager())
            .environment(\.colorScheme, .light).background(Color.white)
        let r = ImageRenderer(content: view); r.scale = 2
        let cg = r.cgImage!
        try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("popover-codex-\(label).png"))
        print(label, "popover", CGFloat(cg.width) / 2, "x", CGFloat(cg.height) / 2, "pt")
    }
}}
