import IOKit
import XCTest
@testable import Tokenly

/// GPU read validation, read-time spreading and window averaging with fixed inputs, plus a live read.
final class GPUReadingTests: XCTestCase {
    private let key = GPUReading.utilizationKey

    private func reading(_ value: Any) -> GPUReading {
        GPUReading.make(from: .services([[key: value]]))
    }

    func testIntegerPercentagesAreUtilization() {
        XCTAssertEqual(reading(0), .utilization(0))
        XCTAssertEqual(reading(50), .utilization(50))
        XCTAssertEqual(reading(100), .utilization(100))
        XCTAssertEqual(reading(50).metric, .available(50))
    }

    func testMissingServiceStatisticsOrKeyAreUnsupported() {
        XCTAssertEqual(GPUReading.make(from: .services([])), .noAccelerator)
        XCTAssertEqual(GPUReading.make(from: .services([nil])), .noStatistics)
        XCTAssertEqual(GPUReading.make(from: .services([["Renderer Utilization %": 40]])), .noUtilizationKey)
        for missing in [GPUReading.noAccelerator, .noStatistics, .noUtilizationKey, .notAppleSilicon, .multipleAccelerators(2)] {
            XCTAssertEqual(missing.metric, .unavailable(.unsupported))
        }
    }

    func testSeveralAcceleratorsAreNotGuessed() {
        let both = GPUReading.make(from: .services([[key: 10], [key: 90]]))
        XCTAssertEqual(both, .multipleAccelerators(2), "No verified rule picks one service")
    }

    func testWrongTypesAreNeverUtilization() {
        XCTAssertEqual(reading(true), .invalidType)
        XCTAssertEqual(reading("50"), .invalidType)
        XCTAssertEqual(reading(50.5), .invalidType)
        XCTAssertEqual(reading(50.0), .invalidType, "A floating-point value is not the integer the key is known to hold")
        XCTAssertEqual(GPUReading.make(from: .services(["not a dictionary"])), .invalidType)
        XCTAssertEqual(reading(true).metric, .unavailable(.inconsistentValues))
    }

    func testOutOfRangeIsRejectedNotClamped() {
        XCTAssertEqual(reading(-1), .outOfRange)
        XCTAssertEqual(reading(101), .outOfRange)
        XCTAssertEqual(reading(Int64.max), .outOfRange)
        XCTAssertEqual(reading(101).metric, .unavailable(.inconsistentValues))
    }

    func testReadFailureKeepsItsCode() {
        XCTAssertEqual(GPUReading.make(from: .failed(kIOReturnNotPermitted)), .readFailed(kIOReturnNotPermitted))
        XCTAssertEqual(GPUReading.readFailed(kIOReturnNotPermitted).metric, .unavailable(.readFailed(kIOReturnNotPermitted)))
    }

    /// The only environment where the undocumented key was verified (Doc/SYSTEM-MONITOR.md §3 V5).
    private static var isVerifiedEnvironment: Bool {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return String(cString: model) == "Mac16,12" && (os.majorVersion, os.minorVersion, os.patchVersion) == (27, 0, 1)
    }

    /// Support and value validity are checked separately. Only the verified environment must be supported; another
    /// Mac may legitimately report the key as missing, and that is not claimed to be supported.
    @MainActor
    func testLiveReadOnThisMac() {
        let status = GPUSampler().supportStatus()
        #if arch(arm64)
        XCTAssertNotEqual(status, .notAppleSilicon)
        if case .utilization(let value) = status {
            XCTAssertTrue((0...100).contains(value), "Supported, but the value is invalid: \(value)")
        } else {
            XCTAssertFalse(Self.isVerifiedEnvironment, "The verified Mac must read the GPU: \(status)")
            print("GPU_NOT_SUPPORTED_ON_THIS_MAC status=\(status)")
        }
        if Self.isVerifiedEnvironment {
            guard case .services(let services) = GPUSampler.readRegistry() else { return XCTFail("Registry read failed") }
            XCTAssertEqual(services.count, 1)
        }
        #else
        XCTAssertEqual(status, .notAppleSilicon)
        #endif
    }
}

