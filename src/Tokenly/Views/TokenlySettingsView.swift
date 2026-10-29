import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class ServiceConnectionForm: ObservableObject {
    @Published var adminKeyInput = ""
    @Published var hasAdminKey = false
    @Published var agyFeedExists = false
    @Published var claudeFeedExists = false
    @Published var credentialMessage: String?
}

struct TokenlySettingsView: View {
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject var displaySettings: ProviderDisplaySettings
    @ObservedObject var externalStore: ExternalProviderStore
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var systemWidgets: SystemWidgetController
    @StateObject private var form = ServiceConnectionForm()
    private let adminKeys = KeychainAdminKeyStore()

    var body: some View {
        TabView {
            general
                .tabItem { Label("일반", systemImage: "gearshape") }
            services
                .tabItem { Label("AI 서비스", systemImage: "square.stack") }
            menuBar
                .tabItem { Label("메뉴 막대", systemImage: "menubar.rectangle") }
            themes
                .tabItem { Label("테마", systemImage: "paintpalette") }
            SystemMonitorSettingsView(controller: systemWidgets)
                .tabItem { Label("시스템", systemImage: "cpu") }
        }
        .frame(width: 440, height: 300)
        .onAppear {
            loginItem.refresh()
            form.agyFeedExists = AGYStatusLineProvider().hasFeed
            form.claudeFeedExists = ClaudeSubscriptionProvider().hasFeed
        }
    }

    private var general: some View {
        settingsPage {
            Text("일반").font(.headline)
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .disabled(!loginItem.canChange)
            Text(loginItem.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("자동 실행은 Applications에 설치한 앱에서 설정할 수 있습니다. Xcode·임시 빌드에서는 등록할 수 없습니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loginItem.state == .requiresApproval {
                Button("로그인 항목 설정 열기") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
            }
        }
    }

    private var services: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            Text("AI 서비스").font(.headline)
            Text("팝오버에 표시할 서비스를 선택합니다. 숫자형 메뉴 막대도 이 선택을 따르고, 최소형은 항상 Codex만 표시합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Codex", isOn: $displaySettings.showsCodex)
            Text("연결 가능 · 숨겨도 5분 조회는 계속됩니다. 숫자형 메뉴 막대에서는 함께 숨겨집니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(codexConnectionStatus)
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("OpenAI API · 조직 관리자 조회").font(.subheadline.weight(.semibold))
            Text("연동 보류 중입니다. 기존 조회 코드는 유지하지만 현재 키 등록·연결 확인·사용량 표시는 사용하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Google Antigravity CLI").font(.subheadline.weight(.semibold))
            Text("CLI 상태줄 수신 파일을 읽습니다. IDE·Gemini API 사용량과 다릅니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("AGY를 팝오버에 표시", isOn: $displaySettings.showsAGY)
                    .disabled(!form.agyFeedExists)
                Button("연결 확인") {
                    form.agyFeedExists = AGYStatusLineProvider().hasFeed
                    if form.agyFeedExists { _ = externalStore.refresh(.antigravity) }
                }
            }
            connectCommandButton(.agy)
            externalStatus(.antigravity)
            Divider()
            Text("Claude Code · 구독 한도").font(.subheadline.weight(.semibold))
            Text("공식 상태줄의 5시간·7일 한도만 사용합니다. 설정 연결과 실제 계정 수신은 별도 확인이 필요합니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Claude를 팝오버에 표시", isOn: $displaySettings.showsClaude)
                Button("수신 확인") {
                    form.claudeFeedExists = ClaudeSubscriptionProvider().hasFeed
                    _ = externalStore.refresh(.claude)
                }
            }
            Text(form.claudeFeedExists ? "상태줄 수신 파일 있음" : "상태줄 수신 파일 없음 · Claude Code 설정 필요")
                .font(.caption).foregroundStyle(.secondary)
            connectCommandButton(.claude)
            externalStatus(.claude)
            Divider()
            Text("Gemini · 연동 검증 예정").font(.subheadline)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
        }
    }

    /// Copies the Terminal command that connects this CLI. The settings window itself never edits the
    /// Claude/AGY settings files; the command previews the change and asks before writing.
    private func connectCommandButton(_ source: StatusLineSource) -> some View {
        HStack {
            Button("연결 명령 복사") {
                let command = StatusLineConnector.shellQuote(BridgeCommand.executablePath()) + " --connect " + source.rawValue
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .help("터미널에 붙여 넣어 실행하면 변경 내용을 먼저 보여 주고, 확인한 뒤 백업과 함께 연결합니다. 기존 상태줄 출력은 유지됩니다.")
            Text("터미널에서 실행 · 해제는 --disconnect \(source.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func externalStatus(_ id: ExternalProviderID) -> some View {
        switch externalStore.state(for: id) {
        case .idle: EmptyView()
        case .loading: Text("연결 중…").font(.caption).foregroundStyle(.secondary)
        case .success(let value):
            Text("마지막 수신 \(CompactDateTime.string(for: value.fetchedAt))")
                .font(.caption).foregroundStyle(.secondary)
                .help(CompactDateTime.fullString(for: value.fetchedAt))
        case .failure(let error, _): Text(error.message).font(.caption).foregroundStyle(.orange)
        }
    }

    private var codexConnectionStatus: String {
        if usageStore.isRefreshing { return "조회 중" }
        if usageStore.errorMessage != nil {
            return usageStore.snapshot == nil ? "조회 실패" : "조회 실패 · 이전 데이터"
        }
        if let snapshot = usageStore.snapshot {
            return "마지막 성공 \(CompactDateTime.string(for: snapshot.fetchedAt))"
        }
        return "조회 대기"
    }

    private var menuBar: some View {
        settingsPage {
            Text("메뉴 막대").font(.headline)
            Picker("표시 스타일", selection: $displaySettings.menuBarStyle) {
                ForEach(MenuBarDisplayStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("미리보기").foregroundStyle(.secondary)
                if displaySettings.menuBarStyle == .numeric {
                    MenuBarNumericLabel(items: NumericGauge.items(store: usageStore, externalStore: externalStore,
                                                                  settings: displaySettings),
                                        fallback: MenuBarPresentation.text(style: .numeric, snapshot: usageStore.snapshot,
                                                                           isRefreshing: usageStore.isRefreshing,
                                                                           hasError: usageStore.errorMessage != nil))
                } else {
                    Text(MenuBarPresentation.text(style: displaySettings.menuBarStyle,
                                                  snapshot: usageStore.snapshot,
                                                  isRefreshing: usageStore.isRefreshing,
                                                  hasError: usageStore.errorMessage != nil))
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            Text("숫자형은 서비스마다 5시간 잔여율을 크게 위에, 7일 잔여율을 작게 아래에 ‘40/70’처럼 표시하고 이름을 아래에 둡니다. AGY는 5시간·7일 창이 없어 가장 낮은 버킷 잔여율 하나만 표시합니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("최소형은 Codex의 5시간·7일 잔여율만 한 줄로 표시합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var themes: some View {
        settingsPage {
            Text("테마").font(.headline)
            Picker("앱 외관", selection: $displaySettings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.radioGroup)
            Text("팝오버와 설정 창에 적용됩니다. 메뉴 막대 자체는 macOS 외관을 따릅니다.")
                .font(.caption).foregroundStyle(.secondary)
            SystemWidgetLayoutPicker(controller: systemWidgets)
            BatteryFramePicker(controller: systemWidgets)
        }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
    }
}
