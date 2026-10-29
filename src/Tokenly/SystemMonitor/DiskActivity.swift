import Foundation

/// Cumulative bytes of one physical drive (`IOBlockStorageDriver` statistics), read at a monotonic time that keeps
/// counting during sleep. `device` is the driver's registry entry ID: a different value is a different drive.
struct DiskActivityCounters: Equatable {
    let device: UInt64
    let bytesRead: UInt64
    let bytesWritten: UInt64
    let time: TimeInterval
}

/// One read of the drive behind the system volume: its counters, or why there are none (no drive could be matched
/// to the volume with certainty, or the read failed). Never a stand-in 0.
enum DiskActivityRead: Equatable {
    case counters(DiskActivityCounters)
    case unavailable(SystemMetricUnavailableReason)
}

/// Read and write speed over one interval, in bytes per second. `MB/s` uses 1 MB = 1,000,000 bytes.
struct DiskActivityRate: Equatable {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    var readMBps: Double { readBytesPerSecond / 1_000_000 }
    var writeMBps: Double { writeBytesPerSecond / 1_000_000 }
}

/// Turns cumulative counters into speeds (Doc/SYSTEM-MONITOR.md §7.7-4). Every result that is not a measured speed
/// leaves the next read as a fresh baseline, so a speed is never averaged over a gap, a sleep or a different drive.
///
/// | Case | Result |
/// |---|---|
/// | first read, after a failure, or another drive | `awaitingBaseline` (nothing to show yet) |
/// | interval ≤ 0 | `noElapsedTicks` |
/// | interval > `maxInterval` (sleep, stalled timer) | `awaitingBaseline` |
/// | a counter went down | `counterReset` |
/// | faster than `maxBytesPerSecond` | `inconsistentValues` |
/// | read failed | that reason |
struct DiskActivityRateTracker {
    /// The 1 s timer may run late by its tolerance; anything past the graph's own gap limit is not one interval.
    static let maxInterval: TimeInterval = SystemWidgetPresentation.chartMaxGap
    /// Far beyond any drive (100 GB/s): a counter that jumps this much is not a real transfer.
    static let maxBytesPerSecond: Double = 100_000_000_000

    private(set) var baseline: DiskActivityCounters?

    mutating func reset() {
        baseline = nil
    }

    mutating func update(_ read: DiskActivityRead) -> SystemMetric<DiskActivityRate> {
        guard case .counters(let current) = read else {
            baseline = nil
            if case .unavailable(let reason) = read { return .unavailable(reason) }
            return .unavailable(.unsupported)
        }
        defer { baseline = current }
        guard let previous = baseline, previous.device == current.device else { return .unavailable(.awaitingBaseline) }
        let elapsed = current.time - previous.time
        guard elapsed > 0 else { return .unavailable(.noElapsedTicks) }
        guard elapsed <= Self.maxInterval else { return .unavailable(.awaitingBaseline) }
        guard current.bytesRead >= previous.bytesRead, current.bytesWritten >= previous.bytesWritten else {
            return .unavailable(.counterReset)
        }
        let read = Double(current.bytesRead - previous.bytesRead) / elapsed
        let written = Double(current.bytesWritten - previous.bytesWritten) / elapsed
        guard read <= Self.maxBytesPerSecond, written <= Self.maxBytesPerSecond else { return .unavailable(.inconsistentValues) }
        return .available(DiskActivityRate(readBytesPerSecond: read, writeBytesPerSecond: written))
    }
}

/// What the popover may say about the system volume and its drive. Each field is `nil` when it was not confirmed;
/// the device model and serial number are deliberately not kept.
struct DiskDeviceInfo: Equatable {
    enum Medium: Equatable { case solidState, rotational }

    var volumeName: String?
    /// "APFS" for `apfs`; other file systems upper-cased.
    var fileSystem: String?
    /// From the drive's `Physical Interconnect Location` (Internal / External).
    var isInternal: Bool?
    /// From the drive's `Medium Type` (Solid State / Rotational).
    var medium: Medium?

    static func fileSystemName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.lowercased() == "apfs" ? "APFS" : raw.uppercased()
    }

    static func medium(_ raw: String?) -> Medium? {
        switch raw {
        case "Solid State": .solidState
        case "Rotational": .rotational
        default: nil
        }
    }

    static func isInternal(_ location: String?) -> Bool? {
        switch location {
        case "Internal": true
        case "External": false
        default: nil
        }
    }

    /// "Macintosh HD · APFS · 내장 SSD"; unknown parts are left out, never guessed.
    var summary: String? {
        let place: String? = isInternal.map { $0 ? "내장" : "외장" }
        let kind: String? = medium.map { $0 == .solidState ? "SSD" : "HDD" }
        let drive = [place, kind].compactMap { $0 }.joined(separator: " ")
        let parts = [volumeName, fileSystem, drive.isEmpty ? nil : drive].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One activity reading plus what is known about the volume and drive.
struct DiskActivitySample: Equatable {
    let read: DiskActivityRead
    let device: DiskDeviceInfo?
}

/// Top of a read or write graph in MB/s: the smallest 1-2-5 step at or above the highest point in the 60 s history,
/// never below 1 MB/s. It depends only on the window's peak, so it changes when a peak enters or leaves the window,
/// not every second; idle noise (< 1 MB/s) stays near the floor instead of being blown up.
enum DiskActivityScale {
    static let minimum: Double = 1

    static func upperBound(_ history: SystemMetricHistory) -> Double {
        upperBound(peak: history.points.compactMap(\.value).filter(\.isFinite).max() ?? 0)
    }

    static func upperBound(peak: Double) -> Double {
        guard peak > minimum else { return minimum }
        var decade = 1.0
        while decade * 10 < peak { decade *= 10 }
        for step in [1.0, 2, 5, 10] where decade * step >= peak { return decade * step }
        return decade * 10
    }
}
