import Darwin
import Foundation

/// Reads CPU and memory from Mach host statistics. It keeps the CPU baseline between calls, so use one instance per store.
///
/// Both reads fill fixed-size structs on the stack, so sampling allocates no kernel memory that would need vm_deallocate.
actor MachSystemSampler: SystemSampler {
    private let host: mach_port_t
    private let totalMemoryBytes: UInt64
    private var cpuTracker = CPUUsageTracker()

    init(totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        // mach_host_self() adds a send-right reference on every call; take it once and release it in deinit.
        host = mach_host_self()
        self.totalMemoryBytes = totalMemoryBytes
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func sample() -> SystemSnapshot {
        let cpu: SystemMetric<CPUUsage>
        switch readCPUTicks() {
        case .available(let ticks): cpu = cpuTracker.update(with: ticks)
        case .unavailable(let reason): cpu = .unavailable(reason)
        }
        return SystemSnapshot(sampledAt: Date(), cpu: cpu, memory: readMemory())
    }

    private func readCPUTicks() -> SystemMetric<CPUTickCounters> {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .unavailable(.readFailed(result)) }
        // cpu_ticks is indexed by CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        let ticks = info.cpu_ticks
        return .available(CPUTickCounters(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3))
    }

    private func readMemory() -> SystemMetric<MemoryUsage> {
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else { return .unavailable(.readFailed(pageResult)) }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .unavailable(.readFailed(result)) }
        let pages = VMPageCounters(anonymous: stats.internal_page_count, purgeable: stats.purgeable_count,
                                   wired: stats.wire_count, compressed: stats.compressor_page_count,
                                   external: stats.external_page_count)
        return MemoryUsage.calculate(totalBytes: totalMemoryBytes, pageSize: UInt64(pageSize), pages: pages)
    }
}
