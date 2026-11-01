import Foundation
#if TOKENLY_CLAUDE_DEV
import AppKit
#endif

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
    @Published private(set) var agySourceTimes: [ExternalUsageSource: Date] = [:]
    private let providers: [ExternalProviderID: any ExternalUsageProvider]
    private let displaySettings: ProviderDisplaySettings
    private let now: () -> Date
    let automaticTickInterval: TimeInterval
    private var timer: Timer?
    private var lastAutomaticAGYAttempt: Date?
#if TOKENLY_CLAUDE_DEV
    private var claudeWakeObserver: NSObjectProtocol?
    private var realOnceStarted = false
    private var realTwoStarted = false
    private var realTwoSecondScheduled = false
    private var mockStarted = false
#endif

    init(displaySettings: ProviderDisplaySettings,
         now: @escaping () -> Date = Date.init,
         automaticTickInterval: TimeInterval = 300,
         providers: [ExternalProviderID: any ExternalUsageProvider] = [
             .claude: ClaudeSubscriptionProvider(),
             .antigravity: AGYCombinedProvider(),
             .openAIAPI: OpenAIAPIUsageProvider()
         ]) {
        self.displaySettings = displaySettings
        self.now = now
        self.automaticTickInterval = automaticTickInterval == 60 ? 60 : 300
        self.providers = providers
    }

    func start() {
#if TOKENLY_CLAUDE_DEV
        if ClaudeDevelopmentConfiguration.isMockSixty {
            guard !realTwoStarted else { return }
            realTwoStarted = true
            _ = refresh(.claude)
            return // One completion may schedule one further attempt; never a repeating timer.
        }
        if ClaudeDevelopmentConfiguration.isMock {
            guard !mockStarted else { return }
            mockStarted = true
            refreshSelected()
            return // UI fixture never installs an automatic timer or wake observer.
        }
        if ClaudeDevelopmentConfiguration.isRealOnce {
            guard !realOnceStarted else { return }
            realOnceStarted = true
            refreshSelected()
            return // No repeating timer or wake observer for the one-shot account check.
        }
        if ClaudeDevelopmentConfiguration.isRealTwo || ClaudeDevelopmentConfiguration.isRealSixty {
            guard !realTwoStarted else { return }
            realTwoStarted = true
            _ = refresh(.claude)
            return // Completion may schedule one nonrepeating timer; no wake observer.
        }
#endif
        guard timer == nil else { return }
        refreshSelected()
#if TOKENLY_CLAUDE_DEV
        if claudeWakeObserver == nil, ClaudeDevelopmentConfiguration.isEnabled {
            claudeWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.displaySettings.showsClaude else { return }
                    _ = self.refresh(.claude) // The provider gate checks eligibility after wake.
                }
            }
        }
#endif
        timer = Timer.scheduledTimer(withTimeInterval: automaticTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSelected() }
        }
    }

    func refreshSelected(force: Bool = false) {
        if displaySettings.showsAGY,
           force || lastAutomaticAGYAttempt.map({ now().timeIntervalSince($0) >= 300 }) != false {
            if refresh(.antigravity) != nil, !force { lastAutomaticAGYAttempt = now() }
        }
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
            var settled = result
            if id == .antigravity, case .success(let incoming) = result,
               let old = previous, incoming.fetchedAt < old.fetchedAt {
                settled = .failure(.staleData, previous: old)
            }
            states[id] = settled
            settledStates[id] = settled
#if TOKENLY_CLAUDE_DEV
            if id == .claude, case .success(let snapshot) = settled {
                ClaudeDevelopmentConfiguration.recordStore(snapshot)
            }
            if id == .claude,
               ClaudeDevelopmentConfiguration.isRealTwo || ClaudeDevelopmentConfiguration.isRealSixty ||
                   ClaudeDevelopmentConfiguration.isMockSixty,
               !realTwoSecondScheduled, Self.shouldScheduleSecondClaudeAttempt(settled) {
                realTwoSecondScheduled = true
                let interval: TimeInterval = ClaudeDevelopmentConfiguration.isRealSixty ||
                    ClaudeDevelopmentConfiguration.isMockSixty ? 60 : 300
                timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.timer = nil
                        _ = self.refresh(.claude)
                    }
                }
            }
#endif
            if case .success(let snapshot) = result, id == .antigravity {
                for (source, date) in snapshot.sourceTimes {
                    if date > (agySourceTimes[source] ?? .distantPast) { agySourceTimes[source] = date }
                }
            }
            if case .success(let snapshot) = settled, case .quotas(let quotas) = snapshot.metrics, !quotas.isEmpty {
                lastValidQuotas[id] = quotas
            } else if lastValidQuotas[id] == nil, let stored = provider.storedQuotaRecord(), !stored.isEmpty {
                lastValidQuotas[id] = stored
            }
        }
    }

    func state(for id: ExternalProviderID) -> ExternalLoadState { states[id] ?? .idle }
    func settledState(for id: ExternalProviderID) -> ExternalLoadState { settledStates[id] ?? .idle }

#if TOKENLY_CLAUDE_DEV
    static func shouldScheduleSecondClaudeAttempt(_ state: ExternalLoadState) -> Bool {
        guard case .success(let snapshot) = state else { return false }
        return snapshot.sourceTimes[.directCLI] != nil
    }
#endif
}
