import Foundation

/// One service in the numeric menu bar style: 5-hour remaining on top, 7-day remaining below.
/// Which services appear, and whether they are stale, follows HeartGauge exactly.
struct NumericGaugeItem: Equatable {
    let provider: HeartGaugeProvider
    /// 5-hour remaining (or, for AGY, the lowest bucket: it has no 5h/7d windows).
    let primary: Double?
    /// 7-day remaining; nil when the service has no such window.
    let secondary: Double?
    let hasSecondarySlot: Bool
    let stale: Bool

    var name: String { provider.shortTitle }

    static func text(_ value: Double?) -> String {
        value.map { "\(Int(min(max($0, 0), 100).rounded()))" } ?? "—"
    }

    var accessibilityText: String {
        let state = stale ? " 이전 데이터" : ""
        guard hasSecondarySlot else { return "\(provider.fullTitle)\(state) 최저 잔여 \(Self.text(primary))%" }
        return "\(provider.fullTitle)\(state) 5시간 \(Self.text(primary))%, 7일 \(Self.text(secondary))%"
    }
}

enum NumericGauge {
    /// Claude's parser names its windows with these labels.
    static let claudeFiveHour = "5시간 한도"
    static let claudeSevenDay = "7일 한도"

    static func codexItem(snapshot: UsageSnapshot?, hasError: Bool) -> NumericGaugeItem? {
        guard HeartGauge.codexReading(snapshot: snapshot, hasError: hasError) != nil, let snapshot else { return nil }
        return NumericGaugeItem(provider: .codex,
                                primary: snapshot.window(.fiveHours)?.remainingPercent,
                                secondary: snapshot.window(.sevenDays)?.remainingPercent,
                                hasSecondarySlot: true, stale: hasError)
    }

    /// Same visibility and stale rules as `HeartGauge.externalReading`; only the values shown differ.
    static func externalItem(_ provider: HeartGaugeProvider, settled: ExternalLoadState,
                             lastValidQuotas: [QuotaMetric]?) -> NumericGaugeItem? {
        guard let reading = HeartGauge.externalReading(settled, lastValidQuotas: lastValidQuotas) else { return nil }
        let quotas: [QuotaMetric]
        if case .success(let snapshot) = settled, case .quotas(let current) = snapshot.metrics {
            quotas = current
        } else {
            quotas = lastValidQuotas ?? []
        }
        switch provider {
        case .claude:
            return NumericGaugeItem(provider: .claude,
                                    primary: quotas.first { $0.name == claudeFiveHour }?.remainingPercent,
                                    secondary: quotas.first { $0.name == claudeSevenDay }?.remainingPercent,
                                    hasSecondarySlot: true, stale: reading.isStale)
        default:
            // AGY buckets are not 5h/7d windows: show only their lowest remaining, as the hearts do.
            return NumericGaugeItem(provider: provider, primary: reading.percent, secondary: nil,
                                    hasSecondarySlot: false, stale: reading.isStale)
        }
    }

    @MainActor
    static func items(store: UsageStore, externalStore: ExternalProviderStore,
                      settings: ProviderDisplaySettings) -> [NumericGaugeItem] {
        HeartGauge.visibleProviders(settings).compactMap { provider in
            switch provider {
            case .codex:
                codexItem(snapshot: store.snapshot, hasError: store.errorMessage != nil)
            case .claude, .antigravity:
                externalItem(provider, settled: externalStore.settledState(for: provider == .claude ? .claude : .antigravity),
                             lastValidQuotas: externalStore.lastValidQuotas[provider == .claude ? .claude : .antigravity])
            }
        }
    }
}
