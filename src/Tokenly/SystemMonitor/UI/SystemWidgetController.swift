import Foundation
import SwiftUI

/// The five system menu bar widgets (Doc/SYSTEM-MONITOR.md §7.1).
enum SystemWidget: String, CaseIterable, Identifiable {
    case cpu, memory, battery, disk, gpu

    var id: String { rawValue }

    /// Name shown under the number (Battery shows an icon instead).
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .battery: "Battery"
        case .disk: "Disk"
        case .gpu: "GPU"
        }
    }

    var metric: SystemMonitorStore.Metric {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .battery: .battery
        case .disk: .disk
        case .gpu: .gpu
        }
    }

    /// `ProcessTopStore` visibility key of this widget's popover, if it lists processes.
    var processTopKey: String? {
        switch self {
        case .cpu: "cpu"
        case .memory: "memory"
        case .battery, .disk, .gpu: nil
        }
    }

    var defaultsKey: String { "systemWidget.\(rawValue).inserted" }

    /// Used only when this widget has no saved choice. GPU remains opt-in because its reading is experimental.
    var initialInsertion: Bool { self != .gpu }
}

/// Whether a widget can be turned on at all on this Mac. Only permanent conditions make it unsupported; a passing
/// read failure never does (§7.6).
enum SystemWidgetSupport: Equatable {
    case supported
    case noBattery
    case gpuUnavailable(GPUReading)

    static func battery(_ power: SystemMetric<BatteryPowerState>) -> SystemWidgetSupport {
        power == .unavailable(.noBattery) ? .noBattery : .supported
    }

    /// Permanent GPU findings (no Apple silicon, no service, several services, no statistics, no key) make the
    /// widget unsupported. `readFailed` and bad values are transient: the widget stays available and shows `—`.
    static func gpu(_ reading: GPUReading) -> SystemWidgetSupport {
        switch reading {
        case .notAppleSilicon, .noAccelerator, .multipleAccelerators, .noStatistics, .noUtilizationKey:
            .gpuUnavailable(reading)
        case .utilization, .readFailed, .invalidType, .outOfRange:
            .supported
        }
    }

    /// One check per widget, on the main actor, with sampler instances of its own: the store's samplers keep
    /// retry and cache state that a probe must not disturb (Doc/HANDOFF.md "6단계 UI 연결 시 지켜야 할 GPU 제약").
    /// Why a widget cannot be turned on, for the settings tab; nil when supported.
    var reasonText: String? {
        switch self {
        case .supported: nil
        case .noBattery: "이 Mac에는 배터리가 없습니다."
        case .gpuUnavailable(.notAppleSilicon): "Apple Silicon Mac에서만 지원합니다."
        case .gpuUnavailable(.multipleAccelerators): "GPU가 여러 개인 Mac은 지원하지 않습니다."
        case .gpuUnavailable: "이 Mac에서는 GPU 사용률을 읽을 수 없습니다."
        }
    }

    @MainActor
    static func probe(_ widget: SystemWidget) -> SystemWidgetSupport {
        switch widget {
        case .battery: battery(BatterySampler().samplePowerState())
        case .gpu: gpu(GPUSampler().supportStatus())
        case .cpu, .memory, .disk: .supported
        }
    }
}

/// Single owner of the five widgets' on/off state (Doc/SYSTEM-MONITOR.md §7.2).
///
/// The settings toggle and `MenuBarExtra(isInserted:)` share `binding(for:)`, whose setter is `setInserted`, the
/// only path that changes state. It stores the user's choice in UserDefaults, publishes it, and starts or stops
/// the matching measurement in `SystemMonitorStore`, synchronously on the main actor.
///
/// `isInserted == true` does not mean the item is on screen: a full menu bar can hide it behind the notch, and
/// there is no verified API to tell. A hidden widget keeps measuring; only the user turning it off stops it.
///
/// Support is probed once at start, and again for the widgets still unsupported whenever
/// `recheckUnsupportedWidgets()` is called (settings opening, wired in 6-3), so a check that failed right after
/// login does not keep a widget unavailable for the whole session.
@MainActor
final class SystemWidgetController: ObservableObject {
    /// The user's choice per widget, as stored. Kept even when the widget is unsupported on this Mac.
    @Published private(set) var stored: [SystemWidget: Bool]
    @Published private(set) var support: [SystemWidget: SystemWidgetSupport]
    /// How CPU·RAM·Disk·GPU arrange number and name. A display choice only: changing it never touches `stored`,
    /// the store or the process scanner.
    @Published private(set) var layout: SystemWidgetLayout
    /// Battery look (minimal or rounded frame). A display choice only, like `layout`.
    @Published private(set) var batteryFrame: BatteryFrameStyle

    static let layoutDefaultsKey = "systemWidget.layout"
    static let batteryFrameDefaultsKey = "systemWidget.batteryFrame"

