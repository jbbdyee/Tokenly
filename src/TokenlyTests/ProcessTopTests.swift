import Darwin
import XCTest
@testable import Tokenly

private func raw(_ pid: Int32, _ name: String = "process", start: UInt64 = 1,
                 user: UInt64 = 0, system: UInt64 = 0, memory: UInt64 = 0) -> ProcessRawEntry {
    ProcessRawEntry(pid: pid, name: name, startTicks: start, userTicks: user,
                    systemTicks: system, footprintBytes: memory)
}

private func reading(_ time: UInt64, _ entries: [ProcessRawEntry], denied: Int = 0) -> ProcessRawSnapshot {
    ProcessRawSnapshot(uptimeNanoseconds: time, entries: entries, permissionDeniedCount: denied)
}

final class ProcessTopCalculationTests: XCTestCase {
    func testMachTimebaseAndMulticorePercent() {
        let before = reading(1_000, [raw(1, user: 10, system: 10), raw(2, user: 0)])
        let after = reading(1_000_001_000, [raw(1, user: 36_000_010, system: 10), raw(2, user: 48_000_000)])
        let result = ProcessTopCalculator.calculate(previous: before, current: after, timebaseNumer: 125, timebaseDenom: 3)
        XCTAssertEqual(result.cpu.map(\.pid), [2, 1])
        XCTAssertEqual(result.cpu[0].percent, 200, accuracy: 0.0001)
        XCTAssertEqual(result.cpu[1].percent, 150, accuracy: 0.0001)
    }

    func testFirstSampleReusedPIDExitAndCounterResetAreNotZeroUsage() {
        let before = reading(1, [raw(1, start: 10, user: 10), raw(2, user: 20), raw(3, user: 30), raw(4, user: 10)])
        let after = reading(1_000_000_001, [raw(1, start: 11, user: 100), raw(2, user: 10), raw(4, user: 20)], denied: 5)
        XCTAssertFalse(ProcessTopCalculator.calculate(previous: nil, current: before, timebaseNumer: 1, timebaseDenom: 1).cpuHasBaseline)
        let result = ProcessTopCalculator.calculate(previous: before, current: after, timebaseNumer: 1, timebaseDenom: 1)
        XCTAssertEqual(result.cpu.map(\.pid), [4])
        XCTAssertEqual(result.permissionDeniedCount, 5)
        XCTAssertEqual(result.readableCount, 3)
    }

    func testSortLimitAndPartialReads() {
        let entries = (1...8).map { raw(Int32($0), user: UInt64($0) * 1_000_000,
                                            memory: UInt64(9 - $0) * 1_000_000) }
        let before = reading(1, entries.map { raw($0.pid) })
        let after = reading(1_000_000_001, entries, denied: 50)
        let result = ProcessTopCalculator.calculate(previous: before, current: after, timebaseNumer: 1, timebaseDenom: 1)
        XCTAssertEqual(result.cpu.map(\.pid), [8, 7, 6, 5, 4])
        XCTAssertEqual(result.memory.map(\.pid), [1, 2, 3, 4, 5])
        XCTAssertEqual(result.permissionDeniedCount, 50)
        XCTAssertEqual(ProcessTopCalculator.calculate(previous: nil, current: reading(1, Array(entries.prefix(2))),
                                                      timebaseNumer: 1, timebaseDenom: 1).memory.count, 2)
    }

    func testInvalidIntervalOrTimebaseHasNoCPUValue() {
        let value = reading(10, [raw(1, user: 5)])
        XCTAssertFalse(ProcessTopCalculator.calculate(previous: value, current: value,
                                                      timebaseNumer: 1, timebaseDenom: 1).cpuHasBaseline)
        XCTAssertFalse(ProcessTopCalculator.calculate(previous: reading(1, [raw(1)]), current: value,
                                                      timebaseNumer: 0, timebaseDenom: 1).cpuHasBaseline)
    }

    func testLiveReaderOnlyReturnsMeasuredProcesses() throws {
        let live = try XCTUnwrap(try LiveProcessReader.read().value)
        XCTAssertTrue(live.entries.contains { $0.pid == getpid() })
        XCTAssertTrue(live.entries.allSatisfy { !$0.name.isEmpty })
    }

