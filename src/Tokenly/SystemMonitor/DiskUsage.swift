import Foundation

/// Raw result of reading volume capacity keys, kept separate so the arithmetic is testable without a file system.
enum DiskCapacityRead {
    /// `resourceValues(forKeys:)` threw; the POSIX error code when one was available, otherwise `EIO`.
    case failed(Int32)
    case values(total: Int?, available: Int?, availableForImportantUsage: Int64?)
}

/// Capacity of the APFS container that holds the system volume (`/`).
///
/// - totalBytes: `volumeTotalCapacity`, the container size (the same for `/` and `/System/Volumes/Data`).
/// - availableBytes: `volumeAvailableCapacity`, the space that is free right now, before macOS deletes anything to
///   make room. Matches `statfs` f_bavail, `df`, `diskutil` "Container Free Space" and System Information "Free".
///   The conservative figure.
/// - usedBytes: total − available, so data macOS could still delete on demand counts as used. `usedFraction` follows
///   the same rule.
/// - availableForImportantUsageBytes: `volumeAvailableCapacityForImportantUsage`, Apple's estimate of the space an
///   important request could get, which may include space freed by purging. Its difference from `availableBytes` is
///   **not** an exact purgeable total; the system computes it with its own rules. Close to the "available" figure in
///   System Settings > Storage (65.55 GB vs 65.66 GB, read at different times). Costs ~4 ms per read.
struct DiskUsage: Equatable {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let availableForImportantUsageBytes: SystemMetric<UInt64>

    var usedBytes: UInt64 { totalBytes - availableBytes }
    /// used / total, within 0...1 (guaranteed by `make`).
    var usedFraction: Double { Double(usedBytes) / Double(totalBytes) }

    static func make(from read: DiskCapacityRead) -> SystemMetric<DiskUsage> {
        let total: Int?, available: Int?, important: Int64?
        switch read {
        case .failed(let code):
            return .unavailable(.readFailed(code))
        case .values(let readTotal, let readAvailable, let readImportant):
            (total, available, important) = (readTotal, readAvailable, readImportant)
        }
        guard let total, let available else { return .unavailable(.unsupported) }
        // A real full disk is available == 0 and is reported as such; only impossible values are rejected.
        guard total > 0, available >= 0, available <= total else { return .unavailable(.inconsistentValues) }

        let importantMetric: SystemMetric<UInt64>
        if let important {
            importantMetric = important >= 0 && important <= Int64(total)
                ? .available(UInt64(important)) : .unavailable(.inconsistentValues)
        } else {
            importantMetric = .unavailable(.unsupported)
        }
        return .available(DiskUsage(totalBytes: UInt64(total), availableBytes: UInt64(available),
                                    availableForImportantUsageBytes: importantMetric))
    }
}
