import Foundation

enum ExternalProviderID: String, CaseIterable, Identifiable {
    case claude
    case antigravity
    case openAIAPI

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .antigravity: "Google Antigravity"
        case .openAIAPI: "OpenAI API"
        }
    }
}

struct QuotaMetric: Equatable, Identifiable {
    let name: String
    let remainingPercent: Double
    let resetsAt: Date?
    var id: String { name }
}

enum AGYQuotaLabel {
    // Add a friendly name only when AGY officially defines the bucket's meaning.
    private static let verifiedNames: [String: String] = [:]

    static func displayName(for identifier: String) -> String {
        verifiedNames[identifier] ?? identifier
    }
}

enum AGYQuotaSummary {
    static func text(for quotas: [QuotaMetric]) -> String {
        guard !quotas.isEmpty else { return "쿼터 데이터 없음" }
        let values = quotas.map { Int($0.remainingPercent.rounded()) }
        if values.count == 1 {
            return "\(AGYQuotaLabel.displayName(for: quotas[0].name)) \(values[0])%"
        }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        return "\(values.count)개 버킷 · \(low)–\(high)%"
    }

    static func hasExhaustedBucket(_ quotas: [QuotaMetric]) -> Bool {
        quotas.contains { $0.remainingPercent <= 0 }
    }
}

struct APITotals: Equatable {
    let inputTokens: Int64
    let outputTokens: Int64
    let costUSD: Double
}

enum ExternalMetrics: Equatable {
    case quotas([QuotaMetric])
    case api(day: APITotals, month: APITotals)
}

struct ExternalUsageSnapshot: Equatable {
    let metrics: ExternalMetrics
    let fetchedAt: Date
}

enum ExternalProviderError: Error, Equatable {
    case setupRequired
    case authenticationRequired
    case permissionDenied
    case unsupported
    case noData
    case staleData
    case claudeStaleData
    case timeout
    case connection
    case invalidResponse

    var message: String {
        switch self {
        case .setupRequired: "연결 설정이 필요합니다. AI 서비스 설정을 확인하세요."
        case .authenticationRequired: "관리자 인증정보가 없습니다. AI 서비스 설정에서 등록하세요."
        case .permissionDenied: "조회 권한이 없습니다. 조직 관리자 키와 권한을 확인하세요."
        case .unsupported: "공식 자동 조회 방식이 확인되지 않아 연결할 수 없습니다."
        case .noData: "현재 제공된 사용량 데이터가 없습니다."
        case .staleData: "15분 안에 수신한 AGY 쿼터가 없습니다. CLI가 종료됐거나 새 상태줄 이벤트가 없을 수 있습니다."
        case .claudeStaleData: "15분 안에 수신한 Claude 구독 한도가 없습니다. Claude Code 상태줄 이벤트를 확인하세요."
        case .timeout: "조회 시간이 초과됐습니다. 잠시 후 다시 시도하세요."
        case .connection: "서비스에 연결하지 못했습니다. 잠시 후 다시 시도하세요."
        case .invalidResponse: "사용량 응답을 해석하지 못했습니다."
        }
    }
}

protocol ExternalUsageProvider {
    var id: ExternalProviderID { get }
    func fetch() async throws -> ExternalUsageSnapshot
    /// Valid quotas last written to local storage, ignoring age; nil when nothing valid is stored.
    func storedQuotaRecord() -> [QuotaMetric]?
}

extension ExternalUsageProvider {
    func storedQuotaRecord() -> [QuotaMetric]? { nil }
}
