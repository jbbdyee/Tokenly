import AppKit
import Combine
import SwiftUI

/// Started by `TokenlyMain` (the process entry point) when no command-line mode was requested.
struct TokenlyApp: App {
    @StateObject private var store = UsageStore(provider: CodexUsageProvider())
    @StateObject private var loginItem = LoginItemManager()
    @StateObject private var displaySettings: ProviderDisplaySettings
    @StateObject private var externalStore: ExternalProviderStore
    private let settingsWindow = SettingsWindowManager()
    /// System Monitor. Only the controller is observed here (it publishes on on/off changes); the store and the
    /// process scanner it owns are observed by the system widget labels alone, so their 1 s updates never
    /// re-evaluate this body or the AI labels.
    @StateObject private var systemWidgets: SystemWidgetController
    private let systemWidgetImages = SystemWidgetImageCache()
    private let appearanceApplier: AppAppearanceApplier
    private let processIcons = ProcessIconProvider()
    private let quitMenu = MenuBarQuitMenu()

    init() {
        let display = ProviderDisplaySettings()
        _displaySettings = StateObject(wrappedValue: display)
        appearanceApplier = AppAppearanceApplier(settings: display)
        _externalStore = StateObject(wrappedValue: ExternalProviderStore(displaySettings: display))
        _systemWidgets = StateObject(wrappedValue: SystemWidgetController(store: SystemMonitorStore(),
                                                                          processTop: ProcessTopStore()))
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(store: store, externalStore: externalStore,
                          displaySettings: displaySettings, settingsWindow: settingsWindow)
                .onAppear { store.start(); store.refreshIfStale(); externalStore.start() }
        } label: {
            let label = MenuBarPresentation.text(style: displaySettings.menuBarStyle,
                                                 snapshot: store.snapshot,
                                                 isRefreshing: store.isRefreshing,
                                                 hasError: store.errorMessage != nil)
            if displaySettings.menuBarStyle == .numeric {
                MenuBarNumericLabel(items: NumericGauge.items(store: store, externalStore: externalStore,
                                                              settings: displaySettings),
                                    fallback: label)
                    // Claude/AGY values are needed before the popover is first opened.
                    .onAppear { store.start(); externalStore.start(); quitMenu.install() }
            } else {
                Text(label)
                    .monospacedDigit()
                    .accessibilityLabel("Tokenly, \(label)")
                    .onAppear { store.start(); quitMenu.install() }
            }
        }
        .menuBarExtraStyle(.window)

        SystemMonitorMenuBarScenes(controller: systemWidgets, cache: systemWidgetImages, settingsWindow: settingsWindow,
                                   processIcons: processIcons)

        Settings {
            TokenlySettingsView(loginItem: loginItem, displaySettings: displaySettings,
                                externalStore: externalStore, usageStore: store, systemWidgets: systemWidgets)
                .background(SettingsWindowCapture(manager: settingsWindow))
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Tokenly 종료") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}

/// SwiftUI's window-style MenuBarExtra owns its status item and offers no right-click menu API.
/// A local right-button monitor handles only this app's status-bar windows, before SwiftUI can open a popover.
/// No global event monitor or accessibility permission is involved.
@MainActor
final class MenuBarQuitMenu: NSObject {
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let window = event.window, window.level == .statusBar,
                  let view = window.contentView else { return event }
            let menu = NSMenu()
            let item = NSMenuItem(title: "Tokenly 종료", action: #selector(self.quit), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

extension AppAppearance {
    /// nil follows macOS.
    var windowAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies Tokenly's appearance setting app-wide through `NSApp.appearance`, the one place every window (settings,
/// the AI popover, the system popovers) takes its appearance from.
///
/// It replaces `.preferredColorScheme` on the settings and AI popover content and the CPU popover's own
/// `NSWindow.appearance`. Reproduced on 2026-10-28 with a SwiftUI `Settings` scene: `.preferredColorScheme` left
/// black text on a dark window after light → system, and per-window `NSWindow.appearance` was overridden by SwiftUI
/// (window dark, SwiftUI scheme light). Only `NSApp.appearance` kept background and text matched in every sequence
/// tested (dark↔light, via system, open and reopened); menu bar labels kept following the menu bar.
@MainActor
final class AppAppearanceApplier {
    private var subscription: AnyCancellable?

    /// `apply` is injectable for tests; the app sets `NSApplication.shared.appearance`.
    init(settings: ProviderDisplaySettings,
         apply: @escaping @MainActor (NSAppearance?) -> Void = { NSApplication.shared.appearance = $0 }) {
        // `$appearance` delivers the current value at once, so the stored setting applies at launch.
        subscription = settings.$appearance.sink { mode in
            MainActor.assumeIsolated { apply(mode.windowAppearance) }
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
        case .numeric:
            value = full
        case .compact:
            value = UsageWindowKind.allCases.map { kind in
                snapshot.window(kind).map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—"
            }.joined(separator: " · ")
        }
        return hasError ? "이전 · \(value)" : value
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
