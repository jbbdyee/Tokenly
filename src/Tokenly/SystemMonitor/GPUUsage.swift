import Foundation
import IOKit
import Metal

/// Static GPU facts for the GPU popover (6-4d), read once per launch.
///
/// - name: the public `MTLDevice.name` of the system default device; if Metal has no device, the IORegistry
///   `model` of the measured accelerator. Never hard-coded.
/// - coreCount: IORegistry `gpu-core-count` of the **same** IOAccelerator service the utilization is read from, and
///   only when that service is the only one (as for utilization). The key is undocumented, so it is shown only when
///   it is an integer in 1...1024; anything else hides the row.
struct GPUDeviceInfo: Equatable {
    let name: String?
    let coreCount: Int?

    static let coreRange = 1...1024

    static func coreCount(from value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFNumberIsFloatType(number) == false else { return nil }
        let count = number.intValue
        return coreRange.contains(count) ? count : nil
    }

    static func make(metalName: String?, registryModel: String?, coreValue: Any?) -> GPUDeviceInfo {
        let trimmed = [metalName, registryModel].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return GPUDeviceInfo(name: trimmed, coreCount: coreCount(from: coreValue))
    }

    /// One IOKit lookup and one Metal device query.
    static func readSystem() -> GPUDeviceInfo {
        var model: String?, cores: Any?
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
            var services: [io_service_t] = []
            var service = IOIteratorNext(iterator)
            while service != IO_OBJECT_NULL { services.append(service); service = IOIteratorNext(iterator) }
            IOObjectRelease(iterator)
            if services.count == 1 {
                model = IORegistryEntryCreateCFProperty(services[0], "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                cores = IORegistryEntryCreateCFProperty(services[0], "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            services.forEach { IOObjectRelease($0) }
        }
        return make(metalName: MTLCreateSystemDefaultDevice()?.name, registryModel: model, coreValue: cores)
    }

    /// Read on first use (lazily, once) and reused.
    static let current = readSystem()
}

/// Raw result of reading every IOAccelerator service, kept separate so validation is testable without IOKit.
enum GPURegistryRead {
    case failed(kern_return_t)
    /// One entry per IOAccelerator service: its `PerformanceStatistics` property, or nil when absent.
    case services([Any?])
}

/// One GPU read.
///
/// **Experimental.** The value comes from `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %`, a key
/// Apple does not document. It may be missing or change meaning on other Macs or macOS versions; it was verified only
/// on an Apple M4 running macOS 27 (Doc/SYSTEM-MONITOR.md §3 V5).
enum GPUReading: Equatable {
    /// An integer percentage in 0...100, kept as Double for averaging.
    case utilization(Double)
    /// Only Apple silicon was verified; other architectures are not read at all.
    case notAppleSilicon
    case noAccelerator
    /// More than one IOAccelerator service: there is no verified rule for choosing one, so none is used.
    case multipleAccelerators(Int)
    case noStatistics
    case noUtilizationKey
    /// Not an integer CFNumber (CFBoolean, string, floating point, or a non-dictionary statistics property).
    case invalidType
    /// An integer outside 0...100. Never clamped.
    case outOfRange
    case readFailed(kern_return_t)

    static let utilizationKey = "Device Utilization %"

    static func make(from read: GPURegistryRead) -> GPUReading {
        let services: [Any?]
        switch read {
        case .failed(let code): return .readFailed(code)
        case .services(let found): services = found
        }
        guard !services.isEmpty else { return .noAccelerator }
        guard services.count == 1 else { return .multipleAccelerators(services.count) }
        return make(statistics: services[0])
    }

    /// Validates one service's `PerformanceStatistics` property (nil when the property, or the service, is gone).
    static func make(statistics property: Any?) -> GPUReading {
        guard let property else { return .noStatistics }
        guard let statistics = property as? [String: Any] else { return .invalidType }
        guard let value = statistics[utilizationKey] else { return .noUtilizationKey }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else { return .invalidType }
        let percent = number.int64Value
        guard (0...100).contains(percent) else { return .outOfRange }
        return .utilization(Double(percent))
    }

