import Combine
import IOKit
import XCTest
@testable import Tokenly

// MARK: - Doubles (kept small: these tests check state flow, not the samplers)

/// Records jobs; nothing fires unless a test asks. Lets tests see whether a measurement is scheduled.
@MainActor
private final class RecordingScheduler: SystemMonitorScheduling {
    final class Job: SystemMonitorCancellable {
        let interval: TimeInterval?
        let action: @MainActor () -> Void
        private(set) var isCancelled = false
        init(interval: TimeInterval?, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.action = action
        }
        func cancel() { isCancelled = true }
    }

    private(set) var jobs: [Job] = []
    var active: [Job] { jobs.filter { !$0.isCancelled } }

    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        record(Job(interval: interval, action: action))
    }

    func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        record(Job(interval: nil, action: action))
    }

    func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        record(Job(interval: nil, action: action))
    }

    private func record(_ job: Job) -> Job {
        jobs.append(job)
        return job
    }
}

private struct IdleSampler: SystemSampler {
    func sample() async throws -> SystemSnapshot {
        SystemSnapshot(sampledAt: Date(), cpu: .unavailable(.awaitingBaseline), memory: .unavailable(.unsupported))
    }
}

private struct FixedBattery: BatterySampling {
    func sample() -> SystemMetric<BatteryStatus> { .unavailable(.unsupported) }
    func samplePowerState() -> SystemMetric<BatteryPowerState> { .unavailable(.unsupported) }
}

private struct FixedDisk: DiskSampling {
    func sample() async -> SystemMetric<DiskUsage> { .unavailable(.unsupported) }
}

private final class FixedGPU: GPUSampling {
    func read() -> GPUReading { .utilization(10) }
}

private struct EmptyProcessTop: ProcessTopSampling {
    func sample() async throws -> SystemMetric<ProcessTopSnapshot> {
        .available(ProcessTopSnapshot(cpu: [], memory: [], cpuHasBaseline: false, readableCount: 0, permissionDeniedCount: 0))
    }
}

/// One app's worth of objects on a throwaway UserDefaults suite. `restart()` builds a new app on the same suite.
@MainActor
private final class App {
    let suite = "tokenly.systemWidget.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    /// What the probe reports now; tests change it between restarts or before a recheck.
    var support: [SystemWidget: SystemWidgetSupport] = [:]
    private(set) var probes: [SystemWidget: Int] = [:]
    private(set) var scheduler = RecordingScheduler()
    private(set) var processScheduler = RecordingScheduler()
    private(set) var store: SystemMonitorStore!
    private(set) var processTop: ProcessTopStore!
    private(set) var controller: SystemWidgetController!

    init() {
        defaults = UserDefaults(suiteName: suite)!
        restart()
    }

    func restart() {
        scheduler = RecordingScheduler()
        processScheduler = RecordingScheduler()
        store = SystemMonitorStore(makeSampler: { IdleSampler() }, battery: FixedBattery(), disk: FixedDisk(),
                                   gpu: FixedGPU(), scheduler: scheduler)
        processTop = ProcessTopStore(makeSampler: { EmptyProcessTop() }, scheduler: processScheduler)
        probes = [:]
        controller = SystemWidgetController(store: store, processTop: processTop, defaults: defaults,
                                            supportProbe: { [unowned self] widget in
                                                probes[widget, default: 0] += 1
                                                return support[widget] ?? .supported
                                            })
    }

    func discard() {
        for widget in SystemWidget.allCases { store.setEnabled(widget.metric, false) }
        defaults.removePersistentDomain(forName: suite)
    }
}

// MARK: - Controller

@MainActor
final class SystemWidgetControllerTests: XCTestCase {
    func testFirstLaunchHasEveryWidgetOff() {
        let app = App()
        defer { app.discard() }
        for widget in SystemWidget.allCases {
            XCTAssertFalse(app.controller.isInserted(widget))
            XCTAssertFalse(app.controller.binding(for: widget).wrappedValue)
            XCTAssertNil(app.defaults.object(forKey: widget.defaultsKey), "Nothing is written until the user acts")
        }
        XCTAssertTrue(app.store.enabledMetrics.isEmpty)
        XCTAssertTrue(app.scheduler.jobs.isEmpty, "No measurement on first launch")
    }

