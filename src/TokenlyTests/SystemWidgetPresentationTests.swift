import IOKit
import XCTest
@testable import Tokenly

final class SystemWidgetPresentationTests: XCTestCase {
    private func usage(_ percent: Double) -> SystemMetric<CPUUsage> {
        .available(CPUUsage(totalPercent: percent, userPercent: percent, systemPercent: 0))
    }

    private func memory(used: UInt64, total: UInt64 = 1_000) -> SystemMetric<MemoryUsage> {
        .available(MemoryUsage(totalBytes: total, usedBytes: used, appBytes: used, wiredBytes: 0, compressedBytes: 0,
                               cachedFilesBytes: 0))
    }

    private func disk(total: UInt64, available: UInt64, important: SystemMetric<UInt64>) -> SystemMetric<DiskUsage> {
        .available(DiskUsage(totalBytes: total, availableBytes: available, availableForImportantUsageBytes: important))
    }

    private func power(_ percent: SystemMetric<Int>, connected: SystemMetric<Bool> = .available(true),
                       charging: SystemMetric<Bool>, full: SystemMetric<Bool> = .available(false)) -> SystemMetric<BatteryPowerState> {
        .available(BatteryPowerState(chargePercent: percent, isExternalPowerConnected: connected, isCharging: charging,
                                     isAtFullCapacity: full))
    }

    // MARK: CPU, RAM, GPU

    func testUsageIsAnIntegerPercentInRange() {
        XCTAssertEqual(SystemWidgetPresentation.cpu(usage(23.6)).text, "24%")
        XCTAssertEqual(SystemWidgetPresentation.cpu(usage(0)).text, "0%")
        XCTAssertEqual(SystemWidgetPresentation.cpu(usage(100)).text, "100%")
        XCTAssertEqual(SystemWidgetPresentation.cpu(usage(100.4)).value, .percent(100))
        XCTAssertEqual(SystemWidgetPresentation.memory(memory(used: 714)).text, "71%")
        XCTAssertEqual(SystemWidgetPresentation.gpu(.available(17.5)).text, "18%")
    }

    func testNotYetMeasuredIsADimmedDash() {
        let displays = [SystemWidgetPresentation.cpu(nil), SystemWidgetPresentation.memory(nil),
                        SystemWidgetPresentation.disk(nil), SystemWidgetPresentation.gpu(nil)]
        for display in displays {
            XCTAssertEqual(display.value, .loading)
            XCTAssertEqual(display.text, "—", "No % sign without a value")
            XCTAssertTrue(display.isDimmed)
        }
    }

    func testUnavailableIsADashNotZero() {
        let cpu = SystemWidgetPresentation.cpu(.unavailable(.awaitingBaseline))
        XCTAssertEqual(cpu.value, .unavailable)
        XCTAssertEqual(cpu.text, "—")
        XCTAssertFalse(cpu.isDimmed)
        XCTAssertEqual(SystemWidgetPresentation.memory(.unavailable(.inconsistentValues)).text, "—")
        XCTAssertEqual(SystemWidgetPresentation.gpu(.unavailable(.readFailed(kIOReturnNoResources))).text, "—",
                       "A failed GPU read is never 0 %")
        XCTAssertEqual(SystemWidgetPresentation.gpu(.unavailable(.insufficientSamples)).value, .unavailable)
        XCTAssertEqual(SystemWidgetPresentation.gpu(.available(.nan)).value, .unavailable)
    }

    // MARK: Disk

    func testDiskUsesTheImportantUsageBasisNotTheConservativeOne() {
        // Free 20 of 100 (conservative 80 % used), 27 available for important usage (73 % used).
        let value = disk(total: 100, available: 20, important: .available(27))
        XCTAssertEqual(SystemWidgetPresentation.disk(value).text, "73%")
        XCTAssertEqual(value.value?.usedFraction, 0.8, "The conservative fraction exists but is not what the menu bar shows")

        let measured = disk(total: 245_107_195_904, available: 51_845_816_320, important: .available(65_550_000_000))
        XCTAssertEqual(SystemWidgetPresentation.disk(measured).text, "73%", "Mac16,12 values from §3 V6")
    }

