import AppKit
import SwiftUI
import XCTest
@testable import Tokenly

/// 6-4b CPU popover: load wording, graph layout and curve, colours by height, TOP 5 rows, process icons, and the
/// popover's start/stop of the TOP 5 scan.
@MainActor
final class CPUPopoverTests: XCTestCase {
    // MARK: Load wording

    func testLoadBoundaries() {
        XCTAssertEqual(SystemWidgetPresentation.cpuLoad(0), .relaxed)
        XCTAssertEqual(SystemWidgetPresentation.cpuLoad(39.9), .relaxed)
        XCTAssertEqual(SystemWidgetPresentation.cpuLoad(40), .normal)
        XCTAssertEqual(SystemWidgetPresentation.cpuLoad(79.9), .normal)
        XCTAssertEqual(SystemWidgetPresentation.cpuLoad(80), .high)
        XCTAssertEqual(SystemWidgetPresentation.cpuLoad(100), .high)
        XCTAssertNil(SystemWidgetPresentation.cpuLoad(nil))
        XCTAssertNil(SystemWidgetPresentation.cpuLoad(.nan))
        XCTAssertEqual([SystemWidgetPresentation.CPULoad.relaxed, .normal, .high].map(\.text), ["여유", "보통", "높음"])
        for load in [SystemWidgetPresentation.CPULoad.relaxed, .normal, .high] {
            XCTAssertFalse(["위험", "고장", "오류"].contains(load.text))
        }
    }

    // MARK: Graph layout

    private let end = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func history(_ points: [(TimeInterval, Double?)]) -> SystemMetricHistory {
        var history = SystemMetricHistory()
        for (offset, value) in points { history.append(value, at: end.addingTimeInterval(offset)) }
        return history
    }

    private let size = CGSize(width: 324, height: 84)

    func testCPUAreaFadeSoftensEdgesWithoutChangingGraphSamples() {
        let samples = history([(-59, 24), (-30, 24), (0, 24)])
        let original = AuroraGraphLayout(history: samples, size: size)
        XCTAssertGreaterThan(original.segments.first?.first?.x ?? 0, 0)
        XCTAssertEqual(original.current?.x, size.width - AuroraGraphLayout.rightInset)
        XCTAssertEqual(AuroraAreaEdgeFade.opacity(at: 0), 0)
        XCTAssertEqual(AuroraAreaEdgeFade.opacity(at: AuroraAreaEdgeFade.edgeFraction), 1)
        XCTAssertEqual(AuroraAreaEdgeFade.opacity(at: 0.5), 1)
        XCTAssertEqual(AuroraAreaEdgeFade.opacity(at: 1 - AuroraAreaEdgeFade.edgeFraction), 1)
        XCTAssertEqual(AuroraAreaEdgeFade.opacity(at: 1), 0)
        XCTAssertEqual(AuroraAreaEdgeFade.opacity(at: 0.01), AuroraAreaEdgeFade.opacity(at: 0.99), accuracy: 0.0001)
        XCTAssertFalse(AuroraGraph(history: samples).fadesAreaEdges, "Other popovers keep the original graph")
    }

    func testLastPointIsTheCurrentValueAtTheRightEdge() {
        let layout = AuroraGraphLayout(history: history([(-2, 30), (-1, 50), (0, 67)]), size: size)
        XCTAssertEqual(layout.currentValue, 67)
        XCTAssertEqual(layout.current?.x ?? 0, size.width - AuroraGraphLayout.rightInset, accuracy: 0.001)
        XCTAssertEqual(layout.current?.y ?? 0, AuroraGraphLayout.y(67, height: size.height), accuracy: 0.001)
        XCTAssertEqual(layout.segments.last?.last, layout.current)
    }