    /// The app's one store and process scanner, owned here for the app's lifetime. Read them (labels observe
    /// `store`); never turn measurements on or off directly, only through `setInserted` (§7.2, review L1).
    let store: SystemMonitorStore
    let processTop: ProcessTopStore?
    private let supportProbe: @MainActor (SystemWidget) -> SystemWidgetSupport
    private let defaults: UserDefaults

    /// Restores the stored choices and starts the measurements of every widget that is on and supported. Runs at
    /// app start, independent of when any label appears.
    init(store: SystemMonitorStore, processTop: ProcessTopStore? = nil, defaults: UserDefaults = .standard,
         supportProbe: @escaping @MainActor (SystemWidget) -> SystemWidgetSupport = SystemWidgetSupport.probe) {
        self.store = store
        self.processTop = processTop
        self.defaults = defaults
        self.supportProbe = supportProbe
        var stored: [SystemWidget: Bool] = [:]
        var support: [SystemWidget: SystemWidgetSupport] = [:]
        for widget in SystemWidget.allCases {
            stored[widget] = defaults.object(forKey: widget.defaultsKey) as? Bool ?? widget.initialInsertion
            support[widget] = supportProbe(widget)
        }
        self.stored = stored
        self.support = support
        // Existing and new users start with `unified`; an unknown stored value also falls back to it.
        self.layout = defaults.string(forKey: Self.layoutDefaultsKey).flatMap(SystemWidgetLayout.init(rawValue:)) ?? .unified
        // Existing users have no value and keep the minimal battery; an unknown value also falls back to it.
        self.batteryFrame = defaults.string(forKey: Self.batteryFrameDefaultsKey)
            .flatMap(BatteryFrameStyle.init(rawValue:)) ?? .minimal
        for widget in SystemWidget.allCases where isInserted(widget) {
            store.setEnabled(widget.metric, true)
        }
    }

    /// Probes again only the widgets currently unsupported; supported ones are never re-checked. When one becomes
    /// supported, its stored choice (kept all along) takes effect: the store starts measuring if it was on. Returns
    /// the widgets whose support changed. Calling it repeatedly while nothing changes does no store work.
    @discardableResult
    func recheckUnsupportedWidgets() -> [SystemWidget] {
        var changed: [SystemWidget] = []
        for widget in SystemWidget.allCases where !isSupported(widget) {
            let probed = supportProbe(widget)
            guard probed != support[widget] else { continue }
            let wasInserted = isInserted(widget)
            support[widget] = probed
            if isInserted(widget) != wasInserted { store.setEnabled(widget.metric, isInserted(widget)) }
            changed.append(widget)
        }
        return changed
    }

    func isSupported(_ widget: SystemWidget) -> Bool {
        support[widget] == .supported
    }

    /// Effective state: what the menu bar and the store use. Stored choice AND supported.
    func isInserted(_ widget: SystemWidget) -> Bool {
        (stored[widget] ?? false) && isSupported(widget)
    }

    /// For both the settings toggle and `MenuBarExtra(isInserted:)`; removing the item from the menu bar writes
    /// `false` through the same setter as the toggle.
    func binding(for widget: SystemWidget) -> Binding<Bool> {
        Binding(get: { [unowned self] in isInserted(widget) },
                set: { [unowned self] in setInserted(widget, $0) })
    }

    /// For the 테마 tab picker.
    func layoutBinding() -> Binding<SystemWidgetLayout> {
        Binding(get: { [unowned self] in layout }, set: { [unowned self] in setLayout($0) })
    }

    /// Stores and publishes the display style. Labels redraw with it; nothing is measured, started or stopped.
    func setLayout(_ newLayout: SystemWidgetLayout) {
        guard newLayout != layout else { return }
        defaults.set(newLayout.rawValue, forKey: Self.layoutDefaultsKey)
        layout = newLayout
    }

    /// For the 테마 tab picker.
    func batteryFrameBinding() -> Binding<BatteryFrameStyle> {
        Binding(get: { [unowned self] in batteryFrame }, set: { [unowned self] in setBatteryFrame($0) })
    }

    /// Stores and publishes the battery look. Only the Battery label redraws; nothing is measured or toggled.
    func setBatteryFrame(_ newFrame: BatteryFrameStyle) {
        guard newFrame != batteryFrame else { return }
        defaults.set(newFrame.rawValue, forKey: Self.batteryFrameDefaultsKey)
        batteryFrame = newFrame
    }

    /// The only state change. Ignored for an unsupported widget (its toggle is disabled and its stored choice is
    /// kept for a Mac where it is supported) and when the value does not change.
    func setInserted(_ widget: SystemWidget, _ inserted: Bool) {
        guard isSupported(widget), stored[widget] != inserted else { return }
        defaults.set(inserted, forKey: widget.defaultsKey)
        stored[widget] = inserted
        store.setEnabled(widget.metric, inserted)
        // A popover still open when its widget is removed must not keep the process scan running.
        if !inserted, let key = widget.processTopKey { processTop?.setVisible(key, false) }
    }
}