    func testDiskWithoutTheImportantUsageValueIsADash() {
        for important in [SystemMetric<UInt64>.unavailable(.unsupported), .unavailable(.inconsistentValues)] {
            let display = SystemWidgetPresentation.disk(disk(total: 100, available: 20, important: important))
            XCTAssertEqual(display.value, .unavailable, "No fallback to the conservative basis")
        }
        XCTAssertEqual(SystemWidgetPresentation.disk(.unavailable(.readFailed(5))).text, "—")
        XCTAssertNil(SystemWidgetPresentation.diskUsedPercent(
            DiskUsage(totalBytes: 100, availableBytes: 20, availableForImportantUsageBytes: .available(101))))
    }

    func testDiskBounds() {
        XCTAssertEqual(SystemWidgetPresentation.disk(disk(total: 100, available: 0, important: .available(0))).text, "100%")
        XCTAssertEqual(SystemWidgetPresentation.disk(disk(total: 100, available: 100, important: .available(100))).text, "0%")
    }

    // MARK: Battery

    func testBatteryStatesAreToldApart() {
        XCTAssertEqual(SystemWidgetPresentation.batteryState(nil), .notMeasured)
        XCTAssertEqual(SystemWidgetPresentation.batteryState(.unavailable(.noBattery)), .noBattery)
        XCTAssertEqual(SystemWidgetPresentation.batteryState(.unavailable(.readFailed(kIOReturnError))),
                       .unavailable(.readFailed(kIOReturnError)))
        XCTAssertEqual(SystemWidgetPresentation.batteryState(power(.available(82), charging: .available(false))),
                       .measured(percent: 82, isCharging: false, isFullOnExternalPower: false))
        XCTAssertEqual(SystemWidgetPresentation.batteryState(power(.available(100), charging: .available(false), full: .available(true))),
                       .measured(percent: 100, isCharging: false, isFullOnExternalPower: true))
    }

    /// Final design: the number only, a bolt only while actually charging, no battery outline or level icon.
    func testBatteryDisplayPerState() {
        let loading = SystemWidgetPresentation.battery(nil)
        XCTAssertEqual(loading.value, .loading)
        XCTAssertEqual(loading.text, "—")
        XCTAssertTrue(loading.isDimmed)
        XCTAssertFalse(loading.showsBolt)

        let failed = SystemWidgetPresentation.battery(.unavailable(.readFailed(kIOReturnError)))
        XCTAssertEqual(failed.value, .unavailable)
        XCTAssertEqual(failed.text, "—")
        XCTAssertFalse(failed.isDimmed, "Unavailable is told apart from not yet measured")
        XCTAssertFalse(failed.showsBolt)

        let normal = SystemWidgetPresentation.battery(power(.available(82), connected: .available(false), charging: .available(false)))
        XCTAssertEqual(normal.text, "82%")
        XCTAssertFalse(normal.showsBolt)
    }

    func testBoltOnlyWhileActuallyCharging() {
        let charging = SystemWidgetPresentation.battery(power(.available(57), charging: .available(true)))
        XCTAssertTrue(charging.showsBolt)
        XCTAssertEqual(charging.text, "57%")

        let pluggedNotCharging = SystemWidgetPresentation.battery(power(.available(80), charging: .available(false)))
        XCTAssertFalse(pluggedNotCharging.showsBolt, "Connected but held: no bolt")
        XCTAssertEqual(pluggedNotCharging.text, "80%")

        let unknown = SystemWidgetPresentation.battery(power(.available(80), charging: .unavailable(.unsupported)))
        XCTAssertFalse(unknown.showsBolt, "Unknown charging state: number without a bolt")
        XCTAssertEqual(unknown.text, "80%")

        let chargingWithoutLevel = SystemWidgetPresentation.battery(power(.unavailable(.unsupported), charging: .available(true)))
        XCTAssertEqual(chargingWithoutLevel.text, "—", "No charge level: a plain dash")
        XCTAssertFalse(chargingWithoutLevel.showsBolt)

        for widget in [SystemWidget.cpu, .memory, .disk, .gpu] {
            XCTAssertFalse(SystemWidgetDisplay(widget: widget, value: .percent(50)).showsBolt)
        }
    }