    func testFixedScaleZeroToHundred() {
        XCTAssertEqual(AuroraGraphLayout.y(0, height: 84), 84)
        XCTAssertEqual(AuroraGraphLayout.y(100, height: 84), AuroraGraphLayout.topInset)
        XCTAssertEqual(AuroraGraphLayout.y(50, height: 84), 84 - 0.5 * (84 - AuroraGraphLayout.topInset), accuracy: 0.0001)
        XCTAssertEqual(AuroraGraphLayout.y(150, height: 84), AuroraGraphLayout.topInset, "Clamped to the axis")
        // A stable history stays within its own band: no autoscaling.
        let layout = AuroraGraphLayout(history: history((0..<10).map { (Double($0 - 9), 22 + Double($0 % 2)) }), size: size)
        let ys = layout.segments.flatMap { $0 }.map(\.y)
        XCTAssertEqual(ys.min() ?? 0, AuroraGraphLayout.y(23, height: 84), accuracy: 0.001)
        XCTAssertEqual(ys.max() ?? 0, AuroraGraphLayout.y(22, height: 84), accuracy: 0.001)
    }

    func testGapsAreBrokenAndNeverZero() {
        // nil at -3, and a 20 s pause without points (M1).
        let layout = AuroraGraphLayout(history: history([(-30, 40), (-29, 41), (-8, 60), (-7, 61), (-3, nil), (-2, 10), (-1, 0), (0, 5)]), size: size)
        XCTAssertEqual(layout.segments.count, 3)
        XCTAssertEqual(layout.segments.map(\.count), [2, 2, 3])
        // The measured 0 % is a point at the bottom; nothing is drawn for the nil.
        let bottom = layout.segments.flatMap { $0 }.filter { $0.y == size.height }
        XCTAssertEqual(bottom.count, 1, "Only the measured 0 % touches the bottom")
        XCTAssertEqual(layout.segments.flatMap { $0 }.count, 7, "No point for the gap")
    }

    func testTrailingGapHasNoCurrentPoint() {
        let layout = AuroraGraphLayout(history: history([(-2, 30), (-1, 31), (0, nil)]), size: size)
        XCTAssertNil(layout.current)
        XCTAssertNil(layout.currentValue)
        XCTAssertEqual(layout.segments.count, 1)
    }

    func testEmptyHistory() {
        let layout = AuroraGraphLayout(history: SystemMetricHistory(), size: size)
        XCTAssertTrue(layout.segments.isEmpty)
        XCTAssertNil(layout.current)
    }

    // MARK: Curve

