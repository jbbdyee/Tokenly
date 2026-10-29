import Darwin
import XCTest
@testable import Tokenly

/// CPU and memory arithmetic with fixed counters, plus a smoke test against the real Mach host.
final class SystemMonitorTests: XCTestCase {
    private func ticks(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CPUTickCounters {
        CPUTickCounters(user: user, system: system, idle: idle, nice: nice)
    }

    private func pages(anonymous: UInt32 = 0, purgeable: UInt32 = 0, wired: UInt32 = 0, compressed: UInt32 = 0, external: UInt32 = 0) -> VMPageCounters {
        VMPageCounters(anonymous: anonymous, purgeable: purgeable, wired: wired, compressed: compressed, external: external)
    }

    // MARK: CPU

    func testFirstCPUSampleOnlyRecordsBaseline() {
        var tracker = CPUUsageTracker()
        XCTAssertEqual(tracker.update(with: ticks(user: 100, system: 50, idle: 850)), .unavailable(.awaitingBaseline))
        XCTAssertEqual(tracker.baseline, ticks(user: 100, system: 50, idle: 850))
    }

    func testCPUUsageUsesTickDeltasAndCountsNiceAsUser() throws {
        var tracker = CPUUsageTracker()
        _ = tracker.update(with: ticks(user: 1_000, system: 500, idle: 8_000, nice: 10))
        // Deltas: user 150 + nice 50, system 100, idle 700 → total 1000.
        let usage = try XCTUnwrap(tracker.update(with: ticks(user: 1_150, system: 600, idle: 8_700, nice: 60)).value)
        XCTAssertEqual(usage.totalPercent, 30, accuracy: 1e-9)
        XCTAssertEqual(usage.userPercent, 20, accuracy: 1e-9)
        XCTAssertEqual(usage.systemPercent, 10, accuracy: 1e-9)
    }

    func testCPUUsageBoundsAreZeroAndHundred() {
        let base = ticks(user: 10, system: 10, idle: 10)
        XCTAssertEqual(CPUUsageTracker.usage(from: base, to: ticks(user: 10, system: 10, idle: 110)).value?.totalPercent, 0)
        XCTAssertEqual(CPUUsageTracker.usage(from: base, to: ticks(user: 60, system: 60, idle: 10)).value?.totalPercent, 100)
    }

    func testCPUUsageWithoutElapsedTicksIsUnavailable() {
        let same = ticks(user: 5, system: 5, idle: 5, nice: 5)
        XCTAssertEqual(CPUUsageTracker.usage(from: same, to: same), .unavailable(.noElapsedTicks))
    }

    func testCPUCounterResetSkipsIntervalAndRebaselines() throws {
        var tracker = CPUUsageTracker()
        _ = tracker.update(with: ticks(user: 1_000, system: 1_000, idle: 1_000))
        XCTAssertEqual(tracker.update(with: ticks(user: 10, system: 1_100, idle: 1_100)), .unavailable(.counterReset))
        let usage = try XCTUnwrap(tracker.update(with: ticks(user: 60, system: 1_150, idle: 1_200)).value)
        XCTAssertEqual(usage.totalPercent, 50, accuracy: 1e-9)
    }

    func testCPUCounterWrapIsTreatedAsReset() {
        let beforeWrap = ticks(user: 100, system: 100, idle: .max - 5)
        XCTAssertEqual(CPUUsageTracker.usage(from: beforeWrap, to: ticks(user: 110, system: 110, idle: 3)), .unavailable(.counterReset))
    }

    func testCPUUsageWithMaximumCounterDeltasStaysInRange() throws {
        let usage = try XCTUnwrap(CPUUsageTracker.usage(from: ticks(), to: ticks(user: .max, system: .max, idle: .max, nice: .max)).value)
        XCTAssertEqual(usage.totalPercent, 75, accuracy: 1e-9)
        for value in [usage.totalPercent, usage.userPercent, usage.systemPercent] {
            XCTAssertTrue((0...100).contains(value))
        }
    }

    // MARK: Memory

    func testMemoryUsedIsAppPlusWiredPlusCompressed() throws {
        let result = MemoryUsage.calculate(totalBytes: 16_384 * 1_000, pageSize: 16_384,
                                           pages: pages(anonymous: 400, purgeable: 50, wired: 100, compressed: 150, external: 200))
        let usage = try XCTUnwrap(result.value)
        XCTAssertEqual(usage.appBytes, 350 * 16_384)
        XCTAssertEqual(usage.wiredBytes, 100 * 16_384)
        XCTAssertEqual(usage.compressedBytes, 150 * 16_384)
        XCTAssertEqual(usage.cachedFilesBytes, 250 * 16_384)
        XCTAssertEqual(usage.usedBytes, 600 * 16_384)
        XCTAssertEqual(usage.usedFraction, 0.6, accuracy: 1e-9)
    }

    func testMemoryUsedEqualToTotalIsAllowed() {
        let result = MemoryUsage.calculate(totalBytes: 4_096 * 10, pageSize: 4_096, pages: pages(anonymous: 10))
        XCTAssertEqual(result.value?.usedFraction, 1)
    }

    func testInconsistentMemoryValuesAreUnavailableNotZero() {
        let valid = pages(anonymous: 10, wired: 10)
        XCTAssertEqual(MemoryUsage.calculate(totalBytes: 0, pageSize: 4_096, pages: valid), .unavailable(.inconsistentValues))
        XCTAssertEqual(MemoryUsage.calculate(totalBytes: 1 << 30, pageSize: 0, pages: valid), .unavailable(.inconsistentValues))
        XCTAssertEqual(MemoryUsage.calculate(totalBytes: 1 << 30, pageSize: 4_096, pages: pages(anonymous: 5, purgeable: 6)),
                       .unavailable(.inconsistentValues))
        XCTAssertEqual(MemoryUsage.calculate(totalBytes: 4_096 * 10, pageSize: 4_096, pages: pages(anonymous: 6, wired: 5)),
                       .unavailable(.inconsistentValues))
        XCTAssertEqual(MemoryUsage.calculate(totalBytes: .max, pageSize: .max, pages: pages(anonymous: 2)),
                       .unavailable(.inconsistentValues))
    }

    // MARK: Live Mach sampler

    func testMachSamplerReportsBaselineThenValidRanges() async throws {
        let sampler = MachSystemSampler()
        let first = await sampler.sample()
        XCTAssertEqual(first.cpu, .unavailable(.awaitingBaseline))
        let memory = try XCTUnwrap(first.memory.value)
        XCTAssertEqual(memory.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(memory.usedBytes, 0)
        XCTAssertTrue((0...1).contains(memory.usedFraction))

        // HOST_CPU_LOAD_INFO advances in bursts: on macOS 27 (Apple silicon) the counters were seen standing still for
        // up to ~1 s, so a 200 ms interval often had no ticks at all. Wait longer than that, and retry only for the two
        // reasons the tracker skips an interval by design; any other reason fails at once and is reported.
        var reasons: [SystemMetricUnavailableReason] = []
        var cpu: CPUUsage?
        var previous = first
        for _ in 0..<3 where cpu == nil {
            try await Task.sleep(nanoseconds: 1_100_000_000)
            let next = await sampler.sample()
            XCTAssertGreaterThanOrEqual(next.sampledAt, previous.sampledAt)
            previous = next
            switch next.cpu {
            case .available(let usage):
                cpu = usage
            case .unavailable(let reason):
                reasons.append(reason)
                guard reason == .noElapsedTicks || reason == .counterReset else {
                    return XCTFail("CPU unavailable after a baseline: \(reason)")
                }
            }
        }
        if !reasons.isEmpty { print("MACH_CPU_SKIPPED_INTERVALS reasons=\(reasons)") }
        let usage = try XCTUnwrap(cpu, "No CPU value in 3 intervals of 1.1 s; unavailable reasons: \(reasons)")
        XCTAssertTrue((0...100).contains(usage.totalPercent))
    }

    func testRepeatedSamplingDoesNotLeakHostPortReferences() async throws {
        let host = mach_host_self()
        XCTAssertNotEqual(host, mach_port_t(MACH_PORT_NULL))
        defer { XCTAssertEqual(mach_port_deallocate(mach_task_self_, host), KERN_SUCCESS) }
        func sendRefs(file: StaticString = #filePath, line: UInt = #line) -> mach_port_urefs_t {
            var refs: mach_port_urefs_t = 0
            XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &refs), KERN_SUCCESS, file: file, line: line)
            return refs
        }
        let withoutSampler = sendRefs()
        XCTAssertGreaterThan(withoutSampler, 0)
        var sampler: MachSystemSampler? = MachSystemSampler()
        let withSampler = sendRefs()
        XCTAssertEqual(withSampler, withoutSampler + 1)
        for _ in 0..<1_000 { _ = await sampler?.sample() }
        XCTAssertEqual(sendRefs(), withSampler)
        sampler = nil
        XCTAssertEqual(sendRefs(), withSampler - 1)
    }

    @MainActor
    func testStoreSamplesMemoryWithMachSampler() async throws {
        let store = SystemMonitorStore()
        store.setEnabled(.memory, true)
        defer { store.setEnabled(.memory, false) }
        await store.pendingSample?.value
        XCTAssertNotNil(store.memory?.value)
        XCTAssertEqual(store.memoryHistory.points.count, 1)
    }
}