    /// The 6-3 bolt policy, every combination of external power × charging × raw full capacity (§7.1).
    func testBoltPolicyCombinations() {
        typealias Case = (connected: SystemMetric<Bool>, charging: SystemMetric<Bool>, full: SystemMetric<Bool>,
                          percent: Int, bolt: SystemWidgetDisplay.Bolt, note: String)
        let unknown = SystemMetric<Bool>.unavailable(.unsupported)
        let cases: [Case] = [
            (.available(false), .available(false), .available(false), 82, .none, "on battery: 82%"),
            (.available(false), .available(false), .available(true), 100, .none, "on battery and full: no bolt"),
            (.available(true), .available(true), .available(false), 82, .charging, "charging: ⚡82%"),
            (.available(true), .available(true), .available(true), 100, .charging, "charging wins at 100"),
            (.available(true), .available(false), .available(true), 100, .fullOnExternalPower, "plugged in and full: ⚡100%"),
            (.available(true), .available(false), .available(false), 82, .none, "plugged in, held below full: 82%"),
            (.available(true), .available(false), .available(false), 100, .none, "99.6 % rounded to 100 is not full"),
            (.available(true), unknown, .available(false), 82, .none, "unknown charging: no bolt"),
            (.available(true), .available(false), unknown, 100, .none, "unknown fullness: no bolt"),
            (unknown, .available(false), .available(true), 100, .none, "unknown external power: no bolt"),
            (.available(true), unknown, unknown, 100, .none, "nothing known but the level: no bolt"),
            (.available(false), .available(true), .available(false), 82, .charging, "charging is reported as is"),
        ]
        for item in cases {
            let display = SystemWidgetPresentation.battery(power(.available(item.percent), connected: item.connected,
                                                                 charging: item.charging, full: item.full))
            XCTAssertEqual(display.text, "\(item.percent)%", item.note)
            XCTAssertEqual(display.bolt, item.bolt, item.note)
            XCTAssertEqual(display.showsBolt, item.bolt != .none, item.note)
        }
    }

    func testFullOnExternalPowerNeedsAKnownLevel() {
        let noLevel = SystemWidgetPresentation.battery(power(.unavailable(.inconsistentValues), charging: .available(false),
                                                             full: .available(true)))
        XCTAssertEqual(noLevel.text, "—")
        XCTAssertFalse(noLevel.showsBolt)
        XCTAssertEqual(SystemWidgetDisplay(widget: .battery, value: .percent(100), bolt: .fullOnExternalPower).accessibilityText,
                       "배터리 100%, 전원 연결됨")
    }

    // MARK: Process TOP 5

    func testProcessCPUIsPerCoreAndMayExceedAHundred() {
        XCTAssertEqual(SystemWidgetPresentation.processCPUText(123.44), "123.4%")
        XCTAssertEqual(SystemWidgetPresentation.processCPUText(0.04), "0.0%")
        XCTAssertEqual(SystemWidgetPresentation.processCPUText(.infinity), "—")
        XCTAssertFalse(SystemWidgetPresentation.processMemoryText(1_288_490_189).isEmpty)
    }

    // MARK: Chart segments

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func history(_ values: [Double?]) -> SystemMetricHistory {
        var history = SystemMetricHistory()
        for (index, value) in values.enumerated() { history.append(value, at: start.addingTimeInterval(Double(index))) }
        return history
    }

    private func values(_ segments: [SystemWidgetPresentation.ChartSegment]) -> [[Double]] {
        segments.map { $0.points.map(\.value) }
    }

    func testContinuousValuesAreOneSegment() {
        XCTAssertEqual(values(SystemWidgetPresentation.segments(history([10, 20, 30]))), [[10, 20, 30]])
    }

    func testAGapSplitsTheLine() {
        XCTAssertEqual(values(SystemWidgetPresentation.segments(history([10, 20, nil, 30, nil, nil, 40]))), [[10, 20], [30], [40]])
    }

    func testLeadingAndTrailingGapsAreDropped() {
        let segments = SystemWidgetPresentation.segments(history([nil, nil, 5, 6, nil]))
        XCTAssertEqual(values(segments), [[5, 6]])
        XCTAssertEqual(segments.first?.points.first?.date, start.addingTimeInterval(2), "Points keep their own times")
    }

    func testAllGapsHaveNoSegments() {
        XCTAssertTrue(SystemWidgetPresentation.segments(history([nil, nil, nil])).isEmpty)
        XCTAssertTrue(SystemWidgetPresentation.segments(SystemMetricHistory()).isEmpty)
    }

    func testZeroIsAPointButAGapIsNot() {
        XCTAssertEqual(values(SystemWidgetPresentation.segments(history([0, nil, 0]))), [[0], [0]])
    }

    // MARK: Chart segments across time gaps (review M1)

    /// A history from (seconds after `start`, value) pairs, appended in order with fixed dates.
    private func timed(_ points: [(TimeInterval, Double?)]) -> SystemMetricHistory {
        var history = SystemMetricHistory()
        for (offset, value) in points { history.append(value, at: start.addingTimeInterval(offset)) }
        return history
    }