    func testLiveSamplerReportsMeasuredRankingsAndScanCost() async throws {
        let sampler = ProcessTopSampler()
        let firstResult = try await sampler.sample()
        let first = try XCTUnwrap(firstResult.value)
        XCTAssertFalse(first.cpuHasBaseline)
        XCTAssertLessThanOrEqual(first.memory.count, 5)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let secondResult = try await sampler.sample()
        let second = try XCTUnwrap(secondResult.value)
        XCTAssertTrue(second.cpuHasBaseline)
        XCTAssertLessThanOrEqual(second.cpu.count, 5)
        XCTAssertLessThanOrEqual(second.memory.count, 5)
        var costs: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try LiveProcessReader.read()
            costs.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        print("PROCESS_TOP_LIVE readable=\(second.readableCount) denied=\(second.permissionDeniedCount) cpu=\(second.cpu.map { "\($0.pid):\(String(format: "%.1f", $0.percent))%" }) memory=\(second.memory.map { "\($0.pid):\($0.footprintBytes / 1_048_576)MiB" }) scan_ms=\(costs)")
    }
}

// MARK: - Enumeration failure and cancellation (3-2 stabilization)

/// Serves scripted raw reads in order and counts calls; `Sendable` because the sampler actor calls it.
private final class ScriptedRawReads: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [SystemMetric<ProcessRawSnapshot>]
    /// Called with the 1-based call number, inside the reading task.
    private var onRead: (Int) -> Void
    private(set) var calls = 0

    init(_ steps: [SystemMetric<ProcessRawSnapshot>], onRead: @escaping (Int) -> Void = { _ in }) {
        self.steps = steps
        self.onRead = onRead
    }

    func read() -> SystemMetric<ProcessRawSnapshot> {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        onRead(calls)
        return steps.isEmpty ? .unavailable(.readFailed(EIO)) : steps.removeFirst()
    }
}

final class ProcessTopFailureAndCancellationTests: XCTestCase {
    private let unit = mach_timebase_info_data_t(numer: 1, denom: 1)

    func testEnumerationFailureIsUnavailableNotAnEmptyList() async throws {
        let reads = ScriptedRawReads([.unavailable(.readFailed(EPERM)), .available(reading(1, [], denied: 7))])
        let sampler = ProcessTopSampler(read: { reads.read() }, timebase: unit)

        let failed = try await sampler.sample()
        XCTAssertEqual(failed, .unavailable(.readFailed(EPERM)), "조회 불가")

        let emptyResult = try await sampler.sample()

        let empty = try XCTUnwrap(emptyResult.value, "목록 없음 is still a successful read")
        XCTAssertEqual(empty.readableCount, 0)
        XCTAssertEqual(empty.permissionDeniedCount, 7)
        XCTAssertTrue(empty.cpu.isEmpty && empty.memory.isEmpty)
    }

    func testEnumerationFailureKeepsTheCPUBaseline() async throws {
        let reads = ScriptedRawReads([.available(reading(1, [raw(1, user: 0)])), .unavailable(.readFailed(EIO)),
                                      .available(reading(1_000_000_001, [raw(1, user: 500_000_000)]))])
        let sampler = ProcessTopSampler(read: { reads.read() }, timebase: unit)
        _ = try await sampler.sample()
        _ = try await sampler.sample()
        let afterResult = try await sampler.sample()
        let after = try XCTUnwrap(afterResult.value)
        XCTAssertTrue(after.cpuHasBaseline)
        XCTAssertEqual(after.cpu.first?.percent ?? -1, 50, accuracy: 0.0001)
    }

    func testLiveReaderReportsInjectedListFailureWithErrno() throws {
        let sizeFails = try LiveProcessReader.read(listPIDs: { _, _ in errno = EPERM; return -1 })
        XCTAssertEqual(sizeFails, .unavailable(.readFailed(EPERM)))

        // The size query succeeds but the list call itself fails.
        let listFails = try LiveProcessReader.read(listPIDs: { buffer, _ in
            if buffer == nil { return Int32(MemoryLayout<pid_t>.stride * 10) }
            errno = EINVAL
            return 0
        })
        XCTAssertEqual(listFails, .unavailable(.readFailed(EINVAL)))
    }