    var metric: SystemMetric<Double> {
        switch self {
        case .utilization(let value): .available(value)
        case .readFailed(let code): .unavailable(.readFailed(code))
        case .invalidType, .outOfRange: .unavailable(.inconsistentValues)
        case .notAppleSilicon, .noAccelerator, .multipleAccelerators, .noStatistics, .noUtilizationKey: .unavailable(.unsupported)
        }
    }
}

/// Read times inside each one-second window.
///
/// The window is split into ten ~100 ms slots and each slot is read once, at a pseudo-random offset. A fixed phase can
/// lock onto a periodic GPU load (aliasing: a 50 ms on / 50 ms off load read every 100 ms at the same phase reads as
/// 0 % or 100 % every time). The generator is seeded so tests reproduce exact read times.
struct GPUSampleSchedule {
    static let window: TimeInterval = 1
    static let slots = 10
    static let slotLength: TimeInterval = window / Double(slots)
    /// Offsets keep this far from slot edges, so small timer delays keep reads inside their slot and in order.
    static let edgeMargin: TimeInterval = 0.005

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// Read time for `slot` (0..<slots) of the window starting at `windowStart`, on the monotonic clock.
    mutating func readTime(windowStart: TimeInterval, slot: Int) -> TimeInterval {
        let unit = Double(next() >> 11) / Double(1 << 53)
        let offset = Self.edgeMargin + unit * (Self.slotLength - 2 * Self.edgeMargin)
        return windowStart + Double(slot) * Self.slotLength + offset
    }

    /// SplitMix64: small, fast and fully determined by the seed.
    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The reads of one one-second window and their average.
struct GPUUtilizationWindow {
    static let minimumValidSamples = 5

    /// A closing read later than this after the window's end means the timer stalled (or the Mac slept): the
    /// window no longer describes the last second. Normal closing reads land 5–95 ms after the end (slot 0 offset)
    /// plus the 5 ms timer tolerance; 0.25 s leaves room for main-thread delays without accepting a stalled window.
    static let maxCloseDelay: TimeInterval = 0.25
    /// The newest valid read must be at most this old when the window closes: it must lie in the window's second
    /// half even when the closing read uses its whole `maxCloseDelay` (0.5 + 0.25 s). A tighter limit (0.5 s was
    /// tried) also dropped normal windows whose last few reads failed.
    static let maxValidSampleAge: TimeInterval = 0.75

    struct Sample: Equatable {
        /// Monotonic time the read **began** (taken just before the IOKit call), so a read starting exactly at the
        /// window's end belongs to the next window.
        let time: TimeInterval
        let reading: GPUReading
    }

    let start: TimeInterval
    private(set) var samples: [Sample] = []

    var end: TimeInterval { start + GPUSampleSchedule.window }

    init(start: TimeInterval) {
        self.start = start
    }

    mutating func add(_ sample: Sample) {
        samples.append(sample)
    }

    /// Whether this window may be published when a read at `time` (≥ `end`) closes it. A stale window is dropped:
    /// publishing it would show data from well before "now" as the current value.
    func isFresh(closingAt time: TimeInterval) -> Bool {
        guard time - end <= Self.maxCloseDelay else { return false }
        let lastValid = samples.last { if case .utilization = $0.reading { return true } else { return false } }
        // A window without any valid read is published as its unavailable reason; there is no stale value to show.
        return lastValid.map { time - $0.time <= Self.maxValidSampleAge } ?? true
    }

    /// Mean of the valid reads: an **experimental estimate** of GPU utilization, not an exact system-wide figure.
    /// Failed reads are left out, never counted as 0. Kept as Double; round only for display.
    var result: SystemMetric<Double> {
        let valid = samples.compactMap { sample -> Double? in
            if case .utilization(let value) = sample.reading { return value }
            return nil
        }
        if valid.count >= Self.minimumValidSamples {
            return .available(valid.reduce(0, +) / Double(valid.count))
        }
        // When every read failed for the same reason (e.g. no accelerator), that reason says more than a count.
        if valid.isEmpty, let first = samples.first?.reading.metric, samples.allSatisfy({ $0.reading.metric == first }) {
            return first
        }
        return .unavailable(.insufficientSamples)
    }
}
