import IOKit
import XCTest
@testable import Tokenly

// MARK: - Test doubles

/// Records every job and fires them only when a test asks.
@MainActor
private final class ManualScheduler: SystemMonitorScheduling {
    final class Job: SystemMonitorCancellable {
        /// `nil` for a power-source observer.
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
    var activeTimers: [Job] { jobs.filter { $0.interval != nil && !$0.isCancelled } }
    var activeObservers: [Job] { jobs.filter { $0.interval == nil && !$0.isCancelled } }

    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let job = Job(interval: interval, action: action)
        jobs.append(job)
        return job
    }

    func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let job = Job(interval: nil, action: action)
        jobs.append(job)
        return job
    }

    final class OneShot: SystemMonitorCancellable {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        private(set) var isCancelled = false
        var hasFired = false

        init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private(set) var oneShots: [OneShot] = []
    var pendingOneShots: [OneShot] { oneShots.filter { !$0.isCancelled && !$0.hasFired } }

    func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let job = OneShot(delay: delay, action: action)
        oneShots.append(job)
        return job
    }

    func fire(every interval: TimeInterval) {
        for job in jobs where job.interval == interval && !job.isCancelled { job.action() }
    }

    func firePowerSourceChange() {
        for job in activeObservers { job.action() }
    }
}

private struct SampleFailure: Error {}

/// Returns scripted snapshots in order; throws when the script runs out or a step says so. Can hold a sample open.
@MainActor
private final class ScriptedSampler: SystemSampler {
    enum Step {
        case snapshot(SystemSnapshot)
        case failure
    }

    private var steps: [Step]
    private let gated: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    var waitingCount: Int { waiting.count }

    init(steps: [Step], gated: Bool) {
        self.steps = steps
        self.gated = gated
    }

    func sample() async throws -> SystemSnapshot {
        calls += 1
        if gated { await withCheckedContinuation { waiting.append($0) } }
        guard !steps.isEmpty, case .snapshot(let snapshot) = steps.removeFirst() else { throw SampleFailure() }
        return snapshot
    }

