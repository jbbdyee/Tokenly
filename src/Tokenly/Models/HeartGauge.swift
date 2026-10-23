import Foundation

/// Providers shown as hearts, in display order.
enum HeartGaugeProvider: String, CaseIterable, Identifiable {
    case codex, claude, antigravity

    var id: String { rawValue }
    var shortTitle: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "AGY"
        }
    }
    var fullTitle: String { self == .antigravity ? "Google Antigravity" : shortTitle }
}

enum HeartGaugeReading: Equatable {
    /// Latest successful data.
    case fresh(Double)
    /// The latest read failed or expired; the value is the last valid one actually received.
    case stale(Double)

    var percent: Double {
        switch self {
        case .fresh(let value), .stale(let value): value
        }
    }

    var isStale: Bool { if case .stale = self { true } else { false } }
    var percentText: String { "\(Int(percent.rounded()))%" }

    func accessibilityText(for provider: HeartGaugeProvider) -> String {
        isStale ? "\(provider.fullTitle) 이전 데이터 \(percentText)" : "\(provider.fullTitle) 최저 잔여 \(percentText)"
    }
}

/// A nil reading means the heart is hidden: not connected, or no valid data was ever received.
enum HeartGauge {
    /// Lowest valid remaining percentage, clamped to 0...100; nil when nothing valid remains.
    static func representativePercent(_ values: [Double]) -> Double? {
        values.filter(\.isFinite).map { min(max($0, 0), 100) }.min()
    }

    static func codexReading(snapshot: UsageSnapshot?, hasError: Bool) -> HeartGaugeReading? {
        guard let snapshot,
              let percent = representativePercent(snapshot.windows.map(\.remainingPercent)) else { return nil }
        return hasError ? .stale(percent) : .fresh(percent)
    }

    /// `settled` never holds `.loading`, so a refresh in progress keeps the previous heart.
    /// AGY buckets are compared as reported; their minimum is not a Gemini-wide subscription total.
    static func externalReading(_ settled: ExternalLoadState, lastValidQuotas: [QuotaMetric]?) -> HeartGaugeReading? {
        switch settled {
        case .idle, .loading:
            return nil
        case .success(let snapshot):
            guard case .quotas(let quotas) = snapshot.metrics else { return nil }
            return representativePercent(quotas.map(\.remainingPercent)).map(HeartGaugeReading.fresh)
        case .failure(.setupRequired, _):
            // No feed file means the service is not connected, whatever was seen before.
            return nil
        case .failure:
            // Stale status-line feeds stay visible as grey while a valid value was ever received.
            return lastValidQuotas.flatMap { representativePercent($0.map(\.remainingPercent)) }
                .map(HeartGaugeReading.stale)
        }
    }

    /// Hearts follow the popover visibility toggles so hidden services never show a heart.
    @MainActor
    static func visibleProviders(_ settings: ProviderDisplaySettings) -> [HeartGaugeProvider] {
        HeartGaugeProvider.allCases.filter { provider in
            switch provider {
            case .codex: settings.showsCodex
            case .claude: settings.showsClaude
            case .antigravity: settings.showsAGY
            }
        }
    }

    @MainActor
    static func readings(store: UsageStore, externalStore: ExternalProviderStore,
                         settings: ProviderDisplaySettings) -> [(provider: HeartGaugeProvider, reading: HeartGaugeReading)] {
        visibleProviders(settings).compactMap { provider in
            let reading: HeartGaugeReading?
            switch provider {
            case .codex:
                reading = codexReading(snapshot: store.snapshot, hasError: store.errorMessage != nil)
            case .claude:
                reading = externalReading(externalStore.settledState(for: .claude),
                                          lastValidQuotas: externalStore.lastValidQuotas[.claude])
            case .antigravity:
                reading = externalReading(externalStore.settledState(for: .antigravity),
                                          lastValidQuotas: externalStore.lastValidQuotas[.antigravity])
            }
            return reading.map { (provider, $0) }
        }
    }
}
