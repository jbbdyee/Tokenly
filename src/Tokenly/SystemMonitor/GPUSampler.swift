import Foundation
import IOKit

/// GPU reads used by SystemMonitorStore; a protocol so the store can be tested without IOKit.
///
/// Main-actor isolated: a sampler keeps state between reads (cached handle, retry times), so one instance must never
/// be used from two execution contexts. The store reads it on the main actor; UI code must do the same.
@MainActor
protocol GPUSampling {
    func read() -> GPUReading
    /// Drops anything held between reads (a cached service handle). Called when the GPU metric is turned off.
    func reset()
}

extension GPUSampling {
    func reset() {}
}

/// Result of looking up IOAccelerator services.
enum GPUServiceLookup {
    case failed(kern_return_t)
    /// Every matching service, each retained for the caller, who must release each exactly once.
    case found([io_service_t])
}

/// The IOKit calls `GPUSampler` makes, replaceable in tests to check handle ownership without hardware.
protocol GPURegistryAccess {
    func matchingServices() -> GPUServiceLookup
    /// The service's `PerformanceStatistics` property, or nil when it (or the service) is gone.
    func statistics(of service: io_service_t) -> Any?
    func release(_ service: io_service_t)
}

struct LiveGPURegistry: GPURegistryAccess {
    func matchingServices() -> GPUServiceLookup {
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes the matching dictionary; IOIteratorNext hands out retained services.
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard result == KERN_SUCCESS else { return .failed(result) }
        defer { IOObjectRelease(iterator) }
        var services: [io_service_t] = []
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            services.append(service)
            service = IOIteratorNext(iterator)
        }
        return .found(services)
    }

    func statistics(of service: io_service_t) -> Any? {
        IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    func release(_ service: io_service_t) {
        IOObjectRelease(service)
    }
}

/// Reads `Device Utilization %` from the IOAccelerator service. **Experimental**: the key is undocumented (see
/// `GPUReading`).
///
/// The service handle is cached between reads: a lookup costs ~120–150 µs of the ~290–350 µs a 100 ms-apart read
/// took (Doc/logs/2026-10-27-gpu-cost.txt). Rules:
/// - A service whose statistics carry the utilization key is cached (owned here, released exactly once on
///   invalidation, `reset()` or deinit), even when the value itself is bad: the service still answers.
/// - The cache is re-validated by a fresh lookup every `revalidateInterval`, and after a pause longer than `wakeGap`
///   between reads (sleep, or the metric being paused), so a GPU reset or service change is picked up.
///
/// Failures are handled by kind, so a passing glitch never blanks the value for long while a Mac without the key is
/// not looked up ten times a second:
/// - **Bad value** (`invalidType`, `outOfRange`) from a reachable service: keep the handle, no wait. The next slot
///   (~100 ms later) reads again; the bad read is simply not counted in the window.
/// - **Service lost** (the cached service no longer has the statistics or the key): release the handle and look the
///   services up at once, then apply the rule for whatever that lookup returns.
/// - **Transient** (`readFailed`: the IOKit lookup call itself failed): retry after `transientRetryDelays`, growing
///   0.25 → 0.5 → 1 → 2 s while failures repeat, back to 0.25 s after any success.
/// - **Unsupported** (no service, several services, no statistics, no key): retry after `unsupportedRetryDelay`
///   (5 s). These describe the Mac, not a moment, so frequent lookups would only cost time.
/// While waiting, reads return the last failure without calling IOKit; it is never turned into 0 % or a value.
///
/// Main-actor isolated (see `GPUSampling`).
@MainActor
final class GPUSampler: GPUSampling {
    static let revalidateInterval: TimeInterval = 10
    static let wakeGap: TimeInterval = 2
    static let transientRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2]
    static let unsupportedRetryDelay: TimeInterval = 5

    private let registry: any GPURegistryAccess
    private let clock: () -> TimeInterval
    private var cached: io_service_t = IO_OBJECT_NULL
    private var cachedAt: TimeInterval = 0
    private var lastReadAt: TimeInterval?
    private var retryAfter: TimeInterval?
    private var lastFailure: GPUReading = .noAccelerator
    /// Consecutive transient lookup failures, choosing the next entry of `transientRetryDelays`.
    private var transientFailures = 0

    init(registry: any GPURegistryAccess = LiveGPURegistry(),
         clock: @escaping () -> TimeInterval = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }) {
        self.registry = registry
        self.clock = clock
    }

    deinit {
        // Runs once nothing else references the sampler, so touching its state here cannot race.
        if cached != IO_OBJECT_NULL { registry.release(cached) }
    }

    func read() -> GPUReading {
        #if arch(arm64)
        let now = clock()
        defer { lastReadAt = now }
        if let lastReadAt, now - lastReadAt > Self.wakeGap { dropCache() }
        if cached != IO_OBJECT_NULL, now - cachedAt >= Self.revalidateInterval { dropCache() }

        if cached != IO_OBJECT_NULL {
            let reading = GPUReading.make(statistics: registry.statistics(of: cached))
            if Self.serviceAnswers(reading) { return reading }
            dropCache()
        }
        if let retryAfter, now < retryAfter { return lastFailure }
        return lookUp(at: now)
        #else
        return .notAppleSilicon
        #endif
    }

    func reset() {
        dropCache()
        lastReadAt = nil
        retryAfter = nil
        transientFailures = 0
    }

    /// One read, for settings to explain why the GPU widget is unavailable before it is ever enabled.
    /// `.utilization` means supported on this Mac right now; every other case is the reason it is not.
    func supportStatus() -> GPUReading {
        read()
    }

    /// A full lookup and read without the cache, for diagnostics and tests.
    static func readRegistry(_ registry: any GPURegistryAccess = LiveGPURegistry()) -> GPURegistryRead {
        switch registry.matchingServices() {
        case .failed(let code):
            return .failed(code)
        case .found(let services):
            defer { services.forEach(registry.release) }
            return .services(services.map { registry.statistics(of: $0) })
        }
    }

    private func lookUp(at now: TimeInterval) -> GPUReading {
        let services: [io_service_t]
        switch registry.matchingServices() {
        case .failed(let code):
            return fail(.readFailed(code), at: now)
        case .found(let found):
            services = found
        }
        guard services.count == 1 else {
            services.forEach(registry.release)
            return fail(services.isEmpty ? .noAccelerator : .multipleAccelerators(services.count), at: now)
        }
        let reading = GPUReading.make(statistics: registry.statistics(of: services[0]))
        guard Self.serviceAnswers(reading) else {
            registry.release(services[0])
            return fail(reading, at: now)
        }
        cached = services[0]
        cachedAt = now
        retryAfter = nil
        transientFailures = 0
        return reading
    }

    /// The service has the statistics and the key: a value, or a bad value that the next read may correct.
    private static func serviceAnswers(_ reading: GPUReading) -> Bool {
        switch reading {
        case .utilization, .invalidType, .outOfRange: true
        default: false
        }
    }

    private func fail(_ reading: GPUReading, at now: TimeInterval) -> GPUReading {
        let delay: TimeInterval
        if case .readFailed = reading {
            delay = Self.transientRetryDelays[min(transientFailures, Self.transientRetryDelays.count - 1)]
            transientFailures += 1
        } else {
            delay = Self.unsupportedRetryDelay
            transientFailures = 0
        }
        retryAfter = now + delay
        lastFailure = reading
        return reading
    }

    private func dropCache() {
        guard cached != IO_OBJECT_NULL else { return }
        registry.release(cached)
        cached = IO_OBJECT_NULL
    }
}
