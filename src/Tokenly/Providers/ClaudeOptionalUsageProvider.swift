import Foundation

/// The SDK route is built explicitly by the development or product configuration.
enum ClaudeUsageRoute {
    case statusLineOnly
    case experimentalDirect(provider: ClaudeDirectUsageProvider, maxAge: TimeInterval)
}

struct ClaudeOptionalUsageProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .claude
    let statusLine: any ExternalUsageProvider
    let route: ClaudeUsageRoute
    let now: () -> Date
    private let state = ClaudeOptionalUsageState()
    private let gate: ClaudeDirectRefreshGate

    init(statusLine: any ExternalUsageProvider = ClaudeSubscriptionProvider(),
         route: ClaudeUsageRoute = .statusLineOnly,
         now: @escaping () -> Date = Date.init,
         gate: ClaudeDirectRefreshGate = ClaudeDirectRefreshGate()) {
        self.statusLine = statusLine
        self.route = route
        self.now = now
        self.gate = gate
    }

    func fetch() async throws -> ExternalUsageSnapshot {
        switch route {
        case .statusLineOnly:
            return try await statusLine.fetch()
        case .experimentalDirect(let direct, let maxAge):
            // Both sources are attempted independently. A direct failure never prevents the
            // existing statusLine path from supplying a fresh snapshot.
            var directResult: ClaudeDirectResult?
            if await gate.begin(at: now()) {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    directResult = try await direct.fetch()
#if TOKENLY_CLAUDE_DEV
                    ClaudeDevelopmentConfiguration.recordAttempt(result: directResult, error: nil,
                        elapsed: ProcessInfo.processInfo.systemUptime - started)
#endif
                    await gate.finish(error: nil, at: now())
                } catch is CancellationError {
#if TOKENLY_CLAUDE_DEV
                    ClaudeDevelopmentConfiguration.recordAttempt(result: nil, error: CancellationError(),
                        elapsed: ProcessInfo.processInfo.systemUptime - started)
#endif
                    await gate.finish(error: CancellationError(), at: now())
                    throw CancellationError()
                } catch {
#if TOKENLY_CLAUDE_DEV
                    ClaudeDevelopmentConfiguration.recordAttempt(result: nil, error: error,
                        elapsed: ProcessInfo.processInfo.systemUptime - started)
#endif
                    await gate.finish(error: error, at: now())
                }
            }
            let statusResult = try? await statusLine.fetch()
            return try await state.combine(direct: directResult, statusLine: statusResult,
                                           now: now(), directMaxAge: maxAge)
        }
    }

    func storedQuotaRecord() -> [QuotaMetric]? { statusLine.storedQuotaRecord() }

    var usesDirectSDK: Bool {
        if case .experimentalDirect = route { return true }
        return false
    }

    func nextAutomaticRefresh() async -> Date? { await gate.automaticNextEligibleAt }
}

private actor ClaudeOptionalUsageState {
    private var selection = ClaudeUsageSelection()
    private var lastStatusLine: ExternalUsageSnapshot?

    func combine(direct: ClaudeDirectResult?, statusLine: ExternalUsageSnapshot?,
                 now: Date, directMaxAge: TimeInterval) throws -> ExternalUsageSnapshot {
        if let direct { selection.accept(direct) }
        if let statusLine { lastStatusLine = statusLine }
        let chosen = selection.displayed(statusLine: lastStatusLine, now: now,
                                         directMaxAge: directMaxAge)
        let fresh = ClaudeWindow.allCases.compactMap { window -> ClaudeWindowValue? in
            guard let entry = chosen[window], !entry.stale else { return nil }
            return entry.value
        }
        guard !fresh.isEmpty else {
            throw chosen.isEmpty ? ExternalProviderError.noData : ExternalProviderError.claudeStaleData
        }
        // The oldest selected receipt prevents a partially updated snapshot from claiming that
        // every displayed window arrived at the newest source's time.
        let captured = fresh.map(\.receivedAt).min() ?? now
        var times: [ExternalUsageSource: Date] = [:]
        for value in fresh {
            times[value.source] = max(times[value.source] ?? .distantPast, value.receivedAt)
        }
        let source: ExternalUsageSource = fresh.allSatisfy { $0.source == .directCLI }
            ? .directCLI : .statusLine
        return ExternalUsageSnapshot(metrics: .quotas(fresh.map(\.quota)), fetchedAt: captured,
                                     source: source, sourceTimes: times)
    }
}