    func testCancelledSampleDoesNotReadOrMoveTheBaseline() async throws {
        let reads = ScriptedRawReads([.available(reading(1, [raw(1)])), .available(reading(2, [raw(1)]))])
        let sampler = ProcessTopSampler(read: { reads.read() }, timebase: unit)
        let cancelledBeforeRead = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sampler.sample()
        }
        do {
            _ = try await cancelledBeforeRead.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(reads.calls, 0, "No scan after cancellation")

        // Cancelled while reading: the finished read is thrown away, so the same sampler's next scan has no baseline.
        let cancellingReads = ScriptedRawReads([.available(reading(1, [raw(1)])), .available(reading(2, [raw(1)]))],
                                               onRead: { call in if call == 1 { withUnsafeCurrentTask { $0?.cancel() } } })
        let cancellingSampler = ProcessTopSampler(read: { cancellingReads.read() }, timebase: unit)
        let cancelledDuringRead = Task { try await cancellingSampler.sample() }
        do {
            _ = try await cancelledDuringRead.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
        let nextResult = try await cancellingSampler.sample()
        let next = try XCTUnwrap(nextResult.value)
        XCTAssertEqual(cancellingReads.calls, 2)
        XCTAssertFalse(next.cpuHasBaseline, "The cancelled read did not become a baseline")
    }

    func testLiveReaderStopsWhenItsTaskIsCancelled() async {
        let scan = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LiveProcessReader.read()
        }
        do {
            _ = try await scan.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

@MainActor
private final class ProcessTimer: SystemMonitorScheduling {
    final class Job: SystemMonitorCancellable {
        let interval: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) { self.interval = interval; self.action = action }
        func cancel() { cancelled = true }
    }
    var jobs: [Job] = []
    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let job = Job(interval, action); jobs.append(job); return job
    }
    func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        XCTFail("Process polling must not request a power observer")
        return Job(0, action)
    }
    func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        XCTFail("Process polling must not request a one-shot timer")
        return Job(0, action)
    }
    func fire() { for job in jobs where !job.cancelled { job.action() } }
}

/// Holds each sample until released. With `honorsCancellation`, a cancelled sample is released and throws like the
/// real sampler; without it, the sample ignores cancellation and returns late, to exercise the store's race handling.
@MainActor
private final class HeldProcessSampler: ProcessTopSampling {
    var calls = 0
    var held: [CheckedContinuation<Void, Never>] = []
    var observedCancellations = 0
    let honorsCancellation: Bool

    init(honorsCancellation: Bool = false) {
        self.honorsCancellation = honorsCancellation
    }

    func sample() async throws -> SystemMetric<ProcessTopSnapshot> {
        calls += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { held.append($0) }
        } onCancel: {
            Task { @MainActor in
                self.observedCancellations += 1
                if self.honorsCancellation { self.release() }
            }
        }
        if honorsCancellation { try Task.checkCancellation() }
        return .available(ProcessTopSnapshot(cpu: [], memory: [], cpuHasBaseline: calls > 1,
                                             readableCount: 0, permissionDeniedCount: 0))
    }
    func release() { held.forEach { $0.resume() }; held.removeAll() }
}

