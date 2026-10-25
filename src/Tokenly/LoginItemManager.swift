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

    /// Only an installed copy may change the login item. `.unavailable` (`SMAppService` reported `.notFound`)
    /// does not block it: an app that was never registered can report that state, and registering is the
    /// only way to find out. The toggle still shows only what `status` reports afterwards.
    var canChange: Bool { isInstalled }

    var statusMessage: String {
        if !isInstalled { return "로그인 시 실행하려면 앱을 Applications 폴더에 설치해 주세요." }
        if let errorMessage { return errorMessage }
        switch state {
        case .off: return "꺼짐 · 사용자가 켤 때만 등록합니다."
        case .on: return "켜짐 · 다음 로그인부터 실행됩니다."
        case .requiresApproval: return "시스템 설정의 로그인 항목에서 승인이 필요합니다."
        case .unavailable: return "시스템이 로그인 항목 상태를 확인하지 못했습니다. 아직 등록하지 않은 경우에도 이렇게 표시될 수 있으며, 켜면 등록을 시도합니다."
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
            errorMessage = enabled ? "자동 실행 등록에 실패했습니다(\(error.localizedDescription)). 시스템 설정의 로그인 항목을 확인해 주세요."
                                   : "자동 실행 해제에 실패했습니다(\(error.localizedDescription)). 시스템 설정의 로그인 항목을 확인해 주세요."
            refresh()
            return
        }
        refresh()
        // The call returned without an error; trust only the status the system reports now.
        if enabled && !isEnabled {
            errorMessage = "등록을 요청했지만 시스템에서 켜짐 상태가 확인되지 않았습니다. 시스템 설정의 로그인 항목을 확인해 주세요."
        } else if !enabled && isEnabled {
            errorMessage = "해제를 요청했지만 아직 켜져 있습니다. 시스템 설정의 로그인 항목을 확인해 주세요."
        }
    }

    nonisolated static func isStableInstallLocation(_ bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        guard path.hasSuffix(".app") else { return false }
        return path.hasPrefix("/Applications/") ||
            path.hasPrefix(home.appendingPathComponent("Applications").standardizedFileURL.path + "/")
    }
}
