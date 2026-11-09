import AppKit
import Combine
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    var menuBarText: String {
        guard let summary = snapshot?.menuBarSummary else {
            if isRefreshing { return "조회 중" }
            return errorMessage == nil ? "데이터 없음" : "조회 실패"
        }
        return errorMessage == nil ? summary : "이전 · \(summary)"
    }

    private let provider: any UsageProvider
    private let now: @MainActor () -> Date
    private let wakeNotifications: NotificationCenter
    private var refreshTimer: Timer?
    private var wakeSubscription: AnyCancellable?
    private var lastAttemptAt: Date?
    static let attentionRefreshInterval: TimeInterval = 60
    static let automaticRefreshInterval: TimeInterval = 60
    static let failedAutomaticRetryInterval: TimeInterval = 300

    init(provider: any UsageProvider, now: @escaping @MainActor () -> Date = Date.init,
         wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.provider = provider
        self.now = now
        self.wakeNotifications = wakeNotifications
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        wakeSubscription = wakeNotifications.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in _ = self?.refreshIfStale() }
            }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.automaticRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshOnTimer() }
        }
    }

    /// Popover opens, wakes and timer ticks may cluster. Conditional refresh needs both
    /// old successful data and at least a minute since any attempt; manual refresh bypasses this gate.
    @discardableResult
    func refreshIfStale() -> Task<Void, Never>? {
        guard !isRefreshing else { return nil }
        let current = now()
        if let lastSuccess = snapshot?.fetchedAt {
            let age = current.timeIntervalSince(lastSuccess)
            if age >= 0 && age < Self.attentionRefreshInterval { return nil }
        }
        if let lastAttemptAt {
            let elapsed = current.timeIntervalSince(lastAttemptAt)
            if elapsed >= 0 && elapsed < Self.attentionRefreshInterval { return nil }
        }
        return refresh()
    }

    @discardableResult
    func refreshOnTimer() -> Task<Void, Never>? {
        if errorMessage != nil, let lastAttemptAt {
            let elapsed = now().timeIntervalSince(lastAttemptAt)
            if elapsed >= 0 && elapsed < Self.failedAutomaticRetryInterval { return nil }
        }
        return refreshIfStale()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        lastAttemptAt = now()
        return Task {
            defer { isRefreshing = false }
            do {
                snapshot = try await provider.fetch()
                errorMessage = nil
            } catch {
                errorMessage = (error as? UsageProviderError)?.userMessage
                    ?? "Codex 사용량을 조회하지 못했습니다. 다시 시도해 주세요."
            }
        }
    }
}
