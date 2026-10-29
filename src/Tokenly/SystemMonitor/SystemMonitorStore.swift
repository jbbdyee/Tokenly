import Foundation

/// A point-in-time system reading. Each metric carries its own availability so one failed read does not hide the others.
struct SystemSnapshot {
    let sampledAt: Date
    let cpu: SystemMetric<CPUUsage>
    let memory: SystemMetric<MemoryUsage>
}

/// Supplies a complete reading without depending on AI usage providers.
protocol SystemSampler {
    func sample() async throws -> SystemSnapshot
}

/// Samples only the metrics that are enabled, keeps the latest values and the last 60 seconds of CPU and RAM usage.
///
/// - CPU and RAM share one 1-second timer and one `SystemSampler`. The job runs while either metric is enabled and
///   stops when both are disabled. Each restart creates a new sampler, so the first CPU value after a pause is
///   `awaitingBaseline` instead of an average over the paused gap.
/// - Battery is event driven: power-source change notifications (plug/unplug, charge level, charging state) plus a
///   60-second fallback poll in case a notification is missed. Cycle count and capacities change rarely, so they are
///   read together with the live state rather than on their own timer.
/// - Disk capacity is read once on enable and then every 60 seconds, off the main actor (one read is ~4 ms).
///   While Disk is on, the system drive's cumulative read/write bytes are also read every second (off the main actor,
///   ~1 ms) and turned into speeds by `DiskActivityRateTracker` (6-4e); the same one job serves the popover.
/// - GPU (experimental) is read about ten times a second at randomized offsets inside ~100 ms slots (one-shot timers,
///   ~40 µs per read on the main actor) and published once per one-second window as the mean of the valid reads.
/// - A sample is never started while the previous one is still running, and results that arrive after the metric
///   was disabled or restarted are dropped.
@MainActor
final class SystemMonitorStore: ObservableObject {
    enum Metric: CaseIterable {
        case cpu, memory, battery, disk, gpu
    }

    static let cpuMemoryInterval: TimeInterval = 1
    static let batteryFallbackInterval: TimeInterval = 60
    /// Capacity changes over minutes, so a minute keeps wakeups rare while large downloads still show up promptly.
    static let diskInterval: TimeInterval = 60
    static let diskActivityInterval: TimeInterval = 1

    @Published private(set) var enabledMetrics: Set<Metric> = []
    /// `nil` means not measured (disabled, or no sample yet since enabling); never a stand-in for 0.
    @Published private(set) var cpu: SystemMetric<CPUUsage>?
    @Published private(set) var memory: SystemMetric<MemoryUsage>?
    /// Read with each RAM sample while RAM is on (6-4c); `nil` when RAM is off or not yet sampled.
    @Published private(set) var memoryPressure: SystemMetric<MemoryPressure>?
    @Published private(set) var batteryPower: SystemMetric<BatteryPowerState>?
    @Published private(set) var batteryHealth: SystemMetric<BatteryStatus>?
    /// When `batteryPower`/`batteryHealth` were last read (wall clock), so the popover can tell an old temperature
    /// (e.g. right after wake, before the next read) from a failed one.
    @Published private(set) var batteryReadDate: Date?
    @Published private(set) var disk: SystemMetric<DiskUsage>?
    /// Read/write speed of the drive behind `/` over the last second; `awaitingBaseline` until two reads exist.
    @Published private(set) var diskActivity: SystemMetric<DiskActivityRate>?
    /// Volume name, file system, internal/external and SSD, as far as confirmed (6-4e). Kept while Disk is on.
    @Published private(set) var diskDevice: DiskDeviceInfo?
    /// Read and write speed in MB/s. Failed seconds are gaps; a baseline or re-baseline adds no point.
    @Published private(set) var diskReadHistory = SystemMetricHistory()
    @Published private(set) var diskWriteHistory = SystemMetricHistory()
    /// Experimental estimated GPU utilization in percent (see `GPUUtilizationWindow.result`). Updated once per second.
    @Published private(set) var gpu: SystemMetric<Double>?
    /// Total CPU usage in percent.
    @Published private(set) var cpuHistory = SystemMetricHistory()
    /// Used memory in percent of physical memory.
    @Published private(set) var memoryHistory = SystemMetricHistory()
    /// One point per completed GPU window; unavailable windows are gaps.
    @Published private(set) var gpuHistory = SystemMetricHistory()

