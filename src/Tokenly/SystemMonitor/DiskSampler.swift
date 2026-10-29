import Foundation

/// Disk reads used by SystemMonitorStore; a protocol so the store can be tested without a file system.
protocol DiskSampling {
    func sample() async -> SystemMetric<DiskUsage>
}

/// Reads the system volume's capacity with the public URL resource-value API. Stateless.
///
/// `sample()` is a nonisolated async function, so it runs off the main actor: the important-usage key alone takes
/// ~4 ms (total and available take ~11 µs).
struct DiskSampler: DiskSampling {
    static let systemVolumePath = "/"

    func sample() async -> SystemMetric<DiskUsage> {
        DiskUsage.make(from: Self.read(path: Self.systemVolumePath))
    }

    static func read(path: String) -> DiskCapacityRead {
        // A new URL every time: a URL object caches resource values, and a reused one kept reporting the old free
        // space after a 1 GiB write.
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey])
            return .values(total: values.volumeTotalCapacity, available: values.volumeAvailableCapacity,
                           availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage)
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let posix = [error as NSError, underlying].compactMap { $0 }.first { $0.domain == NSPOSIXErrorDomain }
            return .failed(posix.map { Int32($0.code) } ?? EIO)
        }
    }
}
