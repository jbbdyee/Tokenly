import IOKit
import SwiftUI
import XCTest
@testable import Tokenly

/// 6-4e Disk popover: APFS space split, read/write speeds and their failure cases, graph scale and gaps, the store's
/// 1-second activity job, and the drive behind `/` on this Mac.
@MainActor
final class DiskActivityTests: XCTestCase {
    private func usage(total: UInt64, free: UInt64, important: SystemMetric<UInt64>) -> DiskUsage {
        DiskUsage(totalBytes: total, availableBytes: free, availableForImportantUsageBytes: important)
    }

    // MARK: Space

    func testHeadlineIsTheMenuBarValue() {
        for (free, important) in [(45_718_515_712, 59_659_565_027), (0, 0), (10, 245_107_195_904), (121_640_000_000, 138_920_000_000)] as [(UInt64, UInt64)] {
            let metric = SystemMetric<DiskUsage>.available(usage(total: 245_107_195_904, free: min(free, important), important: .available(important)))
            guard case .percent(let widget) = SystemWidgetPresentation.disk(metric).value else { return XCTFail("\(free)") }
            XCTAssertEqual(DiskPopoverPresentation.headline(metric).value, "\(widget)")
            XCTAssertNil(DiskPopoverPresentation.headline(metric).note)
        }
        XCTAssertEqual(DiskPopoverPresentation.headline(nil).value, "—")
        XCTAssertEqual(DiskPopoverPresentation.headline(nil).note, "측정 중")
        XCTAssertEqual(DiskPopoverPresentation.headline(.unavailable(.readFailed(5))).note, "확인 불가")
        // No estimate: the menu bar shows "—" (§7.5) and so does the popover; never the conservative number.
        let noEstimate = SystemMetric<DiskUsage>.available(usage(total: 1_000, free: 250, important: .unavailable(.unsupported)))
        XCTAssertEqual(DiskPopoverPresentation.headline(noEstimate).value, "—")
    }

    func testBreakdownPartsAddUpToTheTotalInRawBytes() {
        // This Mac's read on 2026-10-28.
        let disk = usage(total: 245_107_195_904, free: 45_719_699_456, important: .available(59_659_565_027))
        let parts = try! XCTUnwrap(DiskSpaceBreakdown.make(disk))
        XCTAssertEqual(parts.used, 245_107_195_904 - 59_659_565_027)
        XCTAssertEqual(parts.reclaimable, 59_659_565_027 - 45_719_699_456)
        XCTAssertEqual(parts.freeNow, 45_719_699_456)
        XCTAssertEqual(parts.used + parts.reclaimable + parts.freeNow, parts.total, "Three parts, no overlap, no rest")
        XCTAssertEqual(parts.available, 59_659_565_027, "사용 가능 = 지금 비어 있음 + 확보 가능 (추정)")
        let f = parts.fractions
        XCTAssertEqual(f.used + f.reclaimable + f.freeNow, 1, accuracy: 1e-12)
        XCTAssertEqual(f.used, 185_447_630_877 / 245_107_195_904, accuracy: 1e-12, "Bar from raw bytes")
        // The rounded labels may differ by 0.1 GB from the sum of rounded parts; the bytes do not.
        XCTAssertEqual(DiskPopoverPresentation.size(parts.available), "59.7 GB")
    }

    func testBreakdownRejectsContradictoryValues() {
        XCTAssertNil(DiskSpaceBreakdown.make(usage(total: 1_000, free: 300, important: .available(200))), "Estimate below free space")
        XCTAssertNil(DiskSpaceBreakdown.make(usage(total: 1_000, free: 300, important: .available(1_200))), "Estimate above total")
        XCTAssertNil(DiskSpaceBreakdown.make(usage(total: 1_000, free: 300, important: .unavailable(.unsupported))))
        XCTAssertNil(DiskSpaceBreakdown.make(usage(total: 0, free: 0, important: .available(0))))
        let full = try! XCTUnwrap(DiskSpaceBreakdown.make(usage(total: 1_000, free: 0, important: .available(0))))
        XCTAssertEqual([full.used, full.reclaimable, full.freeNow], [1_000, 0, 0], "A full disk is valid")
        let same = try! XCTUnwrap(DiskSpaceBreakdown.make(usage(total: 1_000, free: 400, important: .available(400))))
        XCTAssertEqual(same.reclaimable, 0)
    }

