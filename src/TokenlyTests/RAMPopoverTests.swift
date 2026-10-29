import Darwin
import SwiftUI
import XCTest
@testable import Tokenly

/// 6-4c RAM popover: composition arithmetic, memory pressure (mapping, failure, independence from usage), TOP 5
/// rows, full process names, and the popover's start/stop of the memory scan.
@MainActor
final class RAMPopoverTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    // MARK: Composition

    func testCompositionPartsSumExactlyToTotalAndMatchUsage() {
        let memory = MemoryUsage(totalBytes: 16 * gib, usedBytes: 13 * gib, appBytes: 4 * gib, wiredBytes: 3 * gib,
                                 compressedBytes: 6 * gib, cachedFilesBytes: 2 * gib)
        let parts = SystemWidgetPresentation.memoryComposition(memory)
        XCTAssertEqual(parts.map(\.kind), [.app, .wired, .compressed, .available])
        XCTAssertEqual(parts.map(\.title), ["앱 메모리", "와이어드", "압축", "사용 가능"])
        XCTAssertEqual(parts.map(\.bytes).reduce(0, +), memory.totalBytes, "No overlap, nothing missing")
        XCTAssertEqual(parts[0].bytes + parts[1].bytes + parts[2].bytes, memory.usedBytes, "Same basis as the usage %")
        XCTAssertEqual(parts[3].bytes, 3 * gib, "Available = total − used")
        XCTAssertEqual(parts.map(\.fraction).reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(parts[0].fraction + parts[1].fraction + parts[2].fraction, memory.usedFraction, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(memory.cachedFilesBytes, parts[3].bytes, "Cached files are part of available")
    }

    func testCompositionFromTheCalculatorAlwaysAddsUp() {
        // VM page counters as the kernel reports them (this Mac, 16 KB pages, 2026-10-28).
        let pages = VMPageCounters(anonymous: 267_262, purgeable: 4, wired: 183_070, compressed: 417_613, external: 136_820)
        guard case .available(let memory) = MemoryUsage.calculate(totalBytes: 17_179_869_184, pageSize: 16_384, pages: pages) else {
            return XCTFail("calculate failed")
        }
        let parts = SystemWidgetPresentation.memoryComposition(memory)
        XCTAssertEqual(parts.map(\.bytes).reduce(0, +), memory.totalBytes)
        XCTAssertEqual(parts[0].bytes, (267_262 - 4) * 16_384, "App = anonymous − purgeable")
        XCTAssertEqual(parts[2].bytes, 417_613 * 16_384, "Compressed = pages held by the compressor")
        XCTAssertEqual(memory.cachedFilesBytes, (136_820 + 4) * 16_384)
    }

    func testCompositionRejectsInconsistentValues() {
        XCTAssertTrue(SystemWidgetPresentation.memoryComposition(MemoryUsage(totalBytes: 0, usedBytes: 0, appBytes: 0, wiredBytes: 0,
                                                                             compressedBytes: 0, cachedFilesBytes: 0)).isEmpty)
    }

    func testLiveSampleAddsUp() async throws {
        let snapshot = try await MachSystemSampler().sample()
        let memory = try XCTUnwrap(snapshot.memory.value)
        let parts = SystemWidgetPresentation.memoryComposition(memory)
        XCTAssertEqual(parts.map(\.bytes).reduce(0, +), memory.totalBytes)
        XCTAssertEqual(memory.appBytes + memory.wiredBytes + memory.compressedBytes, memory.usedBytes)
    }

    // MARK: Memory pressure

    func testPressureLevelsMapToTheDispatchLevels() {
        XCTAssertEqual(MemoryPressure.from(level: 1), .available(.normal))
        XCTAssertEqual(MemoryPressure.from(level: 2), .available(.warning))
        XCTAssertEqual(MemoryPressure.from(level: 4), .available(.critical))
        for unknown: Int32 in [0, 3, 8, -1] {
            XCTAssertEqual(MemoryPressure.from(level: unknown), .unavailable(.inconsistentValues), "\(unknown) is never guessed")
        }
        // Same numbers as the public DispatchSource levels.
        XCTAssertEqual(DispatchSource.MemoryPressureEvent.normal.rawValue, 1)
        XCTAssertEqual(DispatchSource.MemoryPressureEvent.warning.rawValue, 2)
        XCTAssertEqual(DispatchSource.MemoryPressureEvent.critical.rawValue, 4)
    }

    func testPressureWordingNeverDefaultsToNormal() {
        XCTAssertEqual(SystemWidgetPresentation.memoryPressureText(.available(.normal)), "정상")
        XCTAssertEqual(SystemWidgetPresentation.memoryPressureText(.available(.warning)), "주의")
        XCTAssertEqual(SystemWidgetPresentation.memoryPressureText(.available(.critical)), "높음")
        XCTAssertEqual(SystemWidgetPresentation.memoryPressureText(.unavailable(.readFailed(ENOENT))), "확인 불가")
        XCTAssertEqual(SystemWidgetPresentation.memoryPressureText(.unavailable(.inconsistentValues)), "확인 불가")
        XCTAssertEqual(SystemWidgetPresentation.memoryPressureText(nil), "확인 불가")
    }

    func testRealPressureReadOnThisMac() {
        let value = MemoryPressure.readSystem()
        XCTAssertNotNil(value.value, "kern.memorystatus_vm_pressure_level should be readable: \(value)")
    }

    private final class Scheduler: SystemMonitorScheduling {
        final class Job: SystemMonitorCancellable { var cancelled = false; func cancel() { cancelled = true } }
        var jobs: [Job] = []
        var active: Int { jobs.filter { !$0.cancelled }.count }
        func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { let j = Job(); jobs.append(j); return j }
        func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { let j = Job(); jobs.append(j); return j }
        func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { let j = Job(); jobs.append(j); return j }
    }

    private struct MemorySampler: SystemSampler {
        func sample() async throws -> SystemSnapshot {
            SystemSnapshot(sampledAt: Date(), cpu: .unavailable(.awaitingBaseline),
                           memory: .available(MemoryUsage(totalBytes: 100, usedBytes: 70, appBytes: 40, wiredBytes: 20,
                                                          compressedBytes: 10, cachedFilesBytes: 15)))
        }
    }

    /// A failing pressure read is "확인 불가" and does not touch the RAM usage value; pressure is cleared with RAM off.
    func testPressureFailureLeavesUsageIntactAndIsCleared() async {
        var reads = 0
        let store = SystemMonitorStore(makeSampler: { MemorySampler() }, scheduler: Scheduler(),
                                       memoryPressure: { reads += 1; return .unavailable(.readFailed(EPERM)) })
        XCTAssertNil(store.memoryPressure, "RAM off: not read")
        store.setEnabled(.memory, true)
        await store.pendingSample?.value
        XCTAssertEqual(store.memory?.value?.usedBytes, 70, "Usage unaffected by the pressure failure")
        XCTAssertEqual(store.memoryPressure, .unavailable(.readFailed(EPERM)))
        XCTAssertEqual(reads, 1, "One read per RAM sample")
        store.setEnabled(.memory, false)
        XCTAssertNil(store.memoryPressure)
        XCTAssertNil(store.memory)
    }

    func testPressureIsReadOnlyWithRAM() async {
        var reads = 0
        let store = SystemMonitorStore(makeSampler: { MemorySampler() }, scheduler: Scheduler(),
                                       memoryPressure: { reads += 1; return .available(.warning) })
        store.setEnabled(.cpu, true)
        await store.pendingSample?.value
        XCTAssertEqual(reads, 0, "CPU alone does not read memory pressure")
        XCTAssertNil(store.memoryPressure)
        // (With CPU running, RAM joins on the next 1 s tick; start RAM alone to sample at once.)
        store.setEnabled(.cpu, false)
        store.setEnabled(.memory, true)
        await store.pendingSample?.value
        XCTAssertEqual(store.memoryPressure, .available(.warning))
        XCTAssertEqual(reads, 1)
        store.setEnabled(.memory, false)
    }

    // MARK: TOP 5

    func testMemoryRowsSortedLimitedAndFormatted() {
        let entries = (1...7).map { ProcessMemoryEntry(pid: Int32($0), name: "p\($0)", footprintBytes: UInt64($0 % 4) * gib + UInt64($0), startTicks: UInt64($0 * 10)) }
        let rows = SystemWidgetPresentation.memoryTopRows(entries)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.pid), [7, 3, 6, 2, 5], "Largest footprint first")
        XCTAssertEqual(rows.first?.startTicks, 70)
        XCTAssertEqual(rows.first?.bytesText, SystemWidgetPresentation.processMemoryText(3 * gib + 7))
    }

    func testCalculatorKeepsMemoryStartTicks() {
        let current = ProcessRawSnapshot(uptimeNanoseconds: 1, entries: [
            ProcessRawEntry(pid: 3, name: "x", startTicks: 999, userTicks: 0, systemTicks: 0, footprintBytes: 5)], permissionDeniedCount: 0)
        let top = ProcessTopCalculator.calculate(previous: nil, current: current, timebaseNumer: 1, timebaseDenom: 1)
        XCTAssertEqual(top.memory.first?.startTicks, 999)
    }

    // MARK: Full process names

    func testFullNameOnlyForKernelTruncatedNames() {
        let cut = "com.apple.Virtualization.Virtua"
        XCTAssertEqual(cut.count, ProcessNames.kernelLimit, "31 characters: the kernel field is full")
        XCTAssertEqual(ProcessNames.full(reported: cut) { "com.apple.Virtualization.VirtualMachine" }, "com.apple.Virtualization.VirtualMachine")
        // Not a continuation of the reported name: keep what the kernel reported.
        XCTAssertEqual(ProcessNames.full(reported: cut) { "something-else" }, cut)
        XCTAssertEqual(ProcessNames.full(reported: cut) { nil }, cut, "Path unreadable: safe fallback")
        // Short names are never looked up.
        var asked = false
        XCTAssertEqual(ProcessNames.full(reported: "Finder") { asked = true; return "Finder-long" }, "Finder")
        XCTAssertFalse(asked)
    }

    func testExecutableNameForThisProcess() {
        let name = LiveProcessReader.executableName(ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(name, "Tokenly", "Test host executable")
        XCTAssertNil(LiveProcessReader.executableName(-1))
    }

    // MARK: Popover lifecycle → memory scan

    private struct NoProcesses: ProcessTopSampling {
        func sample() async throws -> SystemMetric<ProcessTopSnapshot> {
            .available(ProcessTopSnapshot(cpu: [], memory: [], cpuHasBaseline: false, readableCount: 0, permissionDeniedCount: 0))
        }
    }

    func testRAMPopoverStartsAndStopsTheScanOnce() {
        let suite = "tokenly.rampopover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let scheduler = Scheduler()
        let controller = SystemWidgetController(store: SystemMonitorStore(makeSampler: { MemorySampler() }, scheduler: Scheduler()),
                                                processTop: ProcessTopStore(makeSampler: { NoProcesses() }, scheduler: scheduler),
                                                defaults: defaults, supportProbe: { _ in .supported })
        defer {
            for widget in SystemWidget.allCases { controller.setInserted(widget, false) }
            defaults.removePersistentDomain(forName: suite)
        }
        SystemPopoverVisibility.set(.memory, visible: true, controller: controller, source: "appear")
        XCTAssertEqual(scheduler.active, 0, "RAM widget off: no scan")
        controller.setInserted(.memory, true)
        for _ in 0..<3 {
            SystemPopoverVisibility.set(.memory, visible: true, controller: controller, source: "appear")
            SystemPopoverVisibility.set(.memory, visible: true, controller: controller, source: "window")
            XCTAssertEqual(scheduler.active, 1)
            SystemPopoverVisibility.set(.memory, visible: false, controller: controller, source: "disappear")
            SystemPopoverVisibility.set(.memory, visible: false, controller: controller, source: "window")
            XCTAssertEqual(scheduler.active, 0)
        }
        // CPU and RAM popovers open together share one scan.
        controller.setInserted(.cpu, true)
        SystemPopoverVisibility.set(.memory, visible: true, controller: controller, source: "appear")
        SystemPopoverVisibility.set(.cpu, visible: true, controller: controller, source: "appear")
        XCTAssertEqual(scheduler.active, 1)
        SystemPopoverVisibility.set(.memory, visible: false, controller: controller, source: "disappear")
        XCTAssertEqual(scheduler.active, 1, "Still needed by the CPU popover")
        controller.setInserted(.cpu, false)
        XCTAssertEqual(scheduler.active, 0, "Removing the CPU widget releases its key")
    }

    func testPaletteIsTheConfirmedHex() {
        func hex(_ color: Color) -> String {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        XCTAssertEqual(hex(RAMPopoverView.appColor), "A5E2D7")
        XCTAssertEqual(hex(RAMPopoverView.wiredColor), "A8CDF4")
        XCTAssertEqual(hex(RAMPopoverView.compressedColor), "C5B3EE")
        XCTAssertEqual(hex(RAMPopoverView.availableColor), "737782")
    }

    // MARK: Pressure badge colours

    private func contrast(_ a: AuroraPalette.RGB, _ b: AuroraPalette.RGB) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ c: AuroraPalette.RGB) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testPressureBadgeColoursPerStateAndTheme() {
        func hex(_ c: AuroraPalette.RGB) -> String { String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
        let states: [SystemMetric<MemoryPressure>?] = [.available(.normal), .available(.warning), .available(.critical),
                                                       .unavailable(.readFailed(EPERM)), .unavailable(.inconsistentValues), nil]
        // Dark: the approved values.
        let dark = states.map { RAMPopoverView.pressureBadge($0, dark: true) }
        XCTAssertEqual(dark.prefix(4).map { hex($0.text) + "/" + hex($0.background) },
                       ["A5E2D7/254A46", "F4D39A/53452F", "F2B1C4/593A46", "C1C4CD/41444B"])
        XCTAssertEqual(hex(dark[4].text), "C1C4CD", "Inconsistent value: neutral grey, never mint")
        XCTAssertEqual(hex(dark[5].text), "C1C4CD", "Not measured: neutral grey")
        // Each state looks different from the others, in both themes; text always readable on its background.
        for isDark in [true, false] {
            let badges = states.prefix(4).map { RAMPopoverView.pressureBadge($0, dark: isDark) }
            XCTAssertEqual(Set(badges.map { hex($0.background) }).count, 4, "dark=\(isDark): four distinct states")
            for (state, badge) in zip(states, states.map { RAMPopoverView.pressureBadge($0, dark: isDark) }) {
                XCTAssertGreaterThanOrEqual(contrast(badge.text, badge.background), 4.5, "dark=\(isDark) \(String(describing: state))")
            }
        }
        // Words stay with the colours: colour is never the only signal.
        XCTAssertEqual(states.map { SystemWidgetPresentation.memoryPressureText($0) }, ["정상", "주의", "높음", "확인 불가", "확인 불가", "확인 불가"])
    }
}
