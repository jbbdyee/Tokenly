import Foundation
import IOKit
import IOKit.storage

/// Disk activity reads used by SystemMonitorStore; a protocol so the store can be tested without IOKit.
protocol DiskActivitySampling {
    func sample() async -> DiskActivitySample
}

/// Reads the cumulative bytes of the one physical drive behind the system volume `/` (public IOKit storage keys,
/// `IOKit/storage/IOBlockStorageDriver.h`; no administrator rights).
///
/// The drive is found by walking the IORegistry service plane up from the volume's BSD media (`/` → APFS volume →
/// container → physical store partition → whole disk → `IOBlockStorageDriver`). Every step must have exactly one
/// provider, so a container on several drives (or anything ambiguous) is `unsupported` instead of a guess, and a
/// disk image or other virtual device (`Physical Interconnect` = "Virtual Interface") is never used. Summing all
/// drivers would mix in mounted disk images.
///
/// The match is cached by registry entry ID; if that entry disappears the next read locates the drive again (a new
/// ID, so the tracker re-baselines). An actor: reads run off the main actor.
actor DiskActivitySampler: DiskActivitySampling {
    static let systemVolumePath = "/"
    /// Service-plane steps allowed between the volume media and its driver (10 on an M4 Mac).
    static let maxDepth = 32

    private struct Match {
        let registryID: UInt64
        let device: DiskDeviceInfo
    }

    private var match: Match?
    /// Volume name and file system, read once; kept even when no drive could be matched.
    private var volume: DiskDeviceInfo?

    func sample() -> DiskActivitySample {
        if volume == nil { volume = Self.volumeInfo(path: Self.systemVolumePath) }
        if match == nil {
            switch Self.locate(path: Self.systemVolumePath) {
            case .success(let found):
                var device = volume ?? DiskDeviceInfo()
                device.isInternal = found.device.isInternal
                device.medium = found.device.medium
                match = Match(registryID: found.registryID, device: device)
            case .failure(let reason):
                return DiskActivitySample(read: .unavailable(reason.value), device: volume)
            }
        }
        guard let match else { return DiskActivitySample(read: .unavailable(.unsupported), device: volume) }
        guard let counters = Self.counters(registryID: match.registryID) else {
            self.match = nil
            return DiskActivitySample(read: .unavailable(.readFailed(kIOReturnNotFound)), device: volume)
        }
        return DiskActivitySample(read: .counters(counters), device: match.device)
    }

    // MARK: IOKit

    struct LocateFailure: Error {
        let value: SystemMetricUnavailableReason
    }

    static func volumeInfo(path: String) -> DiskDeviceInfo {
        var info = DiskDeviceInfo()
        info.volumeName = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey]))?
            .volumeLocalizedName.flatMap { $0.isEmpty ? nil : $0 }
        var fs = statfs()
        if statfs(path, &fs) == 0 {
            info.fileSystem = DiskDeviceInfo.fileSystemName(withUnsafeBytes(of: fs.f_fstypename) { cString($0) })
        }
        return info
    }

    static func locate(path: String) -> Result<(registryID: UInt64, device: DiskDeviceInfo), LocateFailure> {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return .failure(LocateFailure(value: .readFailed(errno))) }
        let source = withUnsafeBytes(of: fs.f_mntfromname) { cString($0) } ?? ""
        guard source.hasPrefix("/dev/"), let matching = IOBSDNameMatching(kIOMainPortDefault, 0, String(source.dropFirst(5))) else {
            return .failure(LocateFailure(value: .unsupported))
        }
        // IOServiceGetMatchingService consumes `matching`.
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return .failure(LocateFailure(value: .unsupported)) }
        for _ in 0..<maxDepth {
            if IOObjectConformsTo(entry, kIOBlockStorageDriverClass) != 0 {
                defer { IOObjectRelease(entry) }
                return driverMatch(entry)
            }
            guard let parent = onlyParent(of: entry) else {
                IOObjectRelease(entry)
                return .failure(LocateFailure(value: .unsupported))
            }
            IOObjectRelease(entry)
            entry = parent
        }
        IOObjectRelease(entry)
        return .failure(LocateFailure(value: .unsupported))
    }

    /// The driver must sit on a real (not virtual) storage device and publish both byte counters.
    private static func driverMatch(_ driver: io_object_t) -> Result<(registryID: UInt64, device: DiskDeviceInfo), LocateFailure> {
        guard let device = onlyParent(of: driver) else { return .failure(LocateFailure(value: .unsupported)) }
        defer { IOObjectRelease(device) }
        let protocolInfo = property(device, kIOPropertyProtocolCharacteristicsKey) as? [String: Any]
        let interconnect = protocolInfo?[kIOPropertyPhysicalInterconnectTypeKey] as? String
        guard let protocolInfo, interconnect != kIOPropertyPhysicalInterconnectTypeVirtual else {
            return .failure(LocateFailure(value: .unsupported))
        }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(driver, &registryID) == KERN_SUCCESS,
              statistics(driver) != nil else { return .failure(LocateFailure(value: .unsupported)) }
        let characteristics = property(device, kIOPropertyDeviceCharacteristicsKey) as? [String: Any]
        var info = DiskDeviceInfo()
        info.isInternal = DiskDeviceInfo.isInternal(protocolInfo[kIOPropertyPhysicalInterconnectLocationKey] as? String)
        info.medium = DiskDeviceInfo.medium(characteristics?[kIOPropertyMediumTypeKey] as? String)
        return .success((registryID, info))
    }

    static func counters(registryID: UInt64) -> DiskActivityCounters? {
        guard let matching = IORegistryEntryIDMatching(registryID) else { return nil }
        let driver = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard driver != 0 else { return nil }
        defer { IOObjectRelease(driver) }
        guard let stats = statistics(driver) else { return nil }
        let time = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
        return DiskActivityCounters(device: registryID, bytesRead: stats.read, bytesWritten: stats.written, time: time)
    }

    private static func statistics(_ driver: io_object_t) -> (read: UInt64, written: UInt64)? {
        guard let stats = property(driver, kIOBlockStorageDriverStatisticsKey) as? [String: Any],
              let read = (stats[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.uint64Value,
              let written = (stats[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.uint64Value else { return nil }
        return (read, written)
    }

    /// The entry's provider when it has exactly one; `nil` for none or several.
    private static func onlyParent(of entry: io_object_t) -> io_object_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var parents: [io_object_t] = []
        while case let parent = IOIteratorNext(iterator), parent != 0 { parents.append(parent) }
        guard parents.count == 1 else {
            parents.forEach { IOObjectRelease($0) }
            return nil
        }
        return parents[0]
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func cString(_ buffer: UnsafeRawBufferPointer) -> String? {
        guard let base = buffer.bindMemory(to: CChar.self).baseAddress else { return nil }
        return String(cString: base)
    }
}