    func release() {
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

private final class FakeBattery: BatterySampling {
    var power: SystemMetric<BatteryPowerState> = .available(BatteryPowerState(
        chargePercent: .available(80), isExternalPowerConnected: .available(true), isCharging: .available(false)))
    var health: SystemMetric<BatteryStatus> = .unavailable(.unsupported)
    private(set) var powerReads = 0
    private(set) var healthReads = 0

    func sample() -> SystemMetric<BatteryStatus> {
        healthReads += 1
        return health
    }

    func samplePowerState() -> SystemMetric<BatteryPowerState> {
        powerReads += 1
        return power
    }
}

/// Returns a fixed disk value; can hold reads open to test overlap and late results.
@MainActor
private final class FakeDisk: DiskSampling {
    var value: SystemMetric<DiskUsage> = .available(DiskUsage(totalBytes: 1_000, availableBytes: 250,
                                                              availableForImportantUsageBytes: .available(400)))
    var gated = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    var waitingCount: Int { waiting.count }

    func sample() async -> SystemMetric<DiskUsage> {
        calls += 1
        if gated { await withCheckedContinuation { waiting.append($0) } }
        return value
    }

    func release() {
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

/// Disk activity is not under test here: every read reports that no drive was matched.
private final class FakeDiskActivity: DiskActivitySampling {
    private(set) var calls = 0
    func sample() async -> DiskActivitySample {
        calls += 1
        return DiskActivitySample(read: .unavailable(.unsupported), device: nil)
    }
}

/// Returns a scripted reading per call (the last one repeats), counting reads.
private final class FakeGPU: GPUSampling {
    var readings: [GPUReading] = [.utilization(50)]
    private(set) var calls = 0
    private(set) var resets = 0

    func reset() {
        resets += 1
    }

    func read() -> GPUReading {
        calls += 1
        return readings.count > 1 ? readings.removeFirst() : readings[0]
    }
}

/// One store wired to the doubles. Every new CPU/RAM sampler gets a copy of `steps`.
@MainActor
private final class Harness {
    let scheduler = ManualScheduler()
    let battery = FakeBattery()
    let disk = FakeDisk()
    let diskActivity = FakeDiskActivity()
    let gpu = FakeGPU()
    /// Monotonic clock for GPU windows; `advance` moves it together with `now`.
    var uptime: TimeInterval = 1_000
    var steps: [ScriptedSampler.Step] = []
    var gated = false
    var now = start
    private(set) var samplers: [ScriptedSampler] = []
    private(set) lazy var store = SystemMonitorStore(makeSampler: { [unowned self] in
        let sampler = ScriptedSampler(steps: self.steps, gated: self.gated)
        self.samplers.append(sampler)
        return sampler
    }, battery: battery, disk: disk, diskActivity: diskActivity, gpu: gpu, gpuScheduleSeed: 42, scheduler: scheduler,
       now: { [unowned self] in self.now }, uptime: { [unowned self] in self.uptime })

    func advance(_ seconds: TimeInterval) {
        uptime += seconds
        now = now.addingTimeInterval(seconds)
    }

    /// Fires the pending GPU read at an exact monotonic time (earlier or later than scheduled).
    func fireGPURead(at time: TimeInterval) {
        let pending = scheduler.pendingOneShots
        guard pending.count == 1, let job = pending.first else { return }
        advance(time - uptime)
        job.hasFired = true
        job.action()
    }

    /// Fires the single pending GPU read at its due time, plus `late` seconds of timer delay. Returns the delay used.
    @discardableResult
    func fireGPURead(late: TimeInterval = 0) -> TimeInterval? {
        let pending = scheduler.pendingOneShots
        guard pending.count == 1, let job = pending.first else { return nil }
        advance(max(job.delay, 0) + late)
        job.hasFired = true
        job.action()
        return job.delay
    }

    func settle() async {
        await store.pendingSample?.value
    }

    func waitUntilSampleIsHeld() async {
        while samplers.last?.waitingCount == 0 { await Task.yield() }
    }
}

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func snapshot(_ second: TimeInterval, cpu: SystemMetric<CPUUsage>, memoryPercent: UInt64? = 50) -> ScriptedSampler.Step {
    let memory: SystemMetric<MemoryUsage> = memoryPercent.map {
        .available(MemoryUsage(totalBytes: 100, usedBytes: $0, appBytes: $0, wiredBytes: 0, compressedBytes: 0, cachedFilesBytes: 0))
    } ?? .unavailable(.inconsistentValues)
    return .snapshot(SystemSnapshot(sampledAt: start.addingTimeInterval(second), cpu: cpu, memory: memory))
}

private func usage(_ percent: Double) -> SystemMetric<CPUUsage> {
    .available(CPUUsage(totalPercent: percent, userPercent: percent, systemPercent: 0))
}

// MARK: - Store

@MainActor
final class SystemMonitorStoreTests: XCTestCase {
    func testNothingIsSampledUntilAMetricIsEnabled() {
        let harness = Harness()
        XCTAssertTrue(harness.store.enabledMetrics.isEmpty)
        XCTAssertTrue(harness.scheduler.jobs.isEmpty)
        XCTAssertTrue(harness.samplers.isEmpty)
        XCTAssertEqual(harness.battery.powerReads, 0)
        XCTAssertNil(harness.store.cpu)
        XCTAssertNil(harness.store.batteryPower)
    }

    func testCPUStartsWithBaselineThenRecordsEverySecond() async {
        let harness = Harness()
        harness.steps = [snapshot(0, cpu: .unavailable(.awaitingBaseline)), snapshot(1, cpu: usage(25)), snapshot(2, cpu: usage(30))]
        harness.store.setEnabled(.cpu, true)
        await harness.settle()

        XCTAssertEqual(harness.scheduler.activeTimers.map(\.interval), [SystemMonitorStore.cpuMemoryInterval])
        XCTAssertEqual(harness.store.cpu, .unavailable(.awaitingBaseline))
        XCTAssertTrue(harness.store.cpuHistory.points.isEmpty, "The baseline sample is not a graph point")

        harness.scheduler.fire(every: 1)
        await harness.settle()
        harness.scheduler.fire(every: 1)
        await harness.settle()
        XCTAssertEqual(harness.store.cpu?.value?.totalPercent, 30)
        XCTAssertEqual(harness.store.cpuHistory.points.map(\.value), [25, 30])
        XCTAssertNil(harness.store.memory, "Memory is not enabled")
        XCTAssertTrue(harness.store.memoryHistory.points.isEmpty)
    }

    func testMetricsAreEnabledIndependently() async {
        let harness = Harness()
        harness.steps = [snapshot(0, cpu: .unavailable(.awaitingBaseline), memoryPercent: 40), snapshot(1, cpu: usage(10), memoryPercent: 41)]
        harness.store.setEnabled(.memory, true)
        await harness.settle()
        XCTAssertEqual(harness.store.memory?.value?.usedBytes, 40)
        XCTAssertNil(harness.store.cpu)

        // CPU joins the running job: no second timer or sampler, and its first value covers the last second.
        harness.store.setEnabled(.cpu, true)
        XCTAssertEqual(harness.scheduler.activeTimers.count, 1)
        XCTAssertEqual(harness.samplers.count, 1)
        harness.scheduler.fire(every: 1)
        await harness.settle()
        XCTAssertEqual(harness.store.cpu?.value?.totalPercent, 10)

        harness.store.setEnabled(.memory, false)
        XCTAssertNil(harness.store.memory)
        XCTAssertTrue(harness.store.memoryHistory.points.isEmpty)
        XCTAssertEqual(harness.scheduler.activeTimers.count, 1, "CPU keeps the job running")
        XCTAssertNil(harness.store.batteryPower)
        XCTAssertEqual(harness.battery.powerReads, 0)
    }

    func testStopCancelsSamplingAndRestartTakesAFreshBaseline() async {
        let harness = Harness()
        harness.steps = [snapshot(0, cpu: .unavailable(.awaitingBaseline)), snapshot(1, cpu: usage(20))]
        harness.store.setEnabled(.cpu, true)
        await harness.settle()
        harness.scheduler.fire(every: 1)
        await harness.settle()

        harness.store.setEnabled(.cpu, false)
        XCTAssertTrue(harness.scheduler.activeTimers.isEmpty)
        XCTAssertNil(harness.store.cpu)
        XCTAssertTrue(harness.store.cpuHistory.points.isEmpty)
        harness.scheduler.fire(every: 1)
        await harness.settle()
        XCTAssertEqual(harness.samplers[0].calls, 2, "A stopped job is not sampled")

        harness.store.setEnabled(.cpu, true)
        await harness.settle()
        XCTAssertEqual(harness.samplers.count, 2, "Restart uses a new sampler, so no average spans the pause")
        XCTAssertEqual(harness.store.cpu, .unavailable(.awaitingBaseline))
        XCTAssertEqual(harness.scheduler.activeTimers.count, 1)
    }

    func testRepeatedEnablingDoesNotDuplicateWork() async {
        let harness = Harness()
        harness.steps = [snapshot(0, cpu: .unavailable(.awaitingBaseline))]
        for _ in 0..<3 {
            harness.store.setEnabled(.cpu, true)
            harness.store.setEnabled(.memory, true)
            harness.store.setEnabled(.battery, true)
        }
        await harness.settle()
        XCTAssertEqual(harness.scheduler.activeTimers.filter { $0.interval == SystemMonitorStore.cpuMemoryInterval }.count, 1)
        XCTAssertEqual(harness.scheduler.activeTimers.filter { $0.interval == SystemMonitorStore.batteryFallbackInterval }.count, 1)
        XCTAssertEqual(harness.scheduler.activeObservers.count, 1)
        XCTAssertEqual(harness.samplers.count, 1)
        XCTAssertEqual(harness.samplers[0].calls, 1)
        XCTAssertEqual(harness.battery.powerReads, 1)

        for _ in 0..<3 { harness.store.setEnabled(.cpu, false) }
        XCTAssertEqual(harness.scheduler.activeTimers.count, 2, "Memory and battery jobs remain")
    }

    func testSlowSampleIsNeverOverlapped() async {
        let harness = Harness()
        harness.gated = true
        harness.steps = [snapshot(0, cpu: .unavailable(.awaitingBaseline)), snapshot(1, cpu: usage(5))]
        harness.store.setEnabled(.cpu, true)
        await harness.waitUntilSampleIsHeld()

        for _ in 0..<3 { harness.scheduler.fire(every: 1) }
        XCTAssertEqual(harness.samplers[0].calls, 1)

        harness.samplers[0].release()
        await harness.settle()
        harness.scheduler.fire(every: 1)
        await harness.waitUntilSampleIsHeld()
        XCTAssertEqual(harness.samplers[0].calls, 2)
        harness.samplers[0].release()
        await harness.settle()
        XCTAssertEqual(harness.store.cpu?.value?.totalPercent, 5)
    }

    func testResultArrivingAfterDisableIsDropped() async {
        let harness = Harness()
        harness.gated = true
        harness.steps = [snapshot(0, cpu: usage(70))]
        harness.store.setEnabled(.cpu, true)
        await harness.waitUntilSampleIsHeld()
        let inFlight = harness.store.pendingSample

        harness.store.setEnabled(.cpu, false)
        harness.samplers[0].release()
        await inFlight?.value
        XCTAssertNil(harness.store.cpu)
        XCTAssertTrue(harness.store.cpuHistory.points.isEmpty)
    }

    func testFailureIsAGapNotZeroAndRecovers() async {
        let harness = Harness()
        harness.steps = [.failure, snapshot(1, cpu: usage(40), memoryPercent: 60), snapshot(2, cpu: usage(45), memoryPercent: nil)]
        harness.store.setEnabled(.cpu, true)
        harness.store.setEnabled(.memory, true)
        await harness.settle()
        XCTAssertEqual(harness.store.cpu, .unavailable(.readFailed(KERN_FAILURE)))
        XCTAssertEqual(harness.store.memory, .unavailable(.readFailed(KERN_FAILURE)))
        XCTAssertEqual(harness.store.cpuHistory.points.map(\.value), [nil])

        harness.scheduler.fire(every: 1)
        await harness.settle()
        XCTAssertEqual(harness.store.cpu?.value?.totalPercent, 40)
        XCTAssertEqual(harness.store.memory?.value?.usedBytes, 60)

        harness.scheduler.fire(every: 1)
        await harness.settle()
        XCTAssertEqual(harness.store.memory, .unavailable(.inconsistentValues))
        XCTAssertEqual(harness.store.cpuHistory.points.map(\.value), [nil, 40, 45])
        XCTAssertEqual(harness.store.memoryHistory.points.map(\.value), [nil, 60, nil])
    }

    func testBatteryReadsOnEnableOnPowerChangeAndOnFallback() {
        let harness = Harness()
        harness.store.setEnabled(.battery, true)
        XCTAssertEqual(harness.battery.powerReads, 1)
        XCTAssertEqual(harness.battery.healthReads, 1)
        XCTAssertEqual(harness.scheduler.activeObservers.count, 1)
        XCTAssertEqual(harness.scheduler.activeTimers.map(\.interval), [SystemMonitorStore.batteryFallbackInterval])
        XCTAssertTrue(harness.samplers.isEmpty, "Battery does not start CPU/RAM sampling")

        harness.scheduler.firePowerSourceChange()
        harness.scheduler.fire(every: SystemMonitorStore.batteryFallbackInterval)
        XCTAssertEqual(harness.battery.powerReads, 3)
        XCTAssertEqual(harness.store.batteryPower?.value?.chargePercent, .available(80))

        harness.store.setEnabled(.battery, false)
        XCTAssertNil(harness.store.batteryPower)
        XCTAssertNil(harness.store.batteryHealth)
        XCTAssertTrue(harness.scheduler.activeObservers.isEmpty)
        XCTAssertTrue(harness.scheduler.activeTimers.isEmpty)
        harness.scheduler.firePowerSourceChange()
        XCTAssertEqual(harness.battery.powerReads, 3)
    }

    func testBatteryUnavailableStatesPassThroughAndRecover() {
        let harness = Harness()
        harness.battery.power = .unavailable(.noBattery)
        harness.battery.health = .unavailable(.noBattery)
        harness.store.setEnabled(.battery, true)
        XCTAssertEqual(harness.store.batteryPower, .unavailable(.noBattery))
        XCTAssertEqual(harness.store.batteryHealth, .unavailable(.noBattery))

        harness.battery.power = .unavailable(.readFailed(kIOReturnError))
        harness.scheduler.firePowerSourceChange()
        XCTAssertEqual(harness.store.batteryPower, .unavailable(.readFailed(kIOReturnError)))

        let recovered = BatteryPowerState(chargePercent: .available(55), isExternalPowerConnected: .available(false), isCharging: .available(false))
        harness.battery.power = .available(recovered)
        harness.scheduler.fire(every: SystemMonitorStore.batteryFallbackInterval)
        XCTAssertEqual(harness.store.batteryPower, .available(recovered))
    }
}

// MARK: - Disk in the store

@MainActor
final class SystemMonitorStoreDiskTests: XCTestCase {
    func testDiskReadsOnEnableAndEverySixtySecondsOnly() async {
        let harness = Harness()
        harness.store.setEnabled(.disk, true)
        await harness.store.pendingDiskSample?.value
        XCTAssertEqual(harness.disk.calls, 1)
        XCTAssertEqual(harness.store.disk?.value?.usedBytes, 750)
        // 6-4e: Disk also runs its 1-second activity job; capacity stays on 60 s.
        XCTAssertEqual(harness.scheduler.activeTimers.map(\.interval), [SystemMonitorStore.diskInterval, SystemMonitorStore.diskActivityInterval])
        XCTAssertTrue(harness.samplers.isEmpty, "Disk does not start CPU/RAM sampling")
        XCTAssertEqual(harness.battery.powerReads, 0)

        harness.scheduler.fire(every: SystemMonitorStore.cpuMemoryInterval)
        XCTAssertEqual(harness.disk.calls, 1, "Disk is not read on the 1-second tick")
        harness.scheduler.fire(every: SystemMonitorStore.diskInterval)
        await harness.store.pendingDiskSample?.value
        XCTAssertEqual(harness.disk.calls, 2)
    }

    func testDisableStopsAndRestartReadsAgain() async {
        let harness = Harness()
        harness.store.setEnabled(.disk, true)
        await harness.store.pendingDiskSample?.value
        harness.store.setEnabled(.disk, false)
        XCTAssertNil(harness.store.disk)
        XCTAssertTrue(harness.scheduler.activeTimers.isEmpty)
        harness.scheduler.fire(every: SystemMonitorStore.diskInterval)
        XCTAssertEqual(harness.disk.calls, 1, "A disabled disk is not read")

        harness.store.setEnabled(.disk, true)
        await harness.store.pendingDiskSample?.value
        XCTAssertEqual(harness.disk.calls, 2)
        XCTAssertNotNil(harness.store.disk)
        XCTAssertEqual(harness.scheduler.activeTimers.count, 2, "Capacity (60 s) and activity (1 s)")
    }

    func testRepeatedEnableAndSlowReadsDoNotDuplicateWork() async {
        let harness = Harness()
        harness.disk.gated = true
        for _ in 0..<3 { harness.store.setEnabled(.disk, true) }
        while harness.disk.waitingCount == 0 { await Task.yield() }
        for _ in 0..<3 { harness.scheduler.fire(every: SystemMonitorStore.diskInterval) }
        XCTAssertEqual(harness.disk.calls, 1)
        XCTAssertEqual(harness.scheduler.activeTimers.count, 2, "Capacity (60 s) and activity (1 s), once each")
        harness.disk.release()
        await harness.store.pendingDiskSample?.value
        XCTAssertNotNil(harness.store.disk)
    }

    func testLateDiskResultAfterDisableIsDropped() async {
        let harness = Harness()
        harness.disk.gated = true
        harness.store.setEnabled(.disk, true)
        while harness.disk.waitingCount == 0 { await Task.yield() }
        let inFlight = harness.store.pendingDiskSample
        harness.store.setEnabled(.disk, false)
        harness.disk.release()
        await inFlight?.value
        XCTAssertNil(harness.store.disk)
        XCTAssertNil(harness.store.pendingDiskSample)
    }

    func testDiskFailureIsPublishedAndRecovers() async {
        let harness = Harness()
        harness.disk.value = .unavailable(.readFailed(EIO))
        harness.store.setEnabled(.disk, true)
        await harness.store.pendingDiskSample?.value
        XCTAssertEqual(harness.store.disk, .unavailable(.readFailed(EIO)))

        harness.disk.value = .available(DiskUsage(totalBytes: 100, availableBytes: 0, availableForImportantUsageBytes: .unavailable(.unsupported)))
        harness.scheduler.fire(every: SystemMonitorStore.diskInterval)
        await harness.store.pendingDiskSample?.value
        XCTAssertEqual(harness.store.disk?.value?.usedFraction, 1)
    }

    func testDiskIsIndependentOfOtherMetrics() async {
        let harness = Harness()
        harness.steps = [snapshot(0, cpu: .unavailable(.awaitingBaseline))]
        harness.store.setEnabled(.cpu, true)
        harness.store.setEnabled(.disk, true)
        await harness.settle()
        await harness.store.pendingDiskSample?.value
        harness.store.setEnabled(.disk, false)
        XCTAssertEqual(harness.scheduler.activeTimers.map(\.interval), [SystemMonitorStore.cpuMemoryInterval])
        XCTAssertEqual(harness.store.cpu, .unavailable(.awaitingBaseline))
        harness.store.setEnabled(.cpu, false)
    }
}

// MARK: - GPU in the store (experimental)

@MainActor
final class SystemMonitorStoreGPUTests: XCTestCase {
    private func fire(_ harness: Harness, reads: Int, late: TimeInterval = 0, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<reads { XCTAssertNotNil(harness.fireGPURead(late: late), "A GPU read should be pending", file: file, line: line) }
    }

    func testPublishesOncePerSecondFromTenReads() {
        let harness = Harness()
        harness.store.setEnabled(.gpu, true)
        XCTAssertEqual(harness.scheduler.pendingOneShots.count, 1)
        XCTAssertTrue(harness.scheduler.activeTimers.isEmpty, "GPU uses one-shot reads, no repeating timer")

        fire(harness, reads: 10)
        XCTAssertNil(harness.store.gpu, "Nothing is published until the first window closes")
        XCTAssertEqual(harness.gpu.calls, 10)

        fire(harness, reads: 1)
        XCTAssertEqual(harness.store.gpu, .available(50))
        XCTAssertEqual(harness.store.gpuHistory.points.count, 1)

        fire(harness, reads: 10)
        XCTAssertEqual(harness.store.gpuHistory.points.count, 2, "One point per second, not per read")
    }

    func testReadsAreSpreadInsideTheirSlots() {
        let harness = Harness()
        let start = harness.uptime
        harness.store.setEnabled(.gpu, true)
        var offsets: [TimeInterval] = []
        for slot in 0..<GPUSampleSchedule.slots {
            harness.fireGPURead()
            let offset = harness.uptime - start - Double(slot) * GPUSampleSchedule.slotLength
            XCTAssertGreaterThanOrEqual(offset, GPUSampleSchedule.edgeMargin - 1e-9)
            XCTAssertLessThanOrEqual(offset, GPUSampleSchedule.slotLength - GPUSampleSchedule.edgeMargin + 1e-9)
            offsets.append(offset)
        }
        XCTAssertGreaterThan(Set(offsets.map { ($0 * 1_000).rounded() }).count, 5)
    }

    func testPartialFailuresAndTooFewValidReads() {
        let harness = Harness()
        harness.gpu.readings = Array(repeating: .utilization(60), count: 6) + Array(repeating: .readFailed(kIOReturnError), count: 4)
            + Array(repeating: .utilization(90), count: 4) + Array(repeating: .outOfRange, count: 6)
            + Array(repeating: .noAccelerator, count: 10) + [.noAccelerator]
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 11)
        XCTAssertEqual(harness.store.gpu, .available(60), "Failed reads are left out, not averaged in as 0")
        fire(harness, reads: 10)
        XCTAssertEqual(harness.store.gpu, .unavailable(.insufficientSamples))
        fire(harness, reads: 10)
        XCTAssertEqual(harness.store.gpu, .unavailable(.unsupported))
        XCTAssertEqual(harness.store.gpuHistory.points.map(\.value), [60, nil, nil])
    }

    func testDisableClearsEverythingAndRestartDoesNotMixWindows() {
        let harness = Harness()
        harness.gpu.readings = [.utilization(100)]
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 11)
        fire(harness, reads: 5)
        harness.store.setEnabled(.gpu, false)
        XCTAssertNil(harness.store.gpu)
        XCTAssertTrue(harness.store.gpuHistory.points.isEmpty)
        XCTAssertTrue(harness.scheduler.pendingOneShots.isEmpty, "The pending read is cancelled")
        XCTAssertNil(harness.fireGPURead())
        XCTAssertEqual(harness.gpu.calls, 16)

        harness.gpu.readings = [.utilization(0)]
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 11)
        XCTAssertEqual(harness.store.gpu, .available(0), "The five 100 % reads from before the restart are gone")
        XCTAssertEqual(harness.store.gpuHistory.points.count, 1)
    }

    func testRepeatedEnableKeepsOneReadPending() {
        let harness = Harness()
        for _ in 0..<3 { harness.store.setEnabled(.gpu, true) }
        XCTAssertEqual(harness.scheduler.pendingOneShots.count, 1)
        fire(harness, reads: 1)
        XCTAssertEqual(harness.gpu.calls, 1)
        XCTAssertEqual(harness.scheduler.pendingOneShots.count, 1)
    }

    func testLongGapOrSleepDropsTheOpenWindowAndTheStaleValue() {
        let harness = Harness()
        harness.gpu.readings = [.utilization(80)]
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 11)
        fire(harness, reads: 4)
        XCTAssertEqual(harness.store.gpu, .available(80))

        // Asleep for 30 s: the next read lands far past the open window.
        harness.gpu.readings = [.utilization(20)]
        fire(harness, reads: 1, late: 30)
        XCTAssertEqual(harness.store.gpu, .unavailable(.insufficientSamples), "The pre-sleep value is not shown as current")
        XCTAssertEqual(harness.store.gpuHistory.points.count, 1, "The interrupted window is not published")

        fire(harness, reads: 10)
        XCTAssertEqual(harness.store.gpu, .available(20), "Only post-sleep reads are averaged")
        XCTAssertEqual(harness.store.gpuHistory.points.count, 2)
    }

