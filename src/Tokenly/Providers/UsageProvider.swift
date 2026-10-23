import Foundation

protocol UsageProvider {
    var name: String { get }
    func fetch() async throws -> UsageSnapshot
}

enum UsageProviderError: Error, Equatable {
    case cliUnavailable
    case connection
    case timeout
    case requestFailed
    case invalidResponse

    var userMessage: String {
        switch self {
        case .cliUnavailable: return "Codex CLI를 찾거나 실행할 수 없습니다. 설치 상태를 확인해 주세요."
        case .connection: return "Codex app-server에 연결하지 못했습니다. 실행 환경을 확인해 주세요."
        case .timeout: return "Codex 사용량 조회 시간이 초과됐습니다. 잠시 후 다시 시도해 주세요."
        case .requestFailed: return "Codex 사용량 요청에 실패했습니다. 로그인 상태와 실행 환경을 확인해 주세요."
        case .invalidResponse: return "Codex 사용량 응답을 해석하지 못했습니다."
        }
    }
}
