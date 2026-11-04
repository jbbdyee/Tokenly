import Darwin
import XCTest
@testable import Tokenly

/// CPU and memory arithmetic with fixed counters, plus a smoke test against the real Mach host.
final class SystemMonitorTests: XCTestCase {
    private func ticks(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CPUTickCounters {
        CPUTickCounters(user: user, system: system, idle: idle, nice: nice)
    }

    private func pages(anonymous: UInt32 = 0, purgeable: UInt32 = 0, wired: UInt32 = 0, compressed: UInt32 = 0,
                       external: UInt32 = 0, free: UInt32 = 0) -> VMPageCounters {
        VMPageCounters(anonymous: anonymous, purgeable: purgeable, wired: wired, compressed: compressed, external: external,
                       free: free)
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

    func testMemoryUsedIsPhysicalMinusFreeAndFileCache() throws {
        // 1000 pages: 150 free, 200 file-backed; app 350 + wired 100 + compressed 150 = 600; 50 pages in no counter.
        let result = MemoryUsage.calculate(totalBytes: 16_384 * 1_000, pageSize: 16_384,
                                           pages: pages(anonymous: 400, purgeable: 50, wired: 100, compressed: 150,
                                                        external: 200, free: 150))
        let usage = try XCTUnwrap(result.value)
        XCTAssertEqual(usage.appBytes, 350 * 16_384)
        XCTAssertEqual(usage.wiredBytes, 100 * 16_384)
        XCTAssertEqual(usage.compressedBytes, 150 * 16_384)
        XCTAssertEqual(usage.cachedFilesBytes, 200 * 16_384)
        XCTAssertEqual(usage.usedBytes, 650 * 16_384, "1000 − 150 free − 200 file cache")
        XCTAssertEqual(usage.otherBytes, 50 * 16_384, "purgeable and unattributed pages")
        XCTAssertEqual(usage.usedFraction, 0.65, accuracy: 1e-9)
        XCTAssertEqual(usage.usedBytes + usage.cachedFilesBytes + 150 * 16_384, usage.totalBytes)
    }

    func testMemoryUsedEqualToTotalIsAllowed() {
        let result = MemoryUsage.calculate(totalBytes: 4_096 * 10, pageSize: 4_096, pages: pages(anonymous: 10))
        XCTAssertEqual(result.value?.usedFraction, 1)
    }

    func testMemoryUsageStaysWithinZeroAndHundredPercent() throws {
        let total: UInt64 = 16_384 * 1_000
        let allFree = try XCTUnwrap(MemoryUsage.calculate(totalBytes: total, pageSize: 16_384, pages: pages(free: 1_000)).value)
        XCTAssertEqual(allFree.usedFraction, 0)
        let allCache = try XCTUnwrap(MemoryUsage.calculate(totalBytes: total, pageSize: 16_384,
                                                           pages: pages(external: 990, free: 10)).value)
        XCTAssertEqual(allCache.usedFraction, 0)
        let full = try XCTUnwrap(MemoryUsage.calculate(totalBytes: total, pageSize: 16_384,
                                                       pages: pages(anonymous: 500, wired: 300, compressed: 200)).value)
        XCTAssertEqual(full.usedFraction, 1)
        // A non-atomic read where the parts exceed total − free − cache keeps used at the parts (other is never negative).
        let skewed = try XCTUnwrap(MemoryUsage.calculate(totalBytes: total, pageSize: 16_384,
                                                         pages: pages(anonymous: 500, wired: 200, compressed: 100,
                                                                      external: 150, free: 100)).value)
        XCTAssertEqual(skewed.usedBytes, 800 * 16_384)
        XCTAssertEqual(skewed.otherBytes, 0)
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
        XCTAssertEqual(MemoryUsage.calculate(totalBytes: 4_096 * 10, pageSize: 4_096, pages: pages(external: 6, free: 5)),
                       .unavailable(.inconsistentValues), "free + file cache above total")
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

// MARK: - RAM-02 regression (v0.4.1): recorded counters, not invented ones

extension SystemMonitorTests {
    private static let gib = Double(1 << 30)
    private static let pageSize: UInt64 = 16_384
    private static let physical16: UInt64 = 17_179_869_184

    /// One `HOST_VM_INFO64` read (pages) next to the Activity Monitor value read between two such reads.
    private struct PairedRead {
        let anonymous, purgeable, external, wired, compressed, free: UInt32
        let activityMonitorUsedGB: Double
    }

    /// 2026-11-04 UTC 06:51:28–06:51:46, macOS 27.0.1, 16 GiB Apple M4: raw read immediately before reading
    /// "사용된 메모리" from Activity Monitor's Memory tab (accessibility, read-only). Activity Monitor shows GB in 1024³ B.
    private static let paired: [PairedRead] = [
        .init(anonymous: 245_210, purgeable: 2_210, external: 170_257, wired: 187_514, compressed: 401_048, free: 11_102, activityMonitorUsedGB: 13.29),
        .init(anonymous: 262_114, purgeable: 3_300, external: 161_122, wired: 183_845, compressed: 397_311, free: 5_672, activityMonitorUsedGB: 13.46),
        .init(anonymous: 273_256, purgeable: 2_756, external: 161_153, wired: 178_530, compressed: 391_205, free: 5_946, activityMonitorUsedGB: 13.46),
        .init(anonymous: 270_691, purgeable: 5_342, external: 160_428, wired: 182_960, compressed: 390_858, free: 5_058, activityMonitorUsedGB: 13.46),
        .init(anonymous: 272_674, purgeable: 2_340, external: 160_524, wired: 182_935, compressed: 387_610, free: 6_243, activityMonitorUsedGB: 13.48),
        .init(anonymous: 272_607, purgeable: 3_420, external: 160_086, wired: 182_508, compressed: 388_908, free: 6_957, activityMonitorUsedGB: 13.47),
        .init(anonymous: 269_780, purgeable: 2, external: 160_680, wired: 188_850, compressed: 385_128, free: 7_097, activityMonitorUsedGB: 13.43),
    ]

    func testUsedMatchesActivityMonitorOnRecordedPairedReads() throws {
        for (index, read) in Self.paired.enumerated() {
            let pages = VMPageCounters(anonymous: read.anonymous, purgeable: read.purgeable, wired: read.wired,
                                       compressed: read.compressed, external: read.external, free: read.free)
            let usage = try XCTUnwrap(MemoryUsage.calculate(totalBytes: Self.physical16, pageSize: Self.pageSize, pages: pages).value)
            let usedGiB = Double(usage.usedBytes) / Self.gib
            let partsGiB = Double(usage.appBytes + usage.wiredBytes + usage.compressedBytes) / Self.gib
            // Within 0.07 GiB: Activity Monitor refreshes on its own schedule between the two raw reads.
            XCTAssertEqual(usedGiB, read.activityMonitorUsedGB, accuracy: 0.07, "pair \(index + 1)")
            // The previous app + wired + compressed definition was 0.55–0.66 GiB below on the same reads.
            XCTAssertGreaterThan(read.activityMonitorUsedGB - partsGiB, 0.5, "pair \(index + 1)")
            XCTAssertEqual(usage.usedBytes, usage.appBytes + usage.wiredBytes + usage.compressedBytes + usage.otherBytes)
            XCTAssertTrue((0...1).contains(usage.usedFraction))
        }
    }

    /// The three 2026-10-29 reads (UTC 06:02:37–39) recorded with the old sum and the residual
    /// total − used − (external + purgeable) − free. The new used is the old sum plus exactly that residual and the
    /// purgeable pages, byte for byte: the gap was pages no counter attributes, not a rounding or unit effect.
    func testNewUsedEqualsOldSumPlusRecordedResidual() throws {
        let recorded: [(VMPageCounters, oldUsed: UInt64, residual: UInt64)] = [
            (VMPageCounters(anonymous: 264_014, purgeable: 0, wired: 199_046, compressed: 384_458, external: 157_246, free: 6_955),
             13_885_734_912, 603_865_088),
            (VMPageCounters(anonymous: 261_388, purgeable: 1_260, wired: 205_154, compressed: 383_534, external: 154_422, free: 7_209),
             13_907_001_344, 604_061_696),
            (VMPageCounters(anonymous: 256_430, purgeable: 8, wired: 214_049, compressed: 381_250, external: 152_135, free: 7_858),
             13_954_596_864, 603_815_936),
        ]
        for (pages, oldUsed, residual) in recorded {
            let usage = try XCTUnwrap(MemoryUsage.calculate(totalBytes: Self.physical16, pageSize: Self.pageSize, pages: pages).value)
            XCTAssertEqual(usage.appBytes + usage.wiredBytes + usage.compressedBytes, oldUsed, "parts unchanged")
            XCTAssertEqual(usage.usedBytes, oldUsed + residual + UInt64(pages.purgeable) * Self.pageSize)
            XCTAssertEqual(usage.otherBytes, residual + UInt64(pages.purgeable) * Self.pageSize)
        }
    }

    /// A 24 GiB Mac (1,572,864 pages of 16 KiB). Constructed to mirror the reported capture's parts
    /// (app 9.30, wired 2.73, compressed 4.55 GiB) with 1.41 GiB of unattributed pages: used is 18.00 GiB, which is
    /// what the capture's Activity Monitor showed. This shows the formula can express that gap; the friend's raw
    /// counters were never captured, so it does not prove that the 24 GiB gap was unattributed pages.
    func testTwentyFourGiBLayoutKeepsPercentAndPartsOnOneBasis() throws {
        let page = Double(Self.pageSize)
        func pages(_ gib: Double) -> UInt32 { UInt32((gib * Self.gib / page).rounded()) }
        let total: UInt64 = 24 << 30
        let app = pages(9.30), wired = pages(2.73), compressed = pages(4.55)
        let used = UInt32(total / Self.pageSize) - pages(6.00)
        let free = pages(0.20), external = UInt32(total / Self.pageSize) - used - free
        let counters = VMPageCounters(anonymous: app, purgeable: 0, wired: wired, compressed: compressed,
                                      external: external, free: free)
        let usage = try XCTUnwrap(MemoryUsage.calculate(totalBytes: total, pageSize: Self.pageSize, pages: counters).value)
        XCTAssertEqual(Double(usage.usedBytes) / Self.gib, 18.00, accuracy: 0.001)
        XCTAssertEqual(Double(usage.otherBytes) / Self.gib, 1.41, accuracy: 0.01)
        XCTAssertEqual(usage.usedFraction, 0.75, accuracy: 0.0001)
        // Menu bar and popover read the same fraction.
        XCTAssertEqual(SystemWidgetPresentation.memory(.available(usage)).text,
                       SystemWidgetPresentation.usagePercent(usage.usedFraction * 100).map { "\($0)%" })
    }
}
