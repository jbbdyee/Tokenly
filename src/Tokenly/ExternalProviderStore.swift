import Foundation

enum ExternalLoadState {
    case idle
    case loading
    case success(ExternalUsageSnapshot)
    case failure(ExternalProviderError, previous: ExternalUsageSnapshot?)

    var snapshot: ExternalUsageSnapshot? {
        switch self {
        case .success(let value): value
        case .failure(_, let previous): previous
        default: nil
        }
    }
    var isLoading: Bool { if case .loading = self { true } else { false } }
}

@MainActor
final class ExternalProviderStore: ObservableObject {
    @Published private(set) var states: [ExternalProviderID: ExternalLoadState] = [:]
    /// Latest finished result per provider; unlike `states` it never shows `.loading`.
    @Published private(set) var settledStates: [ExternalProviderID: ExternalLoadState] = [:]
    /// Most recent valid quotas seen this session or kept in the provider's local feed file.
    @Published private(set) var lastValidQuotas: [ExternalProviderID: [QuotaMetric]] = [:]
    private let providers: [ExternalProviderID: any ExternalUsageProvider]
    private let displaySettings: ProviderDisplaySettings
    private var timer: Timer?

    init(displaySettings: ProviderDisplaySettings,
         providers: [ExternalProviderID: any ExternalUsageProvider] = [
             .claude: ClaudeSubscriptionProvider(),
             .antigravity: AGYStatusLineProvider(),
             .openAIAPI: OpenAIAPIUsageProvider()
         ]) {
        self.displaySettings = displaySettings
        self.providers = providers
    }

    func start() {
        guard timer == nil else { return }
        refreshSelected()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSelected() }
        }
    }

    func refreshSelected() {
        if displaySettings.showsAGY { _ = refresh(.antigravity) }
        if displaySettings.showsClaude { _ = refresh(.claude) }
        // OpenAI API account integration is paused; retain the provider implementation.
    }

    @discardableResult
    func refresh(_ id: ExternalProviderID) -> Task<Void, Never>? {
        guard id != .openAIAPI else { return nil }
        guard let provider = providers[id], states[id]?.isLoading != true else { return nil }
        let previous = states[id]?.snapshot
        states[id] = .loading
        return Task {
            let result: ExternalLoadState
            do { result = .success(try await provider.fetch()) }
            catch { result = .failure((error as? ExternalProviderError) ?? .connection, previous: previous) }
            states[id] = result
            settledStates[id] = result
            if case .success(let snapshot) = result, case .quotas(let quotas) = snapshot.metrics, !quotas.isEmpty {
                lastValidQuotas[id] = quotas
            } else if lastValidQuotas[id] == nil, let stored = provider.storedQuotaRecord(), !stored.isEmpty {
                lastValidQuotas[id] = stored
            }
        }
    }

    func state(for id: ExternalProviderID) -> ExternalLoadState { states[id] ?? .idle }
    func settledState(for id: ExternalProviderID) -> ExternalLoadState { settledStates[id] ?? .idle }
}