@MainActor
final class ProcessTopStoreTests: XCTestCase {
    func testStartStopRestartAndNoDuplicateWork() async {
        let timer = ProcessTimer()
        var samplers: [HeldProcessSampler] = []
        let store = ProcessTopStore(makeSampler: { let s = HeldProcessSampler(); samplers.append(s); return s }, scheduler: timer)
        XCTAssertTrue(timer.jobs.isEmpty)
        store.setVisible("cpu", true)
        store.setVisible("cpu", true)
        store.setVisible("memory", true)
        while samplers[0].held.isEmpty { await Task.yield() }
        XCTAssertEqual(timer.jobs.count, 1)
        XCTAssertEqual(timer.jobs[0].interval, 3)
        timer.fire(); timer.fire()
        XCTAssertEqual(samplers[0].calls, 1)
        samplers[0].release()
        await store.pendingSample?.value
        XCTAssertNotNil(store.snapshot)

        store.setVisible("cpu", false)
        XCTAssertFalse(timer.jobs[0].cancelled)
        store.setVisible("memory", false)
        XCTAssertTrue(timer.jobs[0].cancelled)
        XCTAssertNil(store.snapshot)
        timer.fire()
        XCTAssertEqual(samplers[0].calls, 1)

        store.setVisible("cpu", true)
        while samplers.count < 2 || samplers[1].held.isEmpty { await Task.yield() }
        XCTAssertEqual(timer.jobs.count, 2)
        samplers[1].release()
        await store.pendingSample?.value
        XCTAssertFalse(store.snapshot?.value?.cpuHasBaseline ?? true)
    }

    func testLateResultCannotRepublishAfterClose() async {
        let timer = ProcessTimer()
        let sampler = HeldProcessSampler()
        let store = ProcessTopStore(makeSampler: { sampler }, scheduler: timer)
        store.setVisible("cpu", true)
        while sampler.held.isEmpty { await Task.yield() }
        let pending = store.pendingSample
        store.setVisible("cpu", false)
        sampler.release()
        await pending?.value
        XCTAssertNil(store.snapshot)
    }

    func testCloseCancelsTheInFlightScan() async {
        let timer = ProcessTimer()
        let sampler = HeldProcessSampler(honorsCancellation: true)
        let store = ProcessTopStore(makeSampler: { sampler }, scheduler: timer)
        store.setVisible("cpu", true)
        while sampler.held.isEmpty { await Task.yield() }
        let pending = store.pendingSample

        store.setVisible("cpu", false)
        XCTAssertNil(store.pendingSample)
        await pending?.value
        XCTAssertEqual(sampler.observedCancellations, 1)
        XCTAssertNil(store.snapshot)
    }

    func testReopenStartsImmediatelyEvenIfTheOldScanIgnoresCancellation() async {
        let timer = ProcessTimer()
        var samplers: [HeldProcessSampler] = []
        let store = ProcessTopStore(makeSampler: { let s = HeldProcessSampler(); samplers.append(s); return s }, scheduler: timer)
        store.setVisible("cpu", true)
        while samplers[0].held.isEmpty { await Task.yield() }
        let oldScan = store.pendingSample

        store.setVisible("cpu", false)
        store.setVisible("cpu", true)
        while samplers.count < 2 || samplers[1].held.isEmpty { await Task.yield() }
        XCTAssertEqual(samplers[1].calls, 1, "The new scan does not wait for the old one")
        while samplers[0].observedCancellations == 0 { await Task.yield() }

        // The old scan finishes late: it must neither publish nor clear the new scan's handle.
        samplers[0].release()
        await oldScan?.value
        XCTAssertNil(store.snapshot)
        XCTAssertNotNil(store.pendingSample)
        timer.fire()
        XCTAssertEqual(samplers[1].calls, 1, "No duplicate scan while the new one is running")

        samplers[1].release()
        await store.pendingSample?.value
        XCTAssertEqual(store.snapshot?.value?.cpuHasBaseline, false)
    }

    func testEnumerationFailureIsPublishedAsUnavailableAndRecovers() async {
        let timer = ProcessTimer()
        let reads = ScriptedRawReads([.unavailable(.readFailed(EPERM)), .available(reading(1, [raw(1, memory: 10)]))])
        let store = ProcessTopStore(makeSampler: { ProcessTopSampler(read: { reads.read() }) }, scheduler: timer)
        store.setVisible("memory", true)
        await store.pendingSample?.value
        XCTAssertEqual(store.snapshot, .unavailable(.readFailed(EPERM)))

        timer.fire()
        await store.pendingSample?.value
        XCTAssertEqual(store.snapshot?.value?.memory.map(\.pid), [1])
        store.setVisible("memory", false)
    }
}
