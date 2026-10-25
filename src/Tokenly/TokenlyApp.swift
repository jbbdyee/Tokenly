import SwiftUI

/// Started by `TokenlyMain` (the process entry point) when no command-line mode was requested.
struct TokenlyApp: App {
    @StateObject private var store = UsageStore(provider: CodexUsageProvider())
    @StateObject private var loginItem = LoginItemManager()
    @StateObject private var displaySettings: ProviderDisplaySettings
    @StateObject private var externalStore: ExternalProviderStore
    private let settingsWindow = SettingsWindowManager()

    init() {
        let display = ProviderDisplaySettings()
        _displaySettings = StateObject(wrappedValue: display)
        _externalStore = StateObject(wrappedValue: ExternalProviderStore(displaySettings: display))
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(store: store, externalStore: externalStore,
                          displaySettings: displaySettings, settingsWindow: settingsWindow)
                .onAppear { store.start(); externalStore.start() }
                .preferredColorScheme(displaySettings.appearance.colorScheme)
        } label: {
            let label = MenuBarPresentation.text(style: displaySettings.menuBarStyle,
                                                 snapshot: store.snapshot,
                                                 isRefreshing: store.isRefreshing,
                                                 hasError: store.errorMessage != nil)
            if displaySettings.menuBarStyle == .bear {
                MenuBarBearLabel(readings: HeartGauge.readings(store: store, externalStore: externalStore,
                                                               settings: displaySettings))
                    .onAppear { store.start(); externalStore.start() }
            } else if displaySettings.menuBarStyle == .numeric {
                MenuBarNumericLabel(items: NumericGauge.items(store: store, externalStore: externalStore,
                                                              settings: displaySettings),
                                    fallback: label)
                    // Claude/AGY values are needed before the popover is first opened.
                    .onAppear { store.start(); externalStore.start() }
            } else {
                Text(label)
                    .monospacedDigit()
                    .accessibilityLabel("Tokenly, \(label)")
                    .onAppear { store.start() }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            TokenlySettingsView(loginItem: loginItem, displaySettings: displaySettings,
                                externalStore: externalStore, usageStore: store)
                .background(SettingsWindowCapture(manager: settingsWindow))
                .preferredColorScheme(displaySettings.appearance.colorScheme)
        }
    }
}

enum MenuBarPresentation {
    static func text(style: MenuBarDisplayStyle, snapshot: UsageSnapshot?,
                     isRefreshing: Bool, hasError: Bool) -> String {
        guard let snapshot, let full = snapshot.menuBarSummary else {
            if isRefreshing { return "조회 중" }
            return hasError ? "조회 실패" : "데이터 없음"
        }
        let value: String
        switch style {
        case .numeric, .bear:
            value = full
        case .compact:
            value = UsageWindowKind.allCases.map { kind in
                snapshot.window(kind).map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
            }.joined(separator: " · ")
        }
        return hasError ? "이전 · \(value)" : value
    }
}

/// Bear style label. Uses the shared HeartGauge readings and hiding rules; names follow the menu bar's
/// own appearance (the label's colorScheme), not the app theme, which only applies to the popover.
struct MenuBarBearLabel: View {
    let readings: [(provider: HeartGaugeProvider, reading: HeartGaugeReading)]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if readings.isEmpty {
            Image(systemName: "heart")
                .accessibilityLabel("Tokenly, 표시할 곰돌이 없음")
        } else {
            let items = readings.map {
                MenuBarBearItem(percent: $0.reading.percent, name: $0.provider.shortTitle,
                                service: BearAssets.service(for: $0.provider, stale: $0.reading.isStale))
            }
            Group {
                if let image = MenuBarBearImage.make(items, dark: colorScheme == .dark) {
                    Image(nsImage: image)
                } else {
                    Text(readings.map { "\($0.provider.shortTitle) \($0.reading.percentText)" }.joined(separator: " "))
                }
            }
            .accessibilityLabel("Tokenly, " + readings.map { $0.reading.accessibilityText(for: $0.provider) }
                .joined(separator: ", "))
        }
    }
}

/// Numeric style: per service, the 5-hour remaining large and high, the 7-day remaining 20% smaller and
/// 1.5pt lower, the name underneath; black or white for the menu bar's own appearance. With nothing to
/// show (loading, no data, failure), it keeps the previous text label and its states.
struct MenuBarNumericLabel: View {
    let items: [NumericGaugeItem]
    let fallback: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !items.isEmpty, let image = MenuBarNumericImage.make(items, dark: colorScheme == .dark) {
            Image(nsImage: image)
                .accessibilityLabel("Tokenly, " + items.map(\.accessibilityText).joined(separator: ", "))
        } else {
            Text(fallback)
                .monospacedDigit()
                .accessibilityLabel("Tokenly, \(fallback)")
        }
    }
}
