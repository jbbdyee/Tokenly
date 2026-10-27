import Foundation

/// One metric in a snapshot: either measured, or explicitly unavailable. Unavailable values are never reported as 0.
enum SystemMetric<Value: Equatable>: Equatable {
    case available(Value)
    case unavailable(SystemMetricUnavailableReason)

    var value: Value? {
        if case .available(let value) = self { return value }
        return nil
    }
}

enum SystemMetricUnavailableReason: Equatable {
    /// The first CPU sample only records a baseline; usage needs two samples.
    case awaitingBaseline
    /// A cumulative counter went backwards (reset or 32-bit wrap); the interval is skipped and re-baselined.
    case counterReset
    /// No ticks elapsed between samples, so there is nothing to divide by.
    case noElapsedTicks
    /// Values were internally inconsistent (e.g. used memory larger than physical memory, zero page size).
    case inconsistentValues
    /// The Mach call failed with this kern_return_t.
    case readFailed(kern_return_t)
}

// MARK: - CPU

/// Cumulative CPU ticks since boot, summed over all logical CPUs (HOST_CPU_LOAD_INFO, natural_t counters).
struct CPUTickCounters: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Share of CPU time between two samples. Every field is within 0...100.
struct CPUUsage: Equatable {
    /// user + nice + system.
    let totalPercent: Double
    /// user + nice.
    let userPercent: Double
    let systemPercent: Double
}

/// Turns successive cumulative counters into usage. A value type without Mach calls, so the arithmetic is unit-testable.
struct CPUUsageTracker {
    private(set) var baseline: CPUTickCounters?

    /// Returns usage since the previous call and keeps `current` as the next baseline.
    mutating func update(with current: CPUTickCounters) -> SystemMetric<CPUUsage> {
        defer { baseline = current }
        guard let previous = baseline else { return .unavailable(.awaitingBaseline) }
        return Self.usage(from: previous, to: current)
    }

    static func usage(from previous: CPUTickCounters, to current: CPUTickCounters) -> SystemMetric<CPUUsage> {
        // Wrapping arithmetic cannot tell a 32-bit wrap from a reset, so any decrease skips this interval.
        guard current.user >= previous.user, current.system >= previous.system,
              current.idle >= previous.idle, current.nice >= previous.nice else {
            return .unavailable(.counterReset)
        }
        // UInt32 deltas widened to UInt64 cannot overflow when summed.
        let user = UInt64(current.user - previous.user) + UInt64(current.nice - previous.nice)
        let system = UInt64(current.system - previous.system)
        let idle = UInt64(current.idle - previous.idle)
        let total = user + system + idle
        guard total > 0 else { return .unavailable(.noElapsedTicks) }

        func percent(_ ticks: UInt64) -> Double { min(max(Double(ticks) / Double(total) * 100, 0), 100) }
        return .available(CPUUsage(totalPercent: percent(user + system), userPercent: percent(user), systemPercent: percent(system)))
    }
}

// MARK: - Memory

/// Page counts from HOST_VM_INFO64 used by the memory formula.
struct VMPageCounters: Equatable {
    /// internal_page_count: anonymous (process-owned) pages, including purgeable ones.
    var anonymous: UInt32
    var purgeable: UInt32
    var wired: UInt32
    /// Physical pages holding compressed data.
    var compressed: UInt32
    /// File-backed cache pages.
    var external: UInt32
}

/// System-wide physical memory usage.
///
/// used = app + wired + compressed, where app = anonymous (internal) − purgeable. File cache (external + purgeable) is reclaimable
/// and excluded. This follows Activity Monitor's "Memory Used" breakdown, but Activity Monitor samples at its own time
/// and may round differently, so the numbers can differ slightly. Swap is not included.
struct MemoryUsage: Equatable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedFilesBytes: UInt64

    /// used / total, within 0...1 (guaranteed by `calculate`).
    var usedFraction: Double { Double(usedBytes) / Double(totalBytes) }

    static func calculate(totalBytes: UInt64, pageSize: UInt64, pages: VMPageCounters) -> SystemMetric<MemoryUsage> {
        guard totalBytes > 0, pageSize > 0, pages.anonymous >= pages.purgeable else {
            return .unavailable(.inconsistentValues)
        }
        func bytes(_ count: UInt64) -> UInt64? {
            let (result, overflow) = count.multipliedReportingOverflow(by: pageSize)
            return overflow ? nil : result
        }
        guard let app = bytes(UInt64(pages.anonymous - pages.purgeable)),
              let wired = bytes(UInt64(pages.wired)),
              let compressed = bytes(UInt64(pages.compressed)),
              let cachedFiles = bytes(UInt64(pages.external) + UInt64(pages.purgeable)) else {
            return .unavailable(.inconsistentValues)
        }
        let (partial, overflow1) = app.addingReportingOverflow(wired)
        let (used, overflow2) = partial.addingReportingOverflow(compressed)
        guard !overflow1, !overflow2, used <= totalBytes else { return .unavailable(.inconsistentValues) }
        return .available(MemoryUsage(totalBytes: totalBytes, usedBytes: used, appBytes: app, wiredBytes: wired,
                                      compressedBytes: compressed, cachedFilesBytes: cachedFiles))
    }
}