// MARK: - Cached service handle (GPUSampler)

/// Registry double that tracks every handle it hands out, so tests can check each is released exactly once.
private final class FakeRegistry: GPURegistryAccess {
    var services: [io_service_t] = [11]
    var statistics: [io_service_t: Any] = [11: [GPUReading.utilizationKey: 30]]
    var lookupFailure: kern_return_t?
    private(set) var lookups = 0
    private(set) var statisticsReads = 0
    private(set) var outstanding: [io_service_t: Int] = [:]
    private(set) var overReleased = false
    var held: Int { outstanding.values.reduce(0, +) }

    func matchingServices() -> GPUServiceLookup {
        lookups += 1
        if let lookupFailure { return .failed(lookupFailure) }
        for service in services { outstanding[service, default: 0] += 1 }
        return .found(services)
    }

    func statistics(of service: io_service_t) -> Any? {
        statisticsReads += 1
        return statistics[service]
    }

    func release(_ service: io_service_t) {
        guard let count = outstanding[service] else { overReleased = true; return }
        outstanding[service] = count == 1 ? nil : count - 1
    }
}

private final class TestClock {
    var now: TimeInterval = 100
}

#if arch(arm64)
@MainActor
final class GPUSamplerCacheTests: XCTestCase {
    private var registry: FakeRegistry!
    private var clock: TestClock!
    private var sampler: GPUSampler!

    override func setUp() {
        registry = FakeRegistry()
        clock = TestClock()
        let clock = clock!
        sampler = GPUSampler(registry: registry, clock: { clock.now })
    }

    override func tearDown() {
        sampler = nil
        XCTAssertEqual(registry.held, 0, "Every handle is released by the end")
        XCTAssertFalse(registry.overReleased)
    }

    private func read(times: Int, every step: TimeInterval = 0.1) -> [GPUReading] {
        (0..<times).map { _ in
            defer { clock.now += step }
            return sampler.read()
        }
    }

    func testReusesOneLookupAndReleasesOnReset() {
        XCTAssertTrue(read(times: 10).allSatisfy { $0 == .utilization(30) })
        XCTAssertEqual(registry.lookups, 1, "One lookup, then the cached handle")
        XCTAssertEqual(registry.statisticsReads, 10)
        XCTAssertEqual(registry.held, 1)
        sampler.reset()
        XCTAssertEqual(registry.held, 0)
    }

    func testDeinitReleasesTheCachedHandle() {
        _ = sampler.read()
        XCTAssertEqual(registry.held, 1)
        sampler = nil
        XCTAssertEqual(registry.held, 0)
    }

    func testRevalidatesEveryTenSecondsAndAfterAPause() {
        _ = read(times: 102)
        XCTAssertEqual(registry.lookups, 2, "Fresh lookup once the cache is 10 s old")
        clock.now += GPUSampler.wakeGap + 1
        _ = sampler.read()
        XCTAssertEqual(registry.lookups, 3, "A pause longer than the wake gap forces a lookup")
        XCTAssertEqual(registry.held, 1)
    }

    func testLostServiceIsReplacedAtOnce() {
        _ = sampler.read()
        registry.statistics[11] = nil
        registry.services = [12]
        registry.statistics[12] = [GPUReading.utilizationKey: 40]
        XCTAssertEqual(sampler.read(), .utilization(40))
        XCTAssertEqual(registry.lookups, 2)
        XCTAssertEqual(registry.held, 1, "The lost handle was released, the new one is held")
    }

    func testServiceChangedDuringSleepIsPickedUp() {
        _ = sampler.read()
        registry.services = [12]
        registry.statistics[12] = [GPUReading.utilizationKey: 70]
        clock.now += 30
        // The old handle would still answer (statistics[11] is set), but the wake gap forces a fresh lookup first.
        XCTAssertEqual(sampler.read(), .utilization(70))
        XCTAssertEqual(registry.lookups, 2)
        XCTAssertEqual(registry.held, 1)
    }