    func testTurningOnStartsAndTurningOffStopsMeasurement() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.cpu, true)
        XCTAssertEqual(app.store.enabledMetrics, [.cpu])
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.cpu.defaultsKey) as? Bool, true)
        XCTAssertEqual(app.scheduler.active.count, 1)

        app.controller.setInserted(.cpu, false)
        XCTAssertTrue(app.store.enabledMetrics.isEmpty)
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.cpu.defaultsKey) as? Bool, false)
        XCTAssertTrue(app.scheduler.active.isEmpty, "The timer is cancelled")
    }

    /// Removing the item from the menu bar writes `false` into the `isInserted` binding; the toggle uses the same one.
    func testBindingChangesTakeTheSamePathAsTheToggle() {
        let app = App()
        defer { app.discard() }
        let disk = app.controller.binding(for: .disk)
        disk.wrappedValue = true
        XCTAssertTrue(app.controller.isInserted(.disk))
        XCTAssertEqual(app.store.enabledMetrics, [.disk])

        disk.wrappedValue = false
        XCTAssertFalse(app.controller.isInserted(.disk))
        XCTAssertFalse(app.controller.binding(for: .disk).wrappedValue, "The settings toggle sees the removal")
        XCTAssertTrue(app.store.enabledMetrics.isEmpty)
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.disk.defaultsKey) as? Bool, false)
    }

    func testRestartRestoresStoredWidgetsAndStartsTheirMeasurement() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.memory, true)
        app.controller.setInserted(.gpu, true)
        app.controller.setInserted(.battery, true)
        app.controller.setInserted(.battery, false)

        app.restart()
        XCTAssertEqual(Set(SystemWidget.allCases.filter(app.controller.isInserted)), [.memory, .gpu])
        XCTAssertEqual(app.store.enabledMetrics, [.memory, .gpu], "Applied in init, before any label appears")
    }

    func testRemovedWidgetCanBeTurnedOnAgain() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.gpu, true)
        app.controller.binding(for: .gpu).wrappedValue = false
        XCTAssertTrue(app.store.enabledMetrics.isEmpty)

        app.controller.setInserted(.gpu, true)
        XCTAssertEqual(app.store.enabledMetrics, [.gpu])
        XCTAssertEqual(app.scheduler.active.count, 1, "One GPU read pending, no leftover from before")
        app.restart()
        XCTAssertTrue(app.controller.isInserted(.gpu))
    }

    func testSettingTheSameValueAgainDoesNothing() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.cpu, true)
        var changes = 0
        let watch = app.controller.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        let jobs = app.scheduler.jobs.count

        app.controller.setInserted(.cpu, true)
        app.controller.binding(for: .cpu).wrappedValue = true
        app.controller.setInserted(.disk, false)
        XCTAssertEqual(changes, 0, "No publish")
        XCTAssertEqual(app.scheduler.jobs.count, jobs, "No new measurement work")
        XCTAssertNil(app.defaults.object(forKey: SystemWidget.disk.defaultsKey), "No write for an unchanged value")
    }

    func testUnsupportedWidgetKeepsTheStoredChoice() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.battery, true)
        app.controller.setInserted(.gpu, true)

        // The same preferences on a Mac without a battery or a readable GPU.
        app.support = [.battery: .noBattery, .gpu: .gpuUnavailable(.noAccelerator)]
        app.restart()
        XCTAssertFalse(app.controller.isInserted(.battery))
        XCTAssertFalse(app.controller.isInserted(.gpu))
        XCTAssertTrue(app.store.enabledMetrics.isEmpty, "Unsupported widgets do not measure")
        app.controller.setInserted(.battery, false)
        app.controller.binding(for: .gpu).wrappedValue = false
        XCTAssertEqual(app.controller.stored[.battery], true)
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.battery.defaultsKey) as? Bool, true, "Choice preserved")
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.gpu.defaultsKey) as? Bool, true)

        app.support = [:]
        app.restart()
        XCTAssertEqual(app.store.enabledMetrics, [.battery, .gpu], "Back on a supported Mac, the widgets return")
    }

    func testOnlyPermanentFindingsMakeAWidgetUnsupported() {
        XCTAssertEqual(SystemWidgetSupport.gpu(.readFailed(kIOReturnNoResources)), .supported)
        XCTAssertEqual(SystemWidgetSupport.gpu(.outOfRange), .supported)
        XCTAssertEqual(SystemWidgetSupport.gpu(.invalidType), .supported)
        XCTAssertEqual(SystemWidgetSupport.gpu(.utilization(0)), .supported)
        for permanent in [GPUReading.notAppleSilicon, .noAccelerator, .multipleAccelerators(2), .noStatistics, .noUtilizationKey] {
            XCTAssertEqual(SystemWidgetSupport.gpu(permanent), .gpuUnavailable(permanent))
        }
        XCTAssertEqual(SystemWidgetSupport.battery(.unavailable(.noBattery)), .noBattery)
        XCTAssertEqual(SystemWidgetSupport.battery(.unavailable(.readFailed(kIOReturnError))), .supported)
        XCTAssertEqual(SystemWidgetSupport.battery(.unavailable(.unsupported)), .supported)
    }

    func testTransientGPUFailureAtStartupIsNotStoredAsUnsupported() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.gpu, true)
        app.support = [.gpu: SystemWidgetSupport.gpu(.readFailed(kIOReturnNoResources))]
        app.restart()
        XCTAssertTrue(app.controller.isInserted(.gpu))
        XCTAssertEqual(app.store.enabledMetrics, [.gpu])
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.gpu.defaultsKey) as? Bool, true)
    }

    // MARK: Support recheck (6-1 review M2)

    func testStartupProbesEachWidgetOnce() {
        let app = App()
        defer { app.discard() }
        XCTAssertEqual(app.probes, Dictionary(uniqueKeysWithValues: SystemWidget.allCases.map { ($0, 1) }))
        app.controller.setInserted(.gpu, true)
        app.controller.setInserted(.gpu, false)
        XCTAssertEqual(app.probes[.gpu], 1, "Turning a widget on or off never probes")
    }

    func testRecheckRestoresAWidgetThatWasUnsupportedAtStartup() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.battery, true)
        app.controller.setInserted(.gpu, true)
        // Right after login the probes failed; the stored choices survive.
        app.support = [.battery: .noBattery, .gpu: .gpuUnavailable(.noStatistics)]
        app.restart()
        XCTAssertTrue(app.store.enabledMetrics.isEmpty)

        app.support = [:]
        XCTAssertEqual(app.controller.recheckUnsupportedWidgets(), [.battery, .gpu])
        XCTAssertTrue(app.controller.isInserted(.battery))
        XCTAssertTrue(app.controller.isInserted(.gpu))
        XCTAssertEqual(app.store.enabledMetrics, [.battery, .gpu], "Stored choices take effect and measuring starts")
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.battery.defaultsKey) as? Bool, true)
        XCTAssertEqual(app.defaults.object(forKey: SystemWidget.gpu.defaultsKey) as? Bool, true)
    }

    func testRecheckOfAWidgetTheUserLeftOffStartsNothing() {
        let app = App()
        defer { app.discard() }
        app.support = [.gpu: .gpuUnavailable(.noAccelerator)]
        app.restart()
        app.support = [:]
        XCTAssertEqual(app.controller.recheckUnsupportedWidgets(), [.gpu])
        XCTAssertTrue(app.controller.isSupported(.gpu))
        XCTAssertFalse(app.controller.isInserted(.gpu), "Supported now, but the user never turned it on")
        XCTAssertTrue(app.store.enabledMetrics.isEmpty)
        XCTAssertNil(app.defaults.object(forKey: SystemWidget.gpu.defaultsKey), "Nothing written")
    }

    func testRecheckProbesOnlyUnsupportedWidgets() {
        let app = App()
        defer { app.discard() }
        app.support = [.battery: .noBattery]
        app.restart()
        app.controller.recheckUnsupportedWidgets()
        app.controller.recheckUnsupportedWidgets()
        XCTAssertEqual(app.probes[.battery], 3, "Start + two rechecks")
        for widget in [SystemWidget.cpu, .memory, .disk, .gpu] {
            XCTAssertEqual(app.probes[widget], 1, "\(widget) is supported and never re-probed")
        }
    }

    func testRepeatedRecheckDoesNoDuplicateWork() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.gpu, true)
        app.support = [.gpu: .gpuUnavailable(.noAccelerator)]
        app.restart()

        var changes = 0
        let watch = app.controller.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        XCTAssertTrue(app.controller.recheckUnsupportedWidgets().isEmpty, "Still unsupported")
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(app.scheduler.jobs.isEmpty)

        app.support = [:]
        app.controller.recheckUnsupportedWidgets()
        let jobs = app.scheduler.jobs.count
        XCTAssertEqual(app.scheduler.active.count, 1, "One GPU read pending")
        for _ in 0..<3 { XCTAssertTrue(app.controller.recheckUnsupportedWidgets().isEmpty) }
        XCTAssertEqual(app.scheduler.jobs.count, jobs, "No second activation")
        XCTAssertEqual(app.probes[.gpu], 3, "Start, the recheck that still failed, the one that succeeded; never again")
    }

    func testRecheckThatStillFindsAnotherPermanentReasonStaysOff() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.gpu, true)
        app.support = [.gpu: .gpuUnavailable(.noAccelerator)]
        app.restart()
        app.support = [.gpu: .gpuUnavailable(.multipleAccelerators(2))]
        XCTAssertEqual(app.controller.recheckUnsupportedWidgets(), [.gpu])
        XCTAssertEqual(app.controller.support[.gpu], .gpuUnavailable(.multipleAccelerators(2)), "The reason is refreshed")
        XCTAssertFalse(app.controller.isInserted(.gpu))
        XCTAssertTrue(app.store.enabledMetrics.isEmpty)
    }

    func testTurningOffCPUOrRAMReleasesTheProcessScan() async {
        let app = App()
        defer { app.discard() }
        for (widget, key) in [(SystemWidget.cpu, "cpu"), (.memory, "memory")] {
            app.controller.setInserted(widget, true)
            app.processTop.setVisible(key, true)
            XCTAssertEqual(app.processScheduler.active.count, 1, "The \(key) popover is scanning")
            await app.processTop.pendingSample?.value

            app.controller.setInserted(widget, false)
            XCTAssertTrue(app.processScheduler.active.isEmpty, "Removing \(widget) stopped the scan")
            XCTAssertNil(app.processTop.snapshot)
        }
    }

    func testOtherWidgetsDoNotTouchTheProcessScan() async {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.disk, true)
        app.processTop.setVisible("cpu", true)
        app.controller.setInserted(.disk, false)
        XCTAssertEqual(app.processScheduler.active.count, 1)
        app.processTop.setVisible("cpu", false)
    }

    // MARK: Display style (6-3 follow-up)

    func testLayoutDefaultsToUnifiedAndWritesNothing() {
        let app = App()
        defer { app.discard() }
        XCTAssertEqual(app.controller.layout, .unified)
        XCTAssertNil(app.defaults.object(forKey: SystemWidgetController.layoutDefaultsKey))
    }

    func testLayoutIsStoredAndRestoredOnRestart() {
        let app = App()
        defer { app.discard() }
        app.controller.layoutBinding().wrappedValue = .split
        XCTAssertEqual(app.controller.layout, .split)
        XCTAssertEqual(app.defaults.string(forKey: SystemWidgetController.layoutDefaultsKey), "split")
        app.restart()
        XCTAssertEqual(app.controller.layout, .split, "Restored after restart")
        app.controller.setLayout(.unified)
        app.restart()
        XCTAssertEqual(app.controller.layout, .unified)
    }

    func testUnknownStoredLayoutFallsBackToUnified() {
        let app = App()
        defer { app.discard() }
        app.defaults.set("diagonal", forKey: SystemWidgetController.layoutDefaultsKey)
        app.restart()
        XCTAssertEqual(app.controller.layout, .unified)
    }

    /// Changing the style touches neither the on/off choices nor any measurement.
    func testLayoutChangeDoesNotTouchOnOffOrMeasurement() async {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.cpu, true)
        app.controller.setInserted(.gpu, true)
        app.processTop.setVisible("cpu", true)
        await app.processTop.pendingSample?.value
        let stored = app.controller.stored
        let metrics = app.store.enabledMetrics
        let jobs = app.scheduler.jobs.count
        let active = app.scheduler.active.count
        let processJobs = app.processScheduler.active.count
        let defaultsBefore = SystemWidget.allCases.map { app.defaults.object(forKey: $0.defaultsKey) as? Bool }

        var publishes = 0
        let watch = app.controller.objectWillChange.sink { publishes += 1 }
        for layout in [SystemWidgetLayout.split, .split, .unified, .split] { app.controller.setLayout(layout) }
        watch.cancel()

        XCTAssertEqual(publishes, 3, "Only real changes publish")
        XCTAssertEqual(app.controller.stored, stored)
        XCTAssertEqual(app.store.enabledMetrics, metrics)
        XCTAssertEqual(app.scheduler.jobs.count, jobs, "No measurement scheduled or restarted")
        XCTAssertEqual(app.scheduler.active.count, active)
        XCTAssertEqual(app.processScheduler.active.count, processJobs)
        XCTAssertEqual(SystemWidget.allCases.map { app.defaults.object(forKey: $0.defaultsKey) as? Bool }, defaultsBefore)
        app.processTop.setVisible("cpu", false)
    }

    func testBatteryIgnoresTheLayout() {
        XCTAssertEqual(SystemWidgetLayout.split.applied(to: .battery), .unified)
        for widget in [SystemWidget.cpu, .memory, .disk, .gpu] {
            XCTAssertEqual(SystemWidgetLayout.split.applied(to: widget), .split)
        }
    }

    // MARK: Battery frame (6-3 final)

    func testBatteryFrameDefaultsToMinimalAndWritesNothing() {
        let app = App()
        defer { app.discard() }
        XCTAssertEqual(app.controller.batteryFrame, .minimal, "Existing users keep the minimal battery")
        XCTAssertNil(app.defaults.object(forKey: SystemWidgetController.batteryFrameDefaultsKey))
    }

    func testBatteryFrameIsStoredRestoredAndIndependentOfLayout() {
        let app = App()
        defer { app.discard() }
        app.controller.batteryFrameBinding().wrappedValue = .rounded
        XCTAssertEqual(app.defaults.string(forKey: SystemWidgetController.batteryFrameDefaultsKey), "rounded")
        XCTAssertEqual(app.controller.layout, .unified, "The layout is a separate choice")
        app.restart()
        XCTAssertEqual(app.controller.batteryFrame, .rounded, "Restored after restart")
        app.controller.setLayout(.split)
        app.restart()
        XCTAssertEqual(app.controller.batteryFrame, .rounded)
        XCTAssertEqual(app.controller.layout, .split)
        app.controller.setBatteryFrame(.minimal)
        app.restart()
        XCTAssertEqual(app.controller.batteryFrame, .minimal)
        app.defaults.set("hexagon", forKey: SystemWidgetController.batteryFrameDefaultsKey)
        app.restart()
        XCTAssertEqual(app.controller.batteryFrame, .minimal, "Unknown value falls back to minimal")
    }

    func testBatteryFrameChangeDoesNotTouchOnOffOrMeasurement() {
        let app = App()
        defer { app.discard() }
        app.controller.setInserted(.battery, true)
        app.controller.setInserted(.cpu, true)
        let stored = app.controller.stored, metrics = app.store.enabledMetrics
        let jobs = app.scheduler.jobs.count, active = app.scheduler.active.count
        var publishes = 0
        let watch = app.controller.objectWillChange.sink { publishes += 1 }
        for frame in [BatteryFrameStyle.rounded, .rounded, .minimal, .rounded] { app.controller.setBatteryFrame(frame) }
        watch.cancel()
        XCTAssertEqual(publishes, 3, "Only real changes publish")
        XCTAssertEqual(app.controller.stored, stored)
        XCTAssertEqual(app.store.enabledMetrics, metrics)
        XCTAssertEqual(app.scheduler.jobs.count, jobs)
        XCTAssertEqual(app.scheduler.active.count, active)
    }
}