    /// Codex review (Medium): a window closed by a read 1.9 s after its start used to be published.
    func testWindowClosedOnePointNineSecondsAfterItsStartIsDropped() {
        let harness = Harness()
        let start = harness.uptime
        harness.gpu.readings = [.utilization(80)]
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 10)
        harness.gpu.readings = [.utilization(20)]
        harness.fireGPURead(at: start + 1.9)
        XCTAssertEqual(harness.store.gpu, .unavailable(.insufficientSamples), "The old second is not published")
        XCTAssertTrue(harness.store.gpuHistory.points.isEmpty)

        fire(harness, reads: 10)
        XCTAssertEqual(harness.store.gpu, .available(20), "A fresh window started at the resumed read")
        XCTAssertEqual(harness.store.gpuHistory.points.count, 1)
    }

    func testDelaysOfOneToTwoSecondsAreDropped() {
        for delay in [1.0, 1.3, 1.6, 2.0] {
            let harness = Harness()
            let start = harness.uptime
            harness.store.setEnabled(.gpu, true)
            fire(harness, reads: 10)
            harness.fireGPURead(at: start + 1 + delay)
            XCTAssertEqual(harness.store.gpu, .unavailable(.insufficientSamples), "Closing \(delay) s after the end")
            XCTAssertTrue(harness.store.gpuHistory.points.isEmpty)
        }
    }

    func testNormalTimerJitterStillPublishes() {
        let harness = Harness()
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 31, late: 0.04)
        XCTAssertGreaterThanOrEqual(harness.store.gpuHistory.points.count, 2)
        XCTAssertTrue(harness.store.gpuHistory.points.allSatisfy { $0.value == 50 }, "40 ms late reads are normal")

        let closing = Harness()
        closing.store.setEnabled(.gpu, true)
        fire(closing, reads: 10)
        fire(closing, reads: 1, late: 0.15)
        XCTAssertEqual(closing.store.gpu, .available(50), "A closing read 0.15 s late is still within the limit")
    }

    func testReadExactlyAtTheWindowEndOpensTheNextWindow() {
        let harness = Harness()
        let start = harness.uptime
        harness.gpu.readings = Array(repeating: .utilization(100), count: 10) + [.utilization(0), .utilization(100)]
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 10)
        harness.fireGPURead(at: start + GPUSampleSchedule.window)
        XCTAssertEqual(harness.store.gpu, .available(100), "The boundary read is not part of the closed window")
        fire(harness, reads: 10)
        XCTAssertEqual(harness.store.gpu, .available(90), "It is the first read of the next window")
    }

    func testDisableResetsTheSamplerCache() {
        let harness = Harness()
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 3)
        XCTAssertEqual(harness.gpu.resets, 0)
        harness.store.setEnabled(.gpu, false)
        XCTAssertEqual(harness.gpu.resets, 1)
        harness.store.setEnabled(.gpu, true)
        harness.store.setEnabled(.gpu, false)
        XCTAssertEqual(harness.gpu.resets, 2)
    }

    func testConsistentlyLateTimersNeverPublishAStaleValue() {
        let harness = Harness()
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 40, late: 0.25)
        XCTAssertEqual(harness.store.gpu, .unavailable(.insufficientSamples))
        // Windows are either dropped as stale or closed in time with too few reads; never a value from such a window.
        XCTAssertTrue(harness.store.gpuHistory.points.allSatisfy { $0.value == nil })
        XCTAssertEqual(harness.scheduler.pendingOneShots.count, 1, "Sampling continues")
    }

    func testHistoryKeepsAtMostSixtySeconds() {
        let harness = Harness()
        harness.store.setEnabled(.gpu, true)
        fire(harness, reads: 10 * 70 + 1)
        XCTAssertEqual(harness.store.gpuHistory.points.count, 60)
    }

    func testGPUIsIndependentOfOtherMetrics() async {
        let harness = Harness()
        harness.store.setEnabled(.gpu, true)
        XCTAssertTrue(harness.samplers.isEmpty)
        XCTAssertEqual(harness.battery.powerReads, 0)
        XCTAssertEqual(harness.disk.calls, 0)

        harness.steps = [snapshot(0, cpu: .unavailable(.awaitingBaseline))]
        harness.store.setEnabled(.cpu, true)
        await harness.settle()
        XCTAssertEqual(harness.scheduler.pendingOneShots.count, 1)
        fire(harness, reads: 3)
        XCTAssertEqual(harness.samplers[0].calls, 1, "GPU reads do not drive CPU sampling")

        harness.store.setEnabled(.gpu, false)
        XCTAssertTrue(harness.scheduler.pendingOneShots.isEmpty)
        XCTAssertEqual(harness.scheduler.activeTimers.map(\.interval), [SystemMonitorStore.cpuMemoryInterval])
        XCTAssertEqual(harness.store.cpu, .unavailable(.awaitingBaseline))
        harness.store.setEnabled(.cpu, false)
    }
}