    func testFailedLookupIsNotRetriedForFiveSeconds() {
        registry.services = []
        XCTAssertTrue(read(times: 49).allSatisfy { $0 == .noAccelerator })
        XCTAssertEqual(registry.lookups, 1, "No IOKit calls while backing off")
        clock.now = 100 + GPUSampler.unsupportedRetryDelay
        registry.services = [11]
        XCTAssertEqual(sampler.read(), .utilization(30), "Recovers after the retry delay")
        XCTAssertEqual(registry.lookups, 2)
    }

    func testUnsupportedAndTransientFailuresStayDistinct() {
        registry.lookupFailure = kIOReturnNoResources
        XCTAssertEqual(sampler.read(), .readFailed(kIOReturnNoResources))
        XCTAssertEqual(sampler.read().metric, .unavailable(.readFailed(kIOReturnNoResources)))
        sampler.reset()

        registry.lookupFailure = nil
        registry.services = [11, 12]
        XCTAssertEqual(sampler.read(), .multipleAccelerators(2))
        XCTAssertEqual(sampler.read().metric, .unavailable(.unsupported))
        XCTAssertEqual(registry.held, 0, "Both looked-up handles were released")
    }

    /// Replaces the earlier "bad value drops the cache and waits 5 s" expectation: that was the Medium issue.
    func testSingleBadValueRecoversOnTheNextRead() {
        _ = sampler.read()
        registry.statistics[11] = [GPUReading.utilizationKey: 150]
        XCTAssertEqual(sampler.read(), .outOfRange)
        XCTAssertEqual(registry.held, 1, "The service still answers, so its handle is kept")
        registry.statistics[11] = [GPUReading.utilizationKey: true]
        clock.now += 0.1
        XCTAssertEqual(sampler.read(), .invalidType)
        registry.statistics[11] = [GPUReading.utilizationKey: 35]
        clock.now += 0.1
        XCTAssertEqual(sampler.read(), .utilization(35), "Recovered on the next slot, no wait")
        XCTAssertEqual(registry.lookups, 1, "Bad values never trigger lookups")
    }

    func testBadValueOnTheFirstLookupStillCachesTheService() {
        registry.statistics[11] = [GPUReading.utilizationKey: -3]
        XCTAssertEqual(sampler.read(), .outOfRange)
        XCTAssertEqual(registry.held, 1)
        registry.statistics[11] = [GPUReading.utilizationKey: 20]
        clock.now += 0.1
        XCTAssertEqual(sampler.read(), .utilization(20))
        XCTAssertEqual(registry.lookups, 1)
    }

    func testOneTransientFailureRecoversAfterAQuarterSecond() {
        registry.lookupFailure = kIOReturnNoResources
        XCTAssertEqual(sampler.read(), .readFailed(kIOReturnNoResources))
        registry.lookupFailure = nil
        // Binary fractions keep the clock exact at the 0.25 s boundary.
        clock.now += 0.125
        XCTAssertEqual(sampler.read(), .readFailed(kIOReturnNoResources), "Waiting: last failure, no IOKit call")
        XCTAssertEqual(registry.lookups, 1)
        clock.now += 0.125
        XCTAssertEqual(sampler.read(), .utilization(30))
        XCTAssertEqual(registry.lookups, 2)
    }

    func testRepeatedTransientFailuresBackOffToTwoSeconds() {
        registry.lookupFailure = kIOReturnNoResources
        var lookupTimes: [TimeInterval] = []
        // 1/16 s steps are exact in binary, so every retry boundary is hit exactly.
        for _ in 0..<128 {
            let before = registry.lookups
            XCTAssertEqual(sampler.read(), .readFailed(kIOReturnNoResources))
            if registry.lookups > before { lookupTimes.append(clock.now) }
            clock.now += 0.0625
        }
        let gaps = zip(lookupTimes.dropFirst(), lookupTimes).map { $0 - $1 }
        XCTAssertEqual(Array(gaps.prefix(5)), [0.25, 0.5, 1, 2, 2])

        registry.lookupFailure = nil
        clock.now += 2
        XCTAssertEqual(sampler.read(), .utilization(30))
        registry.lookupFailure = kIOReturnNoResources
        registry.statistics[11] = nil
        clock.now += 0.1
        let afterSuccess = registry.lookups
        XCTAssertEqual(sampler.read(), .readFailed(kIOReturnNoResources))
        clock.now += 0.25
        _ = sampler.read()
        XCTAssertEqual(registry.lookups, afterSuccess + 2, "A success resets the wait to 0.25 s")
    }

