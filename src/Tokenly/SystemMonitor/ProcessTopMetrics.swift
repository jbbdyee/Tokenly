import Foundation

/// Rankings include only processes whose usage the current macOS user may read.
///
/// Delivered as `SystemMetric<ProcessTopSnapshot>`: `.unavailable` means the process list itself could not be read
/// (nothing is known), while `.available` with `readableCount == 0` means the list was read but no process was readable.
struct ProcessTopSnapshot: Equatable {
    static let title = "조회 가능한 프로세스 TOP 5"
    static let accessNote = "macOS 권한으로 일부 시스템·다른 사용자 프로세스는 제외될 수 있습니다."

    let cpu: [ProcessCPUEntry]
    let memory: [ProcessMemoryEntry]
    let cpuHasBaseline: Bool
    let readableCount: Int
    let permissionDeniedCount: Int
}

struct ProcessCPUEntry: Equatable {
    let pid: Int32
    let name: String
    /// Percent of one logical core; a multithreaded process can exceed 100.
    let percent: Double
    /// Process start time (Mach ticks). With `pid` it identifies one process, so a reused PID is a new process
    /// (the CPU popover keys its app-icon cache on both).
    var startTicks: UInt64 = 0
}

struct ProcessMemoryEntry: Equatable {
    let pid: Int32
    let name: String
    let footprintBytes: UInt64
    /// Same role as `ProcessCPUEntry.startTicks` (icon cache identity).
    var startTicks: UInt64 = 0
}

/// Process display names. The kernel's `pbi_name` holds at most 31 characters, so longer names arrive cut
/// ("com.apple.Virtualization.Virtua"). Only for a name that fills the field is the executable's file name read
/// (`proc_pidpath`, same permission as the rest of the scan), and used only if it starts with the reported name,
/// so a different executable never renames a process.
enum ProcessNames {
    /// Characters `pbi_name` can hold (2 × MAXCOMLEN, minus the terminator).
    static let kernelLimit = 2 * Int(MAXCOMLEN) - 1

    static func full(reported: String, executableName: () -> String?) -> String {
        guard reported.utf8.count >= kernelLimit, let full = executableName(), full.count > reported.count,
              full.hasPrefix(reported) else { return reported }
        return full
    }
}

/// Raw values from one process. CPU times and start time use Mach absolute ticks.
struct ProcessRawEntry: Equatable {
    let pid: Int32
    let name: String
    let startTicks: UInt64
    let userTicks: UInt64
    let systemTicks: UInt64
    let footprintBytes: UInt64
}

struct ProcessRawSnapshot: Equatable {
    let uptimeNanoseconds: UInt64
    let entries: [ProcessRawEntry]
    let permissionDeniedCount: Int
}

struct ProcessTopCalculator {
    static func calculate(previous: ProcessRawSnapshot?, current: ProcessRawSnapshot,
                          timebaseNumer: UInt32, timebaseDenom: UInt32) -> ProcessTopSnapshot {
        let memory = current.entries.sorted {
            $0.footprintBytes == $1.footprintBytes ? $0.pid < $1.pid : $0.footprintBytes > $1.footprintBytes
        }.prefix(5).map { ProcessMemoryEntry(pid: $0.pid, name: $0.name, footprintBytes: $0.footprintBytes, startTicks: $0.startTicks) }

        var cpu: [ProcessCPUEntry] = []
        let validInterval = previous.map { current.uptimeNanoseconds > $0.uptimeNanoseconds } ?? false
        let canCalculate = validInterval && timebaseNumer > 0 && timebaseDenom > 0
        if let previous, canCalculate {
            var prior: [Int32: ProcessRawEntry] = [:]
            for entry in previous.entries { prior[entry.pid] = entry }
            let elapsed = Double(current.uptimeNanoseconds - previous.uptimeNanoseconds)
            for entry in current.entries {
                guard let old = prior[entry.pid], old.startTicks == entry.startTicks,
                      entry.userTicks >= old.userTicks, entry.systemTicks >= old.systemTicks else { continue }
                let delta = Double(entry.userTicks - old.userTicks) + Double(entry.systemTicks - old.systemTicks)
                let percent = delta * Double(timebaseNumer) / Double(timebaseDenom) / elapsed * 100
                guard percent.isFinite, percent >= 0 else { continue }
                cpu.append(ProcessCPUEntry(pid: entry.pid, name: entry.name, percent: percent, startTicks: entry.startTicks))
            }
            cpu.sort { $0.percent == $1.percent ? $0.pid < $1.pid : $0.percent > $1.percent }
            if cpu.count > 5 { cpu.removeLast(cpu.count - 5) }
        }
        return ProcessTopSnapshot(cpu: cpu, memory: Array(memory), cpuHasBaseline: canCalculate,
                                  readableCount: current.entries.count, permissionDeniedCount: current.permissionDeniedCount)
    }
}
