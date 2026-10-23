import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case off
    case on
    case requiresApproval
    case unavailable
}

protocol LoginItemControlling {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

struct MainAppLoginItemController: LoginItemControlling {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .notRegistered: .off
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var state: LoginItemState = .off
    @Published private(set) var errorMessage: String?

    let isInstalled: Bool
    private let controller: LoginItemControlling

    init(controller: LoginItemControlling = MainAppLoginItemController(),
         bundleURL: URL = Bundle.main.bundleURL) {
        self.controller = controller
        isInstalled = Self.isStableInstallLocation(bundleURL)
        refresh()
    }

    var isEnabled: Bool { state == .on || state == .requiresApproval }

    var statusMessage: String {
        if !isInstalled { return "로그인 시 실행하려면 앱을 Applications 폴더에 설치해 주세요." }
        if let errorMessage { return errorMessage }
        switch state {
        case .off: return "꺼짐 · 사용자가 켤 때만 등록합니다."
        case .on: return "켜짐 · 다음 로그인부터 실행됩니다."
        case .requiresApproval: return "시스템 설정의 로그인 항목에서 승인이 필요합니다."
        case .unavailable: return "로그인 항목 상태를 확인할 수 없습니다."
        }
    }

    func refresh() { state = controller.state }

    func setEnabled(_ enabled: Bool) {
        guard isInstalled else {
            errorMessage = "Applications 폴더에 설치한 앱에서 설정해 주세요."
            return
        }
        errorMessage = nil
        do {
            if enabled { try controller.register() }
            else { try controller.unregister() }
        } catch {
            errorMessage = enabled ? "자동 실행 등록에 실패했습니다. 설치 위치와 시스템 설정을 확인해 주세요."
                                   : "자동 실행 해제에 실패했습니다. 시스템 설정의 로그인 항목을 확인해 주세요."
        }
        refresh()
    }

    static func isStableInstallLocation(_ bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        guard path.hasSuffix(".app") else { return false }
        return path.hasPrefix("/Applications/") ||
            path.hasPrefix(home.appendingPathComponent("Applications").standardizedFileURL.path + "/")
    }
}