    func testPersistentlyMissingServiceOrKeyIsLookedUpEveryFiveSeconds() {
        registry.services = []
        _ = read(times: 200)
        XCTAssertEqual(registry.lookups, 4, "Lookups at 0, 5, 10 and 15 s over 20 s, not 10 a second")

        sampler.reset()
        registry.services = [11]
        registry.statistics[11] = ["Renderer Utilization %": 30]
        let before = registry.lookups
        XCTAssertTrue(read(times: 100).allSatisfy { $0 == .noUtilizationKey })
        XCTAssertEqual(registry.lookups - before, 2, "Lookups at 0 and 5 s over 10 s")
        XCTAssertEqual(registry.held, 0, "A service without the key is never kept")
    }

    func testResetClearsTheWaitAndTheTransientCount() {
        registry.lookupFailure = kIOReturnNoResources
        for _ in 0..<4 {
            _ = sampler.read()
            clock.now += 2
        }
        sampler.reset()
        registry.lookupFailure = nil
        XCTAssertEqual(sampler.read(), .utilization(30), "No wait after reset")
        registry.lookupFailure = kIOReturnNoResources
        registry.statistics[11] = nil
        clock.now += 0.1
        let before = registry.lookups
        _ = sampler.read()
        clock.now += 0.25
        _ = sampler.read()
        XCTAssertEqual(registry.lookups, before + 2, "The growing wait started over at 0.25 s")
    }
}
#endif

final class GPUSampleScheduleTests: XCTestCase {
    private func times(seed: UInt64, windows: Int = 1, start: TimeInterval = 0) -> [TimeInterval] {
        var schedule = GPUSampleSchedule(seed: seed)
        return (0..<windows).flatMap { window in
            (0..<GPUSampleSchedule.slots).map { schedule.readTime(windowStart: start + Double(window), slot: $0) }
        }
    }

    func testSameSeedReproducesReadTimes() {
        XCTAssertEqual(times(seed: 7, windows: 3), times(seed: 7, windows: 3))
        XCTAssertNotEqual(times(seed: 7), times(seed: 8))
    }

    func testEachReadStaysInsideItsSlotAwayFromTheEdges() {
        let all = times(seed: 99, windows: 50, start: 1_000)
        for (index, time) in all.enumerated() {
            let slotStart = 1_000 + Double(index / 10) + Double(index % 10) * GPUSampleSchedule.slotLength
            XCTAssertGreaterThanOrEqual(time, slotStart + GPUSampleSchedule.edgeMargin - 1e-9)
            XCTAssertLessThanOrEqual(time, slotStart + GPUSampleSchedule.slotLength - GPUSampleSchedule.edgeMargin + 1e-9)
        }
        let offsets = Set(times(seed: 99).enumerated().map { (($0.element - Double($0.offset) * 0.1) * 1_000).rounded() })
        XCTAssertGreaterThan(offsets.count, 5, "Offsets vary from slot to slot")
    }

    /// A 50 ms on / 50 ms off load has the same 100 ms period as the slots. Reading every slot at one fixed phase sees
    /// only "on" (100 %); spreading the read times recovers the 50 % average over a minute.
    func testSpreadReadTimesAvoidLockingOntoAPeriodicLoad() {
        func load(_ time: TimeInterval) -> Double {
            time.truncatingRemainder(dividingBy: 0.1) < 0.05 ? 100 : 0
        }
        func average(_ reads: [TimeInterval]) -> [Double] {
            stride(from: 0, to: reads.count, by: 10).map { first in
                var window = GPUUtilizationWindow(start: 0)
                for time in reads[first..<first + 10] { window.add(.init(time: time, reading: .utilization(load(time)))) }
                return window.result.value ?? .nan
            }
        }
        let fixedPhase = (0..<600).map { Double($0) * 0.1 + 0.02 }
        XCTAssertEqual(Set(average(fixedPhase)), [100], "Fixed phase: every window reads 100 % for a 50 % load")

        let spread = average(times(seed: 2026, windows: 60))
        let minuteMean = spread.reduce(0, +) / Double(spread.count)
        XCTAssertEqual(minuteMean, 50, accuracy: 6)
        XCTAssertLessThan(spread.filter { $0 == 0 || $0 == 100 }.count, 3, "Windows rarely lock to one phase")
        print("GPU_ALIASING fixed=100 spread_minute_mean=\(String(format: "%.1f", minuteMean)) spread_windows=\(spread.map { Int($0) })")
    }
}