    private let makeSampler: @MainActor () -> any SystemSampler
    private let readMemoryPressure: @MainActor () -> SystemMetric<MemoryPressure>
    private let battery: any BatterySampling
    private let diskSampler: any DiskSampling
    private let diskActivitySampler: any DiskActivitySampling
    private let gpuSampler: any GPUSampling
    /// Monotonic seconds that keep counting during sleep, so GPU windows can detect gaps.
    private let uptime: @MainActor () -> TimeInterval
    private let scheduler: any SystemMonitorScheduling
    /// Time stamp for a failed sample, which has no `sampledAt` of its own.
    private let now: @MainActor () -> Date
    private var sampler: (any SystemSampler)?
    private var cpuMemoryJob: (any SystemMonitorCancellable)?
    private var batteryJobs: [any SystemMonitorCancellable] = []
    private var samplingTask: Task<Void, Never>?
    /// Bumped whenever the CPU/RAM job starts or stops, so a sample that was in flight across that change is dropped.
    private var generation = 0
    private var diskJob: (any SystemMonitorCancellable)?
    private var diskTask: Task<Void, Never>?
    /// Same role as `generation`, for the disk job.
    private var diskGeneration = 0
    private var diskActivityJob: (any SystemMonitorCancellable)?
    private var diskActivityTask: Task<Void, Never>?
    private var diskActivityTracker = DiskActivityRateTracker()
    private var gpuSchedule: GPUSampleSchedule
    private var gpuWindow: GPUUtilizationWindow?
    private var gpuJob: (any SystemMonitorCancellable)?
    private var gpuGeneration = 0