    func testTimeGapWithoutNilSplitsTheLine() {
        // 1 s × 5, a 20 s pause with no points at all, then 1 s × 3 (the reproduction from the review).
        let points: [(TimeInterval, Double?)] = [(0, 10), (1, 11), (2, 12), (3, 13), (4, 14), (24, 30), (25, 31), (26, 32)]
        let segments = SystemWidgetPresentation.segments(timed(points))
        XCTAssertEqual(values(segments), [[10, 11, 12, 13, 14], [30, 31, 32]])
        XCTAssertEqual(segments[1].points.first?.date, start.addingTimeInterval(24))
    }

    func testGapThresholdBoundary() {
        XCTAssertEqual(SystemWidgetPresentation.chartMaxGap, 2.5)
        XCTAssertEqual(values(SystemWidgetPresentation.segments(timed([(0, 1), (2.4, 2)]))), [[1, 2]], "2.4 s: joined")
        XCTAssertEqual(values(SystemWidgetPresentation.segments(timed([(0, 1), (2.5, 2)]))), [[1, 2]], "exactly 2.5 s: joined")
        XCTAssertEqual(values(SystemWidgetPresentation.segments(timed([(0, 1), (2.6, 2)]))), [[1], [2]], "2.6 s: split")
        // An explicit threshold is honoured.
        XCTAssertEqual(values(SystemWidgetPresentation.segments(timed([(0, 1), (2.4, 2)]), maxGap: 2)), [[1], [2]])
    }

    func testNilAndTimeGapTogether() {
        // nil right before a long pause, a long pause right after a nil, and both at once: no empty segments.
        let points: [(TimeInterval, Double?)] = [(0, 10), (1, 11), (2, nil), (20, 12), (21, 13), (40, 14), (41, nil), (42, nil), (59, 15)]   // within the 60 s window
        XCTAssertEqual(values(SystemWidgetPresentation.segments(timed(points))), [[10, 11], [12, 13], [14], [15]])
        // A single measured point between two long pauses is kept as a one-point segment.
        let lone = SystemWidgetPresentation.segments(timed([(0, 5), (10, 6), (20, 7)]))
        XCTAssertEqual(values(lone), [[5], [6], [7]])
        XCTAssertTrue(lone.allSatisfy { !$0.points.isEmpty })
    }

    func testRegularSecondsStayOneSegmentWithJitter() {
        // Timer jitter (1.0–1.1 s) and one skipped tick (~2 s) stay joined.
        let points: [(TimeInterval, Double?)] = [(0, 1), (1.05, 2), (2.15, 3), (4.1, 4), (5.1, 5)]
        XCTAssertEqual(values(SystemWidgetPresentation.segments(timed(points))), [[1, 2, 3, 4, 5]])
        XCTAssertTrue(SystemWidgetPresentation.segments(timed([(0, nil), (30, nil)])).isEmpty, "All nil: no segments")
    }

    func testSegmentsLeaveTheHistoryUnchanged() {
        let history = timed([(0, 10), (1, nil), (20, 12), (21, 13)])
        let copy = history
        _ = SystemWidgetPresentation.segments(history)
        _ = SystemWidgetPresentation.segments(history, maxGap: 0.5)
        XCTAssertEqual(history, copy)
        XCTAssertEqual(history.points.count, 4)
    }

    /// The same rule for every recorded metric: CPU, RAM and GPU histories from the store are split alike.
    @MainActor
    func testStoreHistoriesUseTheSameRule() {
        // SystemMetricHistory is the one type behind cpuHistory, memoryHistory and gpuHistory; feed each kind of
        // value pattern through a history and check the shared function.
        for metric in ["cpu", "memory", "gpu"] {
            let history = timed([(0, 50), (1, 51), (15, 52), (16, nil), (17, 53)])
            XCTAssertEqual(values(SystemWidgetPresentation.segments(history)), [[50, 51], [52], [53]], metric)
        }
        let store = SystemMonitorStore(makeSampler: { FixedSampler() })
        let histories: [SystemMetricHistory] = [store.cpuHistory, store.memoryHistory, store.gpuHistory]
        XCTAssertTrue(histories.allSatisfy { SystemWidgetPresentation.segments($0).isEmpty }, "Fresh store: nothing to draw")
    }

    private struct FixedSampler: SystemSampler {
        func sample() async throws -> SystemSnapshot {
            SystemSnapshot(sampledAt: Date(), cpu: .unavailable(.awaitingBaseline), memory: .unavailable(.unsupported))
        }
    }
}