final class GPUUtilizationWindowTests: XCTestCase {
    private func window(_ readings: [GPUReading]) -> GPUUtilizationWindow {
        var window = GPUUtilizationWindow(start: 0)
        for (index, reading) in readings.enumerated() { window.add(.init(time: Double(index) * 0.1, reading: reading)) }
        return window
    }

    func testMeanOfValidReads() {
        XCTAssertEqual(window(Array(repeating: .utilization(0), count: 10)).result, .available(0))
        XCTAssertEqual(window(Array(repeating: .utilization(100), count: 10)).result, .available(100))
        XCTAssertEqual(window([.utilization(10), .utilization(20), .utilization(30), .utilization(40), .utilization(55)]).result,
                       .available(31))
    }

    func testFailedReadsAreLeftOutNotCountedAsZero() {
        let mixed = window(Array(repeating: .utilization(80), count: 5) + Array(repeating: .readFailed(kIOReturnError), count: 5))
        XCTAssertEqual(mixed.result, .available(80))
    }

    func testFewerThanFiveValidReadsIsUnavailable() {
        let four = window(Array(repeating: .utilization(80), count: 4) + Array(repeating: .outOfRange, count: 6))
        XCTAssertEqual(four.result, .unavailable(.insufficientSamples))
        XCTAssertEqual(window([]).result, .unavailable(.insufficientSamples))
        XCTAssertEqual(window([.noAccelerator, .readFailed(kIOReturnError)]).result, .unavailable(.insufficientSamples))
    }

    func testFreshnessAtTheWindowEnd() {
        var window = GPUUtilizationWindow(start: 0)
        for slot in 0..<10 { window.add(.init(time: Double(slot) * 0.1 + 0.05, reading: .utilization(50))) }
        XCTAssertTrue(window.isFresh(closingAt: 1.0), "A read exactly at the end closes the window normally")
        XCTAssertTrue(window.isFresh(closingAt: 1.0 + GPUUtilizationWindow.maxCloseDelay))
        XCTAssertFalse(window.isFresh(closingAt: 1.0 + GPUUtilizationWindow.maxCloseDelay + 0.01))
        XCTAssertFalse(window.isFresh(closingAt: 1.9), "Resuming 1.9 s after the start is stale")
        XCTAssertFalse(window.isFresh(closingAt: 31), "Sleep")
    }

    func testFreshnessLooksAtTheNewestValidRead() {
        var early = GPUUtilizationWindow(start: 0)
        for slot in 0..<5 { early.add(.init(time: Double(slot) * 0.1 + 0.05, reading: .utilization(50))) }
        for slot in 5..<10 { early.add(.init(time: Double(slot) * 0.1 + 0.05, reading: .readFailed(kIOReturnError))) }
        XCTAssertTrue(early.isFresh(closingAt: 1.05), "Failed tail: newest valid read 0.6 s old is still fresh")
        XCTAssertFalse(early.isFresh(closingAt: 1.25), "Newest valid read 0.8 s old is stale")

        let failedOnly = window(Array(repeating: .noAccelerator, count: 10))
        XCTAssertTrue(failedOnly.isFresh(closingAt: 1.05), "No value to be stale; its reason is published")
    }

    func testUniformFailureKeepsItsReason() {
        XCTAssertEqual(window(Array(repeating: .noAccelerator, count: 10)).result, .unavailable(.unsupported))
        XCTAssertEqual(window(Array(repeating: .invalidType, count: 10)).result, .unavailable(.inconsistentValues))
    }
}
