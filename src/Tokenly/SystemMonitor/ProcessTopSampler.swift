import Darwin
import Foundation

protocol ProcessTopSampling {
    /// Throws only `CancellationError`. A failed process enumeration is `.unavailable(.readFailed(errno))`.
    func sample() async throws -> SystemMetric<ProcessTopSnapshot>
}

/// Holds one CPU baseline. Construct a new instance when a popover reopens so closed time is never averaged in.
actor ProcessTopSampler: ProcessTopSampling {
    private var previous: ProcessRawSnapshot?
    private let read: @Sendable () throws -> SystemMetric<ProcessRawSnapshot>
    private let timebaseNumer: UInt32
    private let timebaseDenom: UInt32

    init(read: @escaping @Sendable () throws -> SystemMetric<ProcessRawSnapshot> = { try LiveProcessReader.read() },
         timebase: mach_timebase_info_data_t? = nil) {
        self.read = read
        var actual = mach_timebase_info_data_t()
        if let timebase { actual = timebase } else { _ = mach_timebase_info(&actual) }
        timebaseNumer = actual.numer
        timebaseDenom = actual.denom
    }

    func sample() throws -> SystemMetric<ProcessTopSnapshot> {
        try Task.checkCancellation()
        let current: ProcessRawSnapshot
        switch try read() {
        case .available(let value):
            current = value
        case .unavailable(let reason):
            // Keep the baseline: the next successful read measures CPU across the failed interval.
            return .unavailable(reason)
        }
        // A scan cancelled after reading is discarded whole, so a closed popover never leaves a baseline behind.
        try Task.checkCancellation()
        let result = ProcessTopCalculator.calculate(previous: previous, current: current,
                                                    timebaseNumer: timebaseNumer, timebaseDenom: timebaseDenom)
        previous = current
        return .available(result)
    }
}

enum LiveProcessReader {
    /// `proc_listpids(PROC_ALL_PIDS, 0, buffer, size)`; replaceable so tests can inject an enumeration failure.
    typealias ListPIDs = (UnsafeMutableRawPointer?, Int32) -> Int32

    /// Checks for cancellation every this many PIDs, so a closed popover stops a scan within a fraction of a millisecond.
    static let cancellationStride = 64

    static func read(listPIDs: ListPIDs = { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0, $1) }) throws -> SystemMetric<ProcessRawSnapshot> {
        // The calling process is always listed, so a non-positive size means the call failed, not "no processes".
        errno = 0
        let bytesNeeded = listPIDs(nil, 0)
        guard bytesNeeded > 0 else { return .unavailable(.readFailed(errno)) }
        // Allow headroom for processes starting between the size query and the actual list call.
        var pids = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.stride + 1024)
        errno = 0
        let bytesRead = pids.withUnsafeMutableBytes { buffer in listPIDs(buffer.baseAddress, Int32(buffer.count)) }
        guard bytesRead > 0 else { return .unavailable(.readFailed(errno)) }

        var entries: [ProcessRawEntry] = []
        var denied = 0
        for (index, pid) in pids.prefix(Int(bytesRead) / MemoryLayout<pid_t>.stride).enumerated() where pid > 0 {
            if index % cancellationStride == 0 { try Task.checkCancellation() }
            var usage = rusage_info_v2()
            errno = 0
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                // libproc's C signature is rusage_info_t * (void **), but the API writes the
                // entire struct into the supplied storage; point it at `usage`, not at a pointer variable.
                let storage = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, Int32(RUSAGE_INFO_V2), storage)
            }
            guard result == 0 else {
                if errno == EPERM || errno == EACCES { denied += 1 }
                continue
            }
            var bsd = proc_bsdinfo()
            let bsdSize = withUnsafeMutablePointer(to: &bsd) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
            }
            let name: String
            if bsdSize == MemoryLayout<proc_bsdinfo>.size {
                let reported = withUnsafePointer(to: &bsd.pbi_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
                }
                name = reported.isEmpty ? "PID \(pid)" : ProcessNames.full(reported: reported) { Self.executableName(pid) }
            } else {
                name = "PID \(pid)"
            }
            entries.append(ProcessRawEntry(pid: pid, name: name, startTicks: usage.ri_proc_start_abstime,
                                           userTicks: usage.ri_user_time, systemTicks: usage.ri_system_time,
                                           footprintBytes: usage.ri_phys_footprint))
        }
        return .available(ProcessRawSnapshot(uptimeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                                             entries: entries, permissionDeniedCount: denied))
    }

    /// Last path component of the process's executable (`proc_pidpath`), or nil when it cannot be read.
    static func executableName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = (String(cString: buffer) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