    init(makeSampler: @escaping @MainActor () -> any SystemSampler = { MachSystemSampler() },
         battery: any BatterySampling = BatterySampler(),
         disk: any DiskSampling = DiskSampler(),
         diskActivity: (any DiskActivitySampling)? = nil,
         gpu: (any GPUSampling)? = nil,
         gpuScheduleSeed: UInt64 = .random(in: .min ... .max),
         scheduler: (any SystemMonitorScheduling)? = nil,
         now: @escaping @MainActor () -> Date = Date.init,
         uptime: @escaping @MainActor () -> TimeInterval = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 },
         memoryPressure: @escaping @MainActor () -> SystemMetric<MemoryPressure> = MemoryPressure.readSystem) {
        self.makeSampler = makeSampler
        self.readMemoryPressure = memoryPressure
        self.battery = battery
        self.diskSampler = disk
        self.diskActivitySampler = diskActivity ?? DiskActivitySampler()
        // Created here, on the main actor, because GPUSampler is main-actor isolated.
        self.gpuSampler = gpu ?? GPUSampler()
        self.gpuSchedule = GPUSampleSchedule(seed: gpuScheduleSeed)
        self.uptime = uptime
        self.scheduler = scheduler ?? LiveSystemMonitorScheduler()
        self.now = now
    }

    /// The CPU/RAM sample currently running, if any. Exposed for tests.
    var pendingSample: Task<Void, Never>? { samplingTask }
    /// The disk read currently running, if any. Exposed for tests.
    var pendingDiskSample: Task<Void, Never>? { diskTask }
    /// The disk activity read currently running, if any. Exposed for tests.
    var pendingDiskActivitySample: Task<Void, Never>? { diskActivityTask }

    /// Enabling an already enabled metric (or disabling a disabled one) does nothing.
    func setEnabled(_ metric: Metric, _ enabled: Bool) {
        guard enabledMetrics.contains(metric) != enabled else { return }
        if enabled {
            enabledMetrics.insert(metric)
        } else {
            enabledMetrics.remove(metric)
            clear(metric)
        }
        switch metric {
        case .cpu, .memory: updateCPUMemoryJob()
        case .battery: updateBatteryJobs()
        case .disk: updateDiskJob()
        case .gpu: updateGPUJob()
        }
    }

    // MARK: CPU and RAM

    private func updateCPUMemoryJob() {
        let needed = enabledMetrics.contains(.cpu) || enabledMetrics.contains(.memory)
        if needed, cpuMemoryJob == nil {
            generation += 1
            sampler = makeSampler()
            cpuMemoryJob = scheduler.repeating(every: Self.cpuMemoryInterval) { [weak self] in self?.sampleCPUMemory() }
            sampleCPUMemory()
        } else if !needed, let job = cpuMemoryJob {
            job.cancel()
            cpuMemoryJob = nil
            sampler = nil
            samplingTask?.cancel()
            samplingTask = nil
            generation += 1
        }
    }

    private func sampleCPUMemory() {
        guard samplingTask == nil, let sampler else { return }
        let generation = generation
        samplingTask = Task { [weak self] in
            let snapshot = try? await sampler.sample()
            guard let self, self.generation == generation else { return }
            self.samplingTask = nil
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: SystemSnapshot?) {
        // A thrown sample is a read failure for both metrics; the next tick may recover.
        let failed = SystemMetricUnavailableReason.readFailed(KERN_FAILURE)
        let date = snapshot?.sampledAt ?? now()
        if enabledMetrics.contains(.cpu) {
            let value = snapshot?.cpu ?? .unavailable(failed)
            cpu = value
            // The baseline sample means "not measured yet", not a gap in the graph.
            if value != .unavailable(.awaitingBaseline) { cpuHistory.append(value.value?.totalPercent, at: date) }
        }
        if enabledMetrics.contains(.memory) {
            let value = snapshot?.memory ?? .unavailable(failed)
            memory = value
            memoryHistory.append(value.value.map { $0.usedFraction * 100 }, at: date)
            // Separate from usage: a failed pressure read never touches `memory`, and vice versa.
            memoryPressure = readMemoryPressure()
        }
    }

    // MARK: Battery

    private func updateBatteryJobs() {
        if enabledMetrics.contains(.battery), batteryJobs.isEmpty {
            batteryJobs = [
                scheduler.onPowerSourceChange { [weak self] in self?.refreshBattery() },
                scheduler.repeating(every: Self.batteryFallbackInterval) { [weak self] in self?.refreshBattery() },
            ]
            refreshBattery()
        } else if !enabledMetrics.contains(.battery) {
            batteryJobs.forEach { $0.cancel() }
            batteryJobs = []
        }
    }

    private func refreshBattery() {
        guard enabledMetrics.contains(.battery) else { return }
        batteryPower = battery.samplePowerState()
        batteryHealth = battery.sample()
        batteryReadDate = now()
    }

    // MARK: Disk

    private func updateDiskJob() {
        if enabledMetrics.contains(.disk), diskJob == nil {
            diskGeneration += 1
            diskJob = scheduler.repeating(every: Self.diskInterval) { [weak self] in self?.sampleDisk() }
            diskActivityTracker.reset()
            diskActivityJob = scheduler.repeating(every: Self.diskActivityInterval) { [weak self] in self?.sampleDiskActivity() }
            sampleDisk()
            sampleDiskActivity()
        } else if !enabledMetrics.contains(.disk), let job = diskJob {
            job.cancel()
            diskJob = nil
            diskTask?.cancel()
            diskTask = nil
            diskActivityJob?.cancel()
            diskActivityJob = nil
            diskActivityTask?.cancel()
            diskActivityTask = nil
            diskActivityTracker.reset()
            diskGeneration += 1
        }
    }

    /// Skipped while the previous read is still running; the longer interval then re-baselines in the tracker.
    private func sampleDiskActivity() {
        guard diskActivityTask == nil else { return }
        let sampler = diskActivitySampler
        let generation = diskGeneration
        diskActivityTask = Task { [weak self] in
            let sample = await sampler.sample()
            guard let self, self.diskGeneration == generation else { return }
            self.diskActivityTask = nil
            self.apply(sample)
        }
    }

    private func apply(_ sample: DiskActivitySample) {
        if diskDevice != sample.device { diskDevice = sample.device }
        let value = diskActivityTracker.update(sample.read)
        diskActivity = value
        let date = now()
        switch value {
        case .available(let rate):
            diskReadHistory.append(rate.readMBps, at: date)
            diskWriteHistory.append(rate.writeMBps, at: date)
        case .unavailable(.awaitingBaseline):
            // Nothing measured yet (first read, sleep, other drive): no point; the time gap already splits the line.
            break
        case .unavailable:
            diskReadHistory.append(nil, at: date)
            diskWriteHistory.append(nil, at: date)
        }
    }

    private func sampleDisk() {
        guard diskTask == nil else { return }
        let sampler = diskSampler
        let generation = diskGeneration
        diskTask = Task { [weak self] in
            let value = await sampler.sample()
            guard let self, self.diskGeneration == generation else { return }
            self.diskTask = nil
            self.disk = value
        }
    }

    // MARK: GPU (experimental)

    private func updateGPUJob() {
        if enabledMetrics.contains(.gpu), gpuJob == nil {
            gpuGeneration += 1
            let start = uptime()
            gpuWindow = GPUUtilizationWindow(start: start)
            scheduleGPURead(at: gpuSchedule.readTime(windowStart: start, slot: 0), from: start)
        } else if !enabledMetrics.contains(.gpu) {
            gpuJob?.cancel()
            gpuJob = nil
            gpuWindow = nil
            gpuGeneration += 1
            gpuSampler.reset()
        }
    }

    private func scheduleGPURead(at target: TimeInterval, from now: TimeInterval) {
        let generation = gpuGeneration
        gpuJob = scheduler.once(after: target - now) { [weak self] in
            guard let self, self.gpuGeneration == generation else { return }
            self.readGPU()
        }
    }

    private func readGPU() {
        guard enabledMetrics.contains(.gpu), var window = gpuWindow else { return }
        // The read's start time: a read beginning exactly at the window's end belongs to the next window.
        let time = uptime()
        if time >= window.end {
            if window.isFresh(closingAt: time) {
                publishGPU(window)
                window = GPUUtilizationWindow(start: window.end)
            } else {
                // A stall or sleep left the window describing an older second: drop it unpublished, mark the current
                // value unavailable instead of keeping a stale one, and start a fresh window (and phase) now.
                window = GPUUtilizationWindow(start: time)
                gpu = .unavailable(.insufficientSamples)
            }
        }
        window.add(GPUUtilizationWindow.Sample(time: time, reading: gpuSampler.read()))
        gpuWindow = window

        // Next slot from the window's own grid, so a late timer never shifts later reads.
        let slot = min(Int((time - window.start) / GPUSampleSchedule.slotLength), GPUSampleSchedule.slots - 1)
        let target = slot + 1 < GPUSampleSchedule.slots
            ? gpuSchedule.readTime(windowStart: window.start, slot: slot + 1)
            : gpuSchedule.readTime(windowStart: window.end, slot: 0)
        scheduleGPURead(at: target, from: time)
    }

    private func publishGPU(_ window: GPUUtilizationWindow) {
        let result = window.result
        gpu = result
        gpuHistory.append(result.value, at: now())
    }

    private func clear(_ metric: Metric) {
        switch metric {
        case .cpu:
            cpu = nil
            cpuHistory.removeAll()
        case .memory:
            memory = nil
            memoryPressure = nil
            memoryHistory.removeAll()
        case .battery:
            batteryPower = nil
            batteryHealth = nil
            batteryReadDate = nil
        case .disk:
            disk = nil
            diskActivity = nil
            diskDevice = nil
            diskReadHistory.removeAll()
            diskWriteHistory.removeAll()
        case .gpu:
            gpu = nil
            gpuHistory.removeAll()
        }
    }
}
