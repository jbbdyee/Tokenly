import Foundation
import SwiftUI

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case numeric, compact, bear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .numeric: "숫자형"
        case .compact: "최소형"
        case .bear: "곰돌이형"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "시스템 설정 따르기"
        case .light: "라이트 모드"
        case .dark: "다크 모드"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class ProviderDisplaySettings: ObservableObject {
    static let codexVisibilityKey = "provider.codex.visibleInPopover"
    static let agyVisibilityKey = "provider.antigravity.visibleInPopover"
    static let claudeVisibilityKey = "provider.claude.visibleInPopover"
    static let openAIVisibilityKey = "provider.openAIAPI.visibleInPopover"
    static let codexExpandedKey = "provider.codex.expandedInPopover"
    static let agyExpandedKey = "provider.antigravity.expandedInPopover"
    static let claudeExpandedKey = "provider.claude.expandedInPopover"
    static let menuBarStyleKey = "menuBar.displayStyle"
    static let appearanceKey = "appearance.mode"

    @Published var showsCodex: Bool {
        didSet { defaults.set(showsCodex, forKey: Self.codexVisibilityKey) }
    }
    @Published var showsAGY: Bool {
        didSet { defaults.set(showsAGY, forKey: Self.agyVisibilityKey) }
    }
    @Published var showsClaude: Bool {
        didSet { defaults.set(showsClaude, forKey: Self.claudeVisibilityKey) }
    }
    @Published var showsOpenAIAPI: Bool {
        didSet { defaults.set(showsOpenAIAPI, forKey: Self.openAIVisibilityKey) }
    }
    @Published var codexExpanded: Bool {
        didSet { defaults.set(codexExpanded, forKey: Self.codexExpandedKey) }
    }
    @Published var agyExpanded: Bool {
        didSet { defaults.set(agyExpanded, forKey: Self.agyExpandedKey) }
    }
    @Published var claudeExpanded: Bool {
        didSet { defaults.set(claudeExpanded, forKey: Self.claudeExpandedKey) }
    }
    @Published var menuBarStyle: MenuBarDisplayStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Self.menuBarStyleKey) }
    }
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsCodex = defaults.object(forKey: Self.codexVisibilityKey) as? Bool ?? true
        showsAGY = defaults.bool(forKey: Self.agyVisibilityKey)
        showsClaude = defaults.bool(forKey: Self.claudeVisibilityKey)
        showsOpenAIAPI = defaults.bool(forKey: Self.openAIVisibilityKey)
        codexExpanded = defaults.object(forKey: Self.codexExpandedKey) as? Bool ?? true
        agyExpanded = defaults.object(forKey: Self.agyExpandedKey) as? Bool ?? false
        claudeExpanded = defaults.object(forKey: Self.claudeExpandedKey) as? Bool ?? false
        let storedStyle = defaults.string(forKey: Self.menuBarStyleKey)
        menuBarStyle = MenuBarDisplayStyle(rawValue: storedStyle ?? "") ?? .numeric
        // v1.0 removed the icon and heart styles: a saved value that no longer exists becomes numeric,
        // written back once so it does not linger. Other settings are untouched.
        if let storedStyle, MenuBarDisplayStyle(rawValue: storedStyle) == nil {
            defaults.set(MenuBarDisplayStyle.numeric.rawValue, forKey: Self.menuBarStyleKey)
        }
        appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }

    var visibleSupportedProviders: [String] {
        (showsCodex ? ["Codex"] : [])
            + (showsClaude ? ["Claude"] : [])
            + (showsAGY ? ["Google Antigravity"] : [])
    }
}