// MARK: - History

final class SystemMetricHistoryTests: XCTestCase {
    func testKeepsAtMostSixtyPoints() {
        var history = SystemMetricHistory()
        for second in 0..<100 { history.append(Double(second), at: start.addingTimeInterval(Double(second) * 0.5)) }
        XCTAssertEqual(history.points.count, 60)
        XCTAssertEqual(history.points.first?.value, 40)
        XCTAssertEqual(history.points.last?.value, 99)
    }

    func testDropsPointsSixtySecondsOrOlder() {
        var history = SystemMetricHistory()
        history.append(1, at: start)
        history.append(2, at: start.addingTimeInterval(30))
        history.append(3, at: start.addingTimeInterval(59.9))
        XCTAssertEqual(history.points.map(\.value), [1, 2, 3])
        history.append(4, at: start.addingTimeInterval(60))
        XCTAssertEqual(history.points.map(\.value), [2, 3, 4])
        history.append(5, at: start.addingTimeInterval(200))
        XCTAssertEqual(history.points.map(\.value), [5])
    }

    func testUnavailableValuesAreGaps() {
        var history = SystemMetricHistory()
        history.append(nil, at: start)
        history.append(10, at: start.addingTimeInterval(1))
        XCTAssertEqual(history.points.map(\.value), [nil, 10])
    }

    func testClockMovingBackwardsRestartsHistory() {
        var history = SystemMetricHistory()
        history.append(1, at: start.addingTimeInterval(10))
        history.append(2, at: start)
        XCTAssertEqual(history.points.map(\.value), [2])
    }
}
