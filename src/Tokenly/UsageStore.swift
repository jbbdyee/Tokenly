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
    private var refreshTimer: Timer?

    init(provider: any UsageProvider) {
        self.provider = provider
    }

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
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