    /// The curve passes through every point and never leaves the range of the two points it joins.
    func testCurveDoesNotInventPeaksOrDips() {
        var values: [Double] = []
        var seed: UInt64 = 42
        for _ in 0..<60 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; values.append(Double(seed >> 33 % 101)) }
        values += [0, 0, 100, 100, 100, 3, 97, 50, 50]
        let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * 5, y: CGFloat($0.element)) }
        let segments = AuroraCurve.monotoneCubic(points)
        XCTAssertEqual(segments.count, points.count - 1)
        var worst: CGFloat = 0
        for (i, s) in segments.enumerated() {
            XCTAssertEqual(s.start, points[i]); XCTAssertEqual(s.end, points[i + 1])
            let lo = min(s.start.y, s.end.y), hi = max(s.start.y, s.end.y)
            for k in 0...50 {
                let t = CGFloat(k) / 50, u = 1 - t
                let y = u * u * u * s.start.y + 3 * u * u * t * s.control1.y + 3 * u * t * t * s.control2.y + t * t * t * s.end.y
                worst = max(worst, lo - y, y - hi)
            }
        }
        XCTAssertLessThanOrEqual(worst, 0.0001, "Curve leaves its neighbours' range by \(worst)")
        // Flat data stays flat.
        let flat = AuroraCurve.monotoneCubic([CGPoint(x: 0, y: 20), CGPoint(x: 1, y: 20), CGPoint(x: 2, y: 20)])
        XCTAssertTrue(flat.allSatisfy { $0.control1.y == 20 && $0.control2.y == 20 })
        XCTAssertTrue(AuroraCurve.monotoneCubic([CGPoint(x: 0, y: 5)]).isEmpty)
    }

    // MARK: Colour by height

    func testColourDependsOnlyOnHeight() {
        for dark in [false, true] {
            let stops = AuroraPalette.stops(dark: dark)
            XCTAssertEqual(AuroraPalette.rgb(for: 0, dark: dark), stops[0].rgb, "teal at 0 %")
            XCTAssertEqual(AuroraPalette.rgb(for: 50, dark: dark), stops[1].rgb, "blue at 50 %")
            XCTAssertEqual(AuroraPalette.rgb(for: 100, dark: dark), stops[2].rgb, "violet at 100 %")
            XCTAssertEqual(AuroraPalette.rgb(for: -5, dark: dark), stops[0].rgb)
            XCTAssertEqual(AuroraPalette.rgb(for: 140, dark: dark), stops[2].rgb)
            // Halfway between stops is halfway between their colours, and the same value gives the same colour.
            let quarter = AuroraPalette.rgb(for: 25, dark: dark)
            XCTAssertEqual(quarter.b, (stops[0].rgb.b + stops[1].rgb.b) / 2, accuracy: 1e-9)
            XCTAssertEqual(AuroraPalette.rgb(for: 67, dark: dark), AuroraPalette.rgb(for: 67, dark: dark))
            // Red rises steadily from blue to violet: higher is "more violet".
            XCTAssertLessThan(AuroraPalette.rgb(for: 60, dark: dark).r, AuroraPalette.rgb(for: 90, dark: dark).r)
        }
        XCTAssertEqual(AuroraPalette.stops(dark: true)[0].rgb, .init(r: 0.25, g: 0.85, b: 0.72), "B1 values")
        XCTAssertEqual(AuroraPalette.lineWidth, 1.25)
        XCTAssertEqual(AuroraPalette.glowOpacity(dark: true), 0.30)
        XCTAssertEqual(AuroraPalette.glowOpacity(dark: false), 0.22)
    }

    // MARK: TOP 5 rows

    func testTopRowsSortedLimitedAndPerCore() {
        let entries = [ProcessCPUEntry(pid: 9, name: "b", percent: 3, startTicks: 1),
                       ProcessCPUEntry(pid: 4, name: "WindowServer", percent: 142.34, startTicks: 2),
                       ProcessCPUEntry(pid: 2, name: "tie-low-pid", percent: 3, startTicks: 3),
                       ProcessCPUEntry(pid: 5, name: "c", percent: 0.04, startTicks: 4),
                       ProcessCPUEntry(pid: 6, name: "d", percent: 87.6, startTicks: 5),
                       ProcessCPUEntry(pid: 7, name: "e", percent: 1, startTicks: 6)]
        let rows = SystemWidgetPresentation.cpuTopRows(entries)
        XCTAssertEqual(rows.map(\.pid), [4, 6, 2, 9, 7], "Highest first, ties by PID, at most five")
        XCTAssertEqual(rows.first?.percentText, "142.3%", "Per core, not capped at 100")
        XCTAssertEqual(rows.first?.startTicks, 2, "Identity kept for the icon cache")
    }

    func testCalculatorKeepsStartTicks() {
        let previous = ProcessRawSnapshot(uptimeNanoseconds: 1_000_000_000, entries: [
            ProcessRawEntry(pid: 7, name: "x", startTicks: 555, userTicks: 0, systemTicks: 0, footprintBytes: 1)], permissionDeniedCount: 0)
        let current = ProcessRawSnapshot(uptimeNanoseconds: 2_000_000_000, entries: [
            ProcessRawEntry(pid: 7, name: "x", startTicks: 555, userTicks: 500_000_000, systemTicks: 0, footprintBytes: 1)], permissionDeniedCount: 0)
        let top = ProcessTopCalculator.calculate(previous: previous, current: current, timebaseNumer: 1, timebaseDenom: 1)
        XCTAssertEqual(top.cpu.first?.startTicks, 555)
        XCTAssertEqual(top.cpu.first?.percent ?? 0, 50, accuracy: 0.001)
    }

    // MARK: Process icons

    func testIconsAreCachedPerProcessIdentity() {
        var asked: [Int32] = []
        let marker = NSImage(size: NSSize(width: 1, height: 1))
        let provider = ProcessIconProvider { pid in asked.append(pid); return pid == 10 ? marker : nil }
        XCTAssertTrue(provider.icon(pid: 10, startTicks: 1) === marker)
        XCTAssertNil(provider.icon(pid: 20, startTicks: 1), "No app: generic icon")
        for _ in 0..<5 { _ = provider.icon(pid: 10, startTicks: 1); _ = provider.icon(pid: 20, startTicks: 1) }
        XCTAssertEqual(asked, [10, 20], "Each process looked up once, including 'no icon'")
        // A reused PID (new start time) is a different process: looked up again.
        _ = provider.icon(pid: 10, startTicks: 2)
        XCTAssertEqual(asked, [10, 20, 10])
        provider.retain([.init(pid: 10, startTicks: 2)])
        XCTAssertEqual(provider.cachedKeys, [.init(pid: 10, startTicks: 2)], "Processes no longer listed are dropped")
        XCTAssertEqual(provider.lookupCount, 3)
    }

    func testRunningApplicationIconOnlyForAppBundles() {
        // The test host is Tokenly.app: a running application with an .app bundle.
        let me = ProcessInfo.processInfo.processIdentifier
        if let app = NSRunningApplication(processIdentifier: me), app.bundleURL?.pathExtension == "app", app.activationPolicy != .prohibited {
            XCTAssertNotNil(ProcessIconProvider.runningApplicationIcon(me))
        }
        // launchd (PID 1) is not an application: generic icon, never a guessed one.
        XCTAssertNil(ProcessIconProvider.runningApplicationIcon(1))
        XCTAssertNil(ProcessIconProvider.runningApplicationIcon(-5))
    }

    // MARK: Popover lifecycle → TOP 5 scan

    private final class Scheduler: SystemMonitorScheduling {
        final class Job: SystemMonitorCancellable { var cancelled = false; func cancel() { cancelled = true } }
        var jobs: [Job] = []
        var active: Int { jobs.filter { !$0.cancelled }.count }
        func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { let j = Job(); jobs.append(j); return j }
        func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { let j = Job(); jobs.append(j); return j }
        func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { let j = Job(); jobs.append(j); return j }
    }

    private struct NoProcesses: ProcessTopSampling {
        func sample() async throws -> SystemMetric<ProcessTopSnapshot> {
            .available(ProcessTopSnapshot(cpu: [], memory: [], cpuHasBaseline: false, readableCount: 0, permissionDeniedCount: 0))
        }
    }

    private struct IdleSampler: SystemSampler {
        func sample() async throws -> SystemSnapshot {
            SystemSnapshot(sampledAt: Date(), cpu: .unavailable(.awaitingBaseline), memory: .unavailable(.unsupported))
        }
    }

    private func makeController() -> (SystemWidgetController, Scheduler, () -> Void) {
        let suite = TestDefaults.suite("CPUPopover")
        let defaults = UserDefaults(suiteName: suite)!
        // Existing user with every widget saved OFF; a new user would start with CPU/RAM/Disk/Battery on (6-9A).
        for widget in SystemWidget.allCases { defaults.set(false, forKey: widget.defaultsKey) }
        let processScheduler = Scheduler()
        let store = SystemMonitorStore(makeSampler: { IdleSampler() }, scheduler: Scheduler())
        let controller = SystemWidgetController(store: store, processTop: ProcessTopStore(makeSampler: { NoProcesses() }, scheduler: processScheduler),
                                                defaults: defaults, supportProbe: { _ in .supported })
        return (controller, processScheduler, {
            for widget in SystemWidget.allCases { controller.setInserted(widget, false) }
            TestDefaults.discard(defaults, suite: suite)
        })
    }

    func testOpeningStartsAndClosingStopsTheScan() {
        let (controller, scheduler, cleanup) = makeController()
        defer { cleanup() }
        controller.setInserted(.cpu, true)
        SystemPopoverVisibility.set(.cpu, visible: true, controller: controller, source: "appear")
        XCTAssertEqual(scheduler.active, 1, "Scanning every 3 s while open")
        SystemPopoverVisibility.set(.cpu, visible: false, controller: controller, source: "disappear")
        XCTAssertEqual(scheduler.active, 0, "Stopped when closed")
    }

    func testAppearAndWindowSignalsNeverDuplicateTheScan() {
        let (controller, scheduler, cleanup) = makeController()
        defer { cleanup() }
        controller.setInserted(.cpu, true)
        for _ in 0..<5 {
            SystemPopoverVisibility.set(.cpu, visible: true, controller: controller, source: "appear")
            SystemPopoverVisibility.set(.cpu, visible: true, controller: controller, source: "window")
            XCTAssertEqual(scheduler.active, 1)
            SystemPopoverVisibility.set(.cpu, visible: false, controller: controller, source: "window")
            SystemPopoverVisibility.set(.cpu, visible: false, controller: controller, source: "disappear")
            XCTAssertEqual(scheduler.active, 0)
        }
        XCTAssertEqual(scheduler.jobs.count, 5, "One timer per opening, none left running")
    }

    func testNoScanWhileTheCPUWidgetIsOffOrAfterRemoval() {
        let (controller, scheduler, cleanup) = makeController()
        defer { cleanup() }
        SystemPopoverVisibility.set(.cpu, visible: true, controller: controller, source: "appear")
        XCTAssertEqual(scheduler.active, 0, "CPU widget off: no scan")
        controller.setInserted(.cpu, true)
        SystemPopoverVisibility.set(.cpu, visible: true, controller: controller, source: "appear")
        XCTAssertEqual(scheduler.active, 1)
        controller.setInserted(.cpu, false)
        XCTAssertEqual(scheduler.active, 0, "Removing the widget while open stops the scan")
        // Non-CPU widgets have no popover scan.
        SystemPopoverVisibility.set(.disk, visible: true, controller: controller, source: "appear")
        XCTAssertEqual(scheduler.active, 0)
    }

    // MARK: App appearance → popover window (real-app fix)

    func testAppearanceSettingMapsToWindowAppearance() {
        XCTAssertNil(AppAppearance.system.windowAppearance, "System: the window follows macOS")
        XCTAssertEqual(AppAppearance.light.windowAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.windowAppearance?.name, .darkAqua)
    }

    /// The applier sets the app-wide appearance at launch and on every change, for every sequence that broke the
    /// settings window (2026-10-28 reproduction).
    func testApplierFollowsEverySequence() {
        let suite = TestDefaults.suite("Appearance")
        let defaults = UserDefaults(suiteName: suite)!
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        settings.appearance = .dark
        var applied: [NSAppearance.Name?] = []
        let applier = AppAppearanceApplier(settings: settings) { applied.append($0?.name) }
        XCTAssertEqual(applied, [.darkAqua], "Stored setting applied at launch")
        let sequences: [[AppAppearance]] = [[.dark, .light, .dark], [.light, .dark, .light], [.system, .dark, .system],
                                            [.system, .light, .system], [.dark, .light, .dark, .light, .dark]]
        for sequence in sequences {
            for mode in sequence {
                settings.appearance = mode
                XCTAssertEqual(applied.count > 0 ? applied[applied.count - 1] : .aqua, mode.windowAppearance?.name, "\(sequence) at \(mode)")
            }
        }
        withExtendedLifetime(applier) {}
    }

    /// With only the app-wide appearance (no per-window or SwiftUI override), a hosted SwiftUI view's colour scheme
    /// always matches its window's effective appearance, through the same sequences.
    func testAppWideAppearanceKeepsSchemeAndWindowMatched() {
        final class Box { var scheme: ColorScheme? }
        struct Probe: View {
            let box: Box
            @Environment(\.colorScheme) private var scheme
            var body: some View { Text("Aa").onChange(of: scheme, initial: true) { _, s in box.scheme = s } }
        }
        let suite = TestDefaults.suite("Appearance")
        let defaults = UserDefaults(suiteName: suite)!
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        let applier = AppAppearanceApplier(settings: settings)
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Probe(box: box))
        for sequence in [[AppAppearance.dark, .light, .dark], [.light, .dark, .light], [.system, .dark, .system],
                         [.system, .light, .system], [.dark, .light, .dark, .light, .dark]] {
            for mode in sequence {
                settings.appearance = mode
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let windowDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                XCTAssertNil(window.appearance, "No per-window override")
                XCTAssertEqual(box.scheme, windowDark ? .dark : .light, "\(sequence) at \(mode): text scheme differs from the window")
                if mode != .system { XCTAssertEqual(windowDark, mode == .dark, "\(sequence) at \(mode)") }
            }
        }
        withExtendedLifetime(applier) {}
    }
}
