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

@MainActor
final class SystemMonitorStore: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(SystemSnapshot)
        case failed(Error)
    }

    @Published private(set) var state: State = .idle
    private let sampler: any SystemSampler

    init(sampler: any SystemSampler) {
        self.sampler = sampler
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        if case .loading = state { return nil }
        state = .loading
        return Task {
            do {
                state = .ready(try await sampler.sample())
            } catch {
                state = .failed(error)
            }
        }
    }
}