    func testDecimalUnits() {
        XCTAssertEqual(DiskPopoverPresentation.size(245_107_195_904), "245.1 GB")
        XCTAssertEqual(DiskPopoverPresentation.size(999_949_999_999), "999.9 GB")
        XCTAssertEqual(DiskPopoverPresentation.size(1_000_000_000_000), "1.00 TB")
        XCTAssertEqual(DiskPopoverPresentation.size(0), "0.0 GB")
        XCTAssertEqual(DiskPopoverPresentation.rate(0), "0 MB/s", "A measured 0 stays 0")
        XCTAssertEqual(DiskPopoverPresentation.rate(0.04), "<0.1 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(3.17), "3.2 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(52.7), "53 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(2_450), "2.45 GB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(nil), "—")
        XCTAssertEqual(DiskPopoverPresentation.rate(.nan), "—")
    }

    /// Boundaries of the one speed formatter (read and write): real 0, tiny non-zero, 0.1, failure.
    func testSpeedBoundaries() {
        XCTAssertEqual(DiskPopoverPresentation.rate(0), "0 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(1e-9), "<0.1 MB/s", "One byte per second is not 0")
        XCTAssertEqual(DiskPopoverPresentation.rate(0.0999), "<0.1 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(0.1), "0.1 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(9.94), "9.9 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(10), "10 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(999), "999 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(1000), "1.00 GB/s")
        XCTAssertEqual(DiskPopoverPresentation.rate(-0.5), "—")
        XCTAssertEqual(DiskPopoverPresentation.rate(.infinity), "—")
        let tiny = DiskActivityRate(readBytesPerSecond: 50_000, writeBytesPerSecond: 50_000)
        XCTAssertEqual(DiskPopoverPresentation.activityValue(.available(tiny), write: false), "<0.1 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.activityValue(.available(tiny), write: true), "<0.1 MB/s", "Same rule for write")
        let idle = DiskActivityRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)
        XCTAssertEqual(DiskPopoverPresentation.activityValue(.available(idle), write: true), "0 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.activityValue(.unavailable(.readFailed(5)), write: true), "확인 불가")
    }

    func testHelpTextAndDeviceSummary() {
        let help = DiskPopoverPresentation.help
        for phrase in ["시스템 추정치", "APFS 공유 공간", "로컬 스냅샷", "Finder나 시스템 설정"] { XCTAssertTrue(help.contains(phrase), phrase) }
        XCTAssertFalse(help.contains("purgeable 총량"))
        var info = DiskDeviceInfo(volumeName: "Macintosh HD", fileSystem: "APFS", isInternal: true, medium: .solidState)
        XCTAssertEqual(info.summary, "Macintosh HD · APFS · 내장 SSD")
        info.isInternal = nil
        XCTAssertEqual(info.summary, "Macintosh HD · APFS · SSD", "Unknown placement is left out")
        info.medium = nil
        XCTAssertEqual(info.summary, "Macintosh HD · APFS")
        XCTAssertNil(DiskDeviceInfo().summary)
        XCTAssertEqual(DiskDeviceInfo(isInternal: false, medium: .rotational).summary, "외장 HDD")
        XCTAssertEqual(DiskDeviceInfo.fileSystemName("apfs"), "APFS")
        XCTAssertNil(DiskDeviceInfo.fileSystemName(" "))
        XCTAssertNil(DiskDeviceInfo.medium("Unknown"))
        XCTAssertNil(DiskDeviceInfo.isInternal("File"))
    }

    // MARK: Speed

    private func counters(_ read: UInt64, _ written: UInt64, at time: TimeInterval, device: UInt64 = 7) -> DiskActivityRead {
        .counters(DiskActivityCounters(device: device, bytesRead: read, bytesWritten: written, time: time))
    }

    func testRateFromBytesOverRealElapsedTime() {
        var tracker = DiskActivityRateTracker()
        XCTAssertEqual(tracker.update(counters(1_000, 5_000, at: 10)), .unavailable(.awaitingBaseline), "First read: baseline only")
        let rate = tracker.update(counters(1_000 + 3_000_000, 5_000 + 550_000, at: 11.1)).value
        XCTAssertEqual(try XCTUnwrap(rate).readMBps, 3.0 / 1.1, accuracy: 1e-9, "Divided by 1.1 s, not 1 s")
        XCTAssertEqual(try XCTUnwrap(rate).writeMBps, 0.55 / 1.1, accuracy: 1e-9)
        XCTAssertEqual(tracker.update(counters(3_001_000, 555_000, at: 12.1)), .available(DiskActivityRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)),
                       "Unchanged counters are a real 0 MB/s")
    }

    func testFailuresNeverBecomeZeroAndReBaseline() {
        var tracker = DiskActivityRateTracker()
        _ = tracker.update(counters(0, 0, at: 1))
        XCTAssertEqual(tracker.update(.unavailable(.readFailed(kIOReturnNotFound))), .unavailable(.readFailed(kIOReturnNotFound)))
        XCTAssertNil(tracker.baseline)
        XCTAssertEqual(tracker.update(counters(9_000_000, 0, at: 2)), .unavailable(.awaitingBaseline), "No speed across a failure")
        XCTAssertNotNil(tracker.update(counters(10_000_000, 0, at: 3)).value)
        XCTAssertEqual(tracker.update(.unavailable(.unsupported)), .unavailable(.unsupported), "No drive matched ≠ idle")
    }

    func testCounterDecreaseDeviceChangeSleepAndBadIntervals() {
        var tracker = DiskActivityRateTracker()
        _ = tracker.update(counters(5_000, 5_000, at: 1))
        XCTAssertEqual(tracker.update(counters(4_000, 6_000, at: 2)), .unavailable(.counterReset))
        XCTAssertNotNil(tracker.update(counters(4_500, 6_000, at: 3)).value, "Re-baselined at the lower value")

        XCTAssertEqual(tracker.update(counters(9_000, 9_000, at: 4, device: 8)), .unavailable(.awaitingBaseline), "Another drive")
        XCTAssertNotNil(tracker.update(counters(9_500, 9_000, at: 5, device: 8)).value)

        // Sleep: the monotonic clock kept counting, so the interval is long; never one average across it.
        XCTAssertEqual(tracker.update(counters(900_000_000, 9_000, at: 5 + 3_600)), .unavailable(.awaitingBaseline))
        XCTAssertNotNil(tracker.update(counters(900_000_000, 9_000, at: 3_606)).value)
        XCTAssertEqual(tracker.update(counters(900_000_000, 9_000, at: 3_606 + DiskActivityRateTracker.maxInterval)).value?.readMBps, 0,
                       "Exactly the limit is still one interval")

        XCTAssertEqual(tracker.update(counters(900_000_000, 9_000, at: 3_000)), .unavailable(.noElapsedTicks), "Clock went back")
        XCTAssertEqual(tracker.update(counters(900_000_000, 9_000, at: 3_000)), .unavailable(.noElapsedTicks), "Zero interval")

        XCTAssertEqual(tracker.update(counters(900_000_000 + 500_000_000_000, 9_000, at: 3_001)), .unavailable(.inconsistentValues),
                       "500 GB in a second is not a transfer")
        XCTAssertNotNil(tracker.update(counters(900_000_000 + 500_000_000_000, 9_000, at: 3_002)).value)
    }

    // MARK: Graph

    func testScaleIsAStableStepAboveThePeakAndNeverBelowOne() {
        let cases: [(Double, Double)] = [(0, 1), (0.05, 1), (1, 1), (1.2, 2), (2, 2), (3, 5), (7, 10), (10, 10), (12.6, 20),
                                         (52.7, 100), (140, 200), (480, 500), (1_500, 2_000), (7_000, 10_000)]
        for (peak, top) in cases { XCTAssertEqual(DiskActivityScale.upperBound(peak: peak), top, "\(peak)") }
        var history = SystemMetricHistory()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for (i, value) in ([0.2, nil, 3.4, 0.1] as [Double?]).enumerated() { history.append(value, at: start.addingTimeInterval(Double(i))) }
        XCTAssertEqual(DiskActivityScale.upperBound(history), 5, "Gaps are ignored, the peak sets the step")
        XCTAssertEqual(DiskActivityScale.upperBound(SystemMetricHistory()), 1, "No data: the floor, no invented activity")
        XCTAssertEqual(DiskPopoverPresentation.scaleLabel(5), "눈금 상한 5 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.scaleLabel(2_000), "눈금 상한 2 GB/s")
    }

    func testLaneScalingKeepsGapsAndTheSixtySecondWindow() {
        var history = SystemMetricHistory()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for i in 0..<90 where !(70...72).contains(i) { history.append(i == 80 ? nil : 4, at: start.addingTimeInterval(Double(i))) }
        XCTAssertLessThanOrEqual(history.points.count, 60, "Only the last 60 s are kept")
        let scaled = DiskActivityLane.scaled(history, top: 5)
        XCTAssertEqual(scaled.points.map(\.date), history.points.map(\.date))
        XCTAssertEqual(scaled.points.compactMap(\.value).first, 80, "4 MB/s on a 5 MB/s scale = 80 %")
        let layout = AuroraGraphLayout(history: scaled, size: CGSize(width: 312, height: 38))
        XCTAssertEqual(layout.segments.count, 3, "Split at the 4 s pause and at the failed second; no fake 0")
        XCTAssertFalse(layout.segments.flatMap { $0 }.contains { $0.y == 38 }, "Nothing drawn at 0")
    }

    // MARK: Store

    func testStoreActivityLifecycle() async {
        let harness = StoreHarness()
        harness.activity.reads = [counters(0, 0, at: 1), counters(2_000_000, 1_000_000, at: 2), .unavailable(.readFailed(5)),
                                  counters(9_000_000, 1_000_000, at: 4), counters(9_000_000, 1_000_000, at: 5)]
        harness.store.setEnabled(.disk, true)
        await harness.settle()
        XCTAssertEqual(harness.activity.calls, 1, "One read on enable")
        XCTAssertEqual(harness.store.diskActivity, .unavailable(.awaitingBaseline))
        XCTAssertTrue(harness.store.diskReadHistory.points.isEmpty, "The baseline adds no point")
        XCTAssertEqual(harness.store.diskDevice?.summary, "Macintosh HD · APFS · 내장 SSD")
        XCTAssertEqual(harness.scheduler.intervals.sorted(), [SystemMonitorStore.diskActivityInterval, SystemMonitorStore.diskInterval])

        for _ in 0..<4 {
            harness.now = harness.now.addingTimeInterval(1)
            harness.scheduler.fire(SystemMonitorStore.diskActivityInterval)
            await harness.settle()
        }
        XCTAssertEqual(harness.activity.calls, 5)
        XCTAssertEqual(harness.store.diskReadHistory.points.map(\.value), [2, nil, 0], "Speed, failure gap, re-baseline (no point), real 0")
        XCTAssertEqual(harness.store.diskWriteHistory.points.map(\.value), [1, nil, 0])
        XCTAssertEqual(harness.store.diskActivity?.value?.readMBps, 0)
        XCTAssertEqual(harness.disk.calls, 1, "Capacity stays on its 60 s timer")

        harness.store.setEnabled(.disk, false)
        XCTAssertTrue(harness.scheduler.intervals.isEmpty, "Both jobs stop")
        XCTAssertNil(harness.store.diskActivity)
        XCTAssertNil(harness.store.diskDevice)
        XCTAssertTrue(harness.store.diskReadHistory.points.isEmpty && harness.store.diskWriteHistory.points.isEmpty)
        harness.scheduler.fire(SystemMonitorStore.diskActivityInterval)
        XCTAssertEqual(harness.activity.calls, 5, "Off: no polling")
    }

    func testStoreNeverRunsTwoActivityReadsOrKeepsALateOne() async {
        let harness = StoreHarness()
        harness.activity.gated = true
        for _ in 0..<3 { harness.store.setEnabled(.disk, true) }
        while harness.activity.waiting == 0 { await Task.yield() }
        for _ in 0..<3 { harness.scheduler.fire(SystemMonitorStore.diskActivityInterval) }
        XCTAssertEqual(harness.activity.calls, 1, "A read in flight blocks the next tick")
        XCTAssertEqual(harness.scheduler.intervals.filter { $0 == SystemMonitorStore.diskActivityInterval }.count, 1, "One timer")

        let inFlight = harness.store.pendingDiskActivitySample
        harness.store.setEnabled(.disk, false)
        harness.activity.release()
        await inFlight?.value
        XCTAssertNil(harness.store.diskActivity, "A read finishing after Disk was turned off is dropped")
        XCTAssertNil(harness.store.diskDevice)
    }

    func testNoMatchedDriveIsUnavailableNotIdle() async {
        let harness = StoreHarness()
        harness.activity.reads = [.unavailable(.unsupported)]
        harness.store.setEnabled(.disk, true)
        await harness.settle()
        XCTAssertEqual(DiskPopoverPresentation.activityValue(harness.store.diskActivity, write: false), "확인 불가")
        XCTAssertEqual(DiskPopoverPresentation.activityValue(.available(DiskActivityRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)), write: true), "0 MB/s")
        XCTAssertEqual(DiskPopoverPresentation.activityValue(nil, write: true), "측정 중")
        XCTAssertEqual(harness.store.diskReadHistory.points.map(\.value), [nil], "A gap, never 0")
    }

    // MARK: This Mac

    /// The real sampler finds one non-virtual drive under `/` and reads growing counters from it (read-only).
    func testRealDriveBehindTheSystemVolume() async throws {
        let located = try DiskActivitySampler.locate(path: "/").get()
        XCTAssertNotEqual(located.registryID, 0)
        let sampler = DiskActivitySampler()
        let first = await sampler.sample(), second = await sampler.sample()
        guard case .counters(let a) = first.read, case .counters(let b) = second.read else { return XCTFail("\(first.read) \(second.read)") }
        XCTAssertEqual(a.device, located.registryID)
        XCTAssertEqual(a.device, b.device)
        XCTAssertGreaterThanOrEqual(b.bytesRead, a.bytesRead)
        XCTAssertGreaterThan(b.time, a.time)
        XCTAssertEqual(first.device?.fileSystem, "APFS")
        XCTAssertNotNil(first.device?.volumeName)
        if case .success = DiskActivitySampler.locate(path: "/dev") { XCTFail("devfs has no drive behind it") }
    }
}

// MARK: - Doubles

private final class ScriptedDiskActivity: DiskActivitySampling {
    var reads: [DiskActivityRead] = [.unavailable(.unsupported)]
    var gated = false
    private(set) var calls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { continuations.count }

    func sample() async -> DiskActivitySample {
        let read = reads[min(calls, reads.count - 1)]
        calls += 1
        if gated { await withCheckedContinuation { continuations.append($0) } }
        return DiskActivitySample(read: read, device: DiskDeviceInfo(volumeName: "Macintosh HD", fileSystem: "APFS", isInternal: true, medium: .solidState))
    }

    func release() {
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private final class FixedDisk: DiskSampling {
    private(set) var calls = 0
    func sample() async -> SystemMetric<DiskUsage> {
        calls += 1
        return .available(DiskUsage(totalBytes: 1_000, availableBytes: 250, availableForImportantUsageBytes: .available(400)))
    }
}

@MainActor
private final class TimerScheduler: SystemMonitorScheduling {
    final class Job: SystemMonitorCancellable {
        let interval: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private var jobs: [Job] = []
    var intervals: [TimeInterval] { jobs.filter { !$0.cancelled }.map(\.interval) }

    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let job = Job(interval, action)
        jobs.append(job)
        return job
    }

    func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { Job(delay, action) }
    func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { Job(-1, action) }

    func fire(_ interval: TimeInterval) {
        for job in jobs where job.interval == interval && !job.cancelled { job.action() }
    }
}

@MainActor
private final class StoreHarness {
    let scheduler = TimerScheduler()
    let activity = ScriptedDiskActivity()
    let disk = FixedDisk()
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private(set) lazy var store = SystemMonitorStore(disk: disk, diskActivity: activity, scheduler: scheduler,
                                                     now: { [unowned self] in self.now })

    func settle() async {
        await store.pendingDiskSample?.value
        await store.pendingDiskActivitySample?.value
    }
}
