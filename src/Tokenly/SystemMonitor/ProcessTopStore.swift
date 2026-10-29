import Foundation

/// Popover-owned state. Calling `setVisible` from the future CPU/RAM popovers starts/stops all process work.
@MainActor
final class ProcessTopStore: ObservableObject {
    static let interval: TimeInterval = 3

    /// `nil` while closed or before the first scan finishes.
    @Published private(set) var snapshot: SystemMetric<ProcessTopSnapshot>?
    private let makeSampler: () -> any ProcessTopSampling
    private let scheduler: any SystemMonitorScheduling
    private var sampler: (any ProcessTopSampling)?
    private var timer: (any SystemMonitorCancellable)?
    /// Bumped on every open/close, so a scan from an earlier session can neither publish nor touch the current one.
    private var generation = 0
    private var visibleClients: Set<String> = []
    private(set) var pendingSample: Task<Void, Never>?

    init(makeSampler: @escaping () -> any ProcessTopSampling = { ProcessTopSampler() },
         scheduler: (any SystemMonitorScheduling)? = nil) {
        self.makeSampler = makeSampler
        self.scheduler = scheduler ?? LiveSystemMonitorScheduler()
    }

    /// Each popover uses a stable key such as "cpu" or "memory". Both may be open without duplicate scans.
    func setVisible(_ key: String, _ visible: Bool) {
        let wasActive = !visibleClients.isEmpty
        if visible { visibleClients.insert(key) } else { visibleClients.remove(key) }
        let isActive = !visibleClients.isEmpty
        guard wasActive != isActive else { return }
        generation += 1
        if isActive {
            sampler = makeSampler()
            requestSample()
            timer = scheduler.repeating(every: Self.interval) { [weak self] in self?.requestSample() }
        } else {
            timer?.cancel()
            timer = nil
            sampler = nil
            snapshot = nil
            // The scan stops at its next cancellation check; its generation can no longer publish, and clearing the
            // handle lets a reopen start a fresh scan at once instead of waiting for the old one.
            pendingSample?.cancel()
            pendingSample = nil
        }
    }

    private func requestSample() {
        guard pendingSample == nil, let sampler else { return }
        let requestGeneration = generation
        pendingSample = Task { [weak self] in
            // nil only when cancelled by a close.
            let value = try? await sampler.sample()
            guard let self, self.generation == requestGeneration else { return }
            self.pendingSample = nil
            if let value { self.snapshot = value }
        }
    }
}
