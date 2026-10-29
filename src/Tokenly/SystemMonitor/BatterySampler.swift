import Foundation
import IOKit
import IOKit.ps

/// Battery reads used by SystemMonitorStore; a protocol so the store can be tested without hardware.
protocol BatterySampling {
    func sample() -> SystemMetric<BatteryStatus>
    func samplePowerState() -> SystemMetric<BatteryPowerState>
}

/// Reads battery health (AppleSmartBattery IORegistry entry) and live charge state (IOPowerSources). Stateless and
/// independent of the CPU/RAM sampler.
struct BatterySampler: BatterySampling {
    func sample() -> SystemMetric<BatteryStatus> {
        BatteryStatus.make(from: Self.readRegistry())
    }

    func samplePowerState() -> SystemMetric<BatteryPowerState> {
        BatteryPowerState.make(from: Self.readPowerSources(), adapter: Self.readAdapter())
    }

    /// Public adapter details; only the watts are used (no serial or other identifiers are kept).
    static func readAdapter() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }

    static func readPowerSources() -> PowerSourcesRead {
        // Copy functions return retained objects; descriptions are borrowed from the blob, which outlives their use here.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return .failed }
        return .sources(list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] })
    }

    static func readRegistry() -> BatteryRegistryRead {
        // IOServiceGetMatchingService consumes the matching dictionary; the returned service must be released.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return .noService }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS else { return .failed(result) }
        // Create rule: the dictionary is returned retained, so take ownership exactly once.
        guard let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return .failed(kIOReturnError) }
        return .properties(dictionary, pack: readPackData(of: service))
    }

    /// `BatteryData` of the battery service's one `AppleSmartBatteryPack` child; `nil` if there is none or more than one
    /// (no guessing which pack), or it has no such dictionary.
    static func readPackData(of service: io_object_t) -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var packs: [io_object_t] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            if IOObjectConformsTo(child, "AppleSmartBatteryPack") != 0 { packs.append(child) } else { IOObjectRelease(child) }
        }
        defer { packs.forEach { IOObjectRelease($0) } }
        guard packs.count == 1 else { return nil }
        return IORegistryEntryCreateCFProperty(packs[0], "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}
