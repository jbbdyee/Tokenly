import Foundation

enum UsageWindowKind: String, CaseIterable, Identifiable {
    case fiveHours
    case sevenDays

    var id: String { rawValue }
    var title: String { self == .fiveHours ? "5시간 한도" : "7일 한도" }
    var durationMinutes: Int { self == .fiveHours ? 300 : 10_080 }
    var shortTitle: String { self == .fiveHours ? "5h" : "7d" }
}

enum RemainingLevel: Equatable {
    case healthy
    case caution
    case low

    init(percent: Double) {
        if percent > 50 { self = .healthy }
        else if percent > 20 { self = .caution }
        else { self = .low }
    }
}

struct UsageWindow: Identifiable {
    let kind: UsageWindowKind
    let usedPercent: Double
    let resetsAt: Date?

    var id: UsageWindowKind { kind }
    var remainingPercent: Double { 100 - usedPercent }
    var remainingLevel: RemainingLevel { RemainingLevel(percent: remainingPercent) }
}

struct UsageSnapshot {
    let providerName: String
    let windows: [UsageWindow]
    let fetchedAt: Date
    /// ChatGPT rate-limit reset credits from the same official `account/rateLimits/read` response;
    /// nil when the backend did not include them. Read-only: Tokenly never redeems a credit.
    var resetCredits: RateLimitResetCredits? = nil

    func window(_ kind: UsageWindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    var menuBarSummary: String? {
        guard !windows.isEmpty else { return nil }
        return UsageWindowKind.allCases.map { kind in
            guard let window = window(kind) else { return "\(kind.shortTitle) —" }
            return "\(kind.shortTitle) \(Int(window.remainingPercent.rounded()))%"
        }.joined(separator: " · ")
    }
}

/// One reset credit as reported by `account/rateLimits/read` (`RateLimitResetCredit`).
struct RateLimitResetCredit: Equatable {
    enum Status: String { case available, redeeming, redeemed, unknown }
    /// nil = the credit does not expire.
    let expiresAt: Date?
    let status: Status
    let title: String?
}

/// `RateLimitResetCreditsSummary`: the backend's available count plus optional detail rows.
struct RateLimitResetCredits: Equatable {
    let availableCount: Int
    /// nil = only the count is known; [] = details were fetched and none are available.
    /// The backend may cap this list, so it can be shorter than `availableCount`.
    let credits: [RateLimitResetCredit]?

    /// Listed credits that are available and not yet expired, soonest expiry first (no expiry last).
    func usableCredits(now: Date = Date()) -> [RateLimitResetCredit] {
        (credits ?? [])
            .filter { $0.status == .available && ($0.expiresAt.map { $0 > now } ?? true) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// The backend count, minus any listed available credit whose expiry has already passed
    /// (the snapshot may be old after a failed or delayed refresh). Never negative.
    func usableCount(now: Date = Date()) -> Int {
        let expired = (credits ?? []).filter { $0.status == .available && ($0.expiresAt.map { $0 <= now } ?? false) }.count
        return max(0, availableCount - expired)
    }
}
