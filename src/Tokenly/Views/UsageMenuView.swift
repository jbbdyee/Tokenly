import AppKit
import SwiftUI

struct UsageMenuView: View {
    @State private var showsRefreshInfo = false
    @ObservedObject var store: UsageStore
    @ObservedObject var externalStore: ExternalProviderStore
    @ObservedObject var displaySettings: ProviderDisplaySettings
    let settingsWindow: SettingsWindowManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    /// Whether the popover window is on screen; the low-state sparkle animates only while it is.
    @State private var isOnScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tokenly").font(.headline)
                Spacer()
                Button { store.refresh(); externalStore.refreshSelected(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(UsagePopoverCopy.refreshHelp)
                .accessibilityLabel("모든 서비스 새로고침")
                Button { settingsWindow.show(openSettings: openSettings.callAsFunction) } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("설정 열기")
                .accessibilityLabel("설정 열기")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Divider()

            if needsBoundedProviderScroll {
                ScrollView { providerSections }
                    .frame(height: max(180, (NSScreen.main?.visibleFrame.height ?? 700) - 170))
            } else {
                providerSections
            }

            Divider()
            HStack {
                Text(UsagePopoverCopy.footer)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showsRefreshInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("갱신 방식 안내")
                .accessibilityLabel("갱신 방식 안내")
                .popover(isPresented: $showsRefreshInfo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("갱신 방식").font(.headline)
                        Text("Codex는 1분 조건, AGY는 5분 조건으로 자동 조회합니다.")
#if TOKENLY_CLAUDE_DEV
                    if ClaudeDevelopmentConfiguration.isEnabled {
                        Text(ClaudeDevelopmentConfiguration.isMock
                             ? "가상 데이터 검증: 실제 Claude 계정 조회가 아닙니다. SDK 조회와 상태줄 대체 표시를 시험합니다."
                             : "Claude 개발 검증 앱: SDK 조회와 Claude Code 상태줄 수신을 구분해 표시합니다. SDK 조회 실패 시 이전 데이터나 상태줄 데이터를 사용할 수 있습니다.")
                        Text(ClaudeDevelopmentConfiguration.isMock
                             ? (ClaudeDevelopmentConfiguration.isMockSixty
                                ? "가상 SDK 조회는 성공 후 60초에 한 번 더, 최대 2회 실행합니다. 실제 계정 조회가 아닙니다."
                                : "가상 검증은 첫 조회만 실행합니다. 선택한 간격은 실제 SDK 조회가 아닙니다.")
                             : "Claude SDK 조회 조건: \(Int(externalStore.automaticTickInterval))초 · 화면 표시는 별도로 갱신됩니다.")
                    } else {
                        Text("Claude는 Claude Code 사용 중 전달된 한도를 표시합니다. 앱에서 서버에 직접 조회하지 않습니다.")
                    }
#elseif TOKENLY_CLAUDE_PRODUCT_CANDIDATE
                    Text("Claude는 성공한 SDK 조회 완료 후 최소 1분이 지나면 다시 조회합니다. 실패하거나 실행 환경이 없으면 기존 상태줄 데이터를 대신 표시합니다.")
#else
                    Text("Claude는 Claude Code 사용 중 전달된 한도를 표시합니다. 앱에서 서버에 직접 조회하지 않습니다.")
#endif
                        Text("AGY 직접 조회가 실패하면 상태줄 수신값을 대신 표시할 수 있습니다.")
                        if let date = externalStore.agySourceTimes[.directCLI] {
                            Text("AGY 직접 조회 마지막 성공: \(CompactDateTime.string(for: date))")
                        }
                        if let date = externalStore.agySourceTimes[.statusLine] {
                            Text("AGY 상태줄 마지막 수신: \(CompactDateTime.string(for: date))")
                        }
                        Text("마지막 갱신은 직접 조회 성공 시각, 마지막 수신은 상태줄 데이터 수신 시각입니다. 다시 읽기만 해서는 시각이 바뀌지 않습니다.")
                        Text("Claude는 마지막 수신 후 15분이 지나면 이전 데이터로 표시합니다. AGY도 오래된 대체 데이터는 최신 조회로 표시하지 않습니다.")
                        if !agyInfoQuotas.isEmpty {
                            Divider()
                            Text("AGY 원본 한도 항목").font(.caption.weight(.semibold))
                            ForEach(agyInfoQuotas) { quota in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(quota.name).font(.caption.weight(.medium))
                                    Text("\(Int(quota.remainingPercent.rounded()))% 남음 · \(resetText(quota.resetsAt))")
                                        .monospacedDigit()
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text("Gemini는 그룹 표시 이름입니다. 두 ID의 정확한 그룹 의미와 개별 모델 사용 가능 여부는 공식적으로 확인되지 않았습니다.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                    .frame(width: 280, alignment: .leading)
                    .padding(14)
                }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(WindowVisibilityReporter(handle: nil) { visible in
            Task { @MainActor in isOnScreen = visible }
        })
        .environment(\.remainingSparkleActive, isOnScreen)
        .frame(width: 340)
        .background(.regularMaterial)
    }

    private var needsBoundedProviderScroll: Bool {
        let expandedCount = (displaySettings.showsCodex && displaySettings.codexExpanded ? 1 : 0)
            + (displaySettings.showsAGY && displaySettings.agyExpanded ? 1 : 0)
            + (displaySettings.showsClaude && displaySettings.claudeExpanded ? 1 : 0)
        return expandedCount >= 2 && (NSScreen.main?.visibleFrame.height ?? 700) < 750
    }

    private var providerSections: some View {
        VStack(alignment: .leading, spacing: 0) {
                if displaySettings.visibleSupportedProviders.isEmpty {
                    Label("표시할 서비스가 없습니다. 설정에서 표시를 켜세요.", systemImage: "eye.slash")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 14)
                }
                if displaySettings.showsCodex {
                    section("Codex", summary: codexSummary, status: codexStatus,
                            expanded: $displaySettings.codexExpanded) { codexDetails }
                }
                if displaySettings.showsCodex && displaySettings.showsClaude { Divider() }
                if displaySettings.showsClaude {
                    section("Claude", summary: claudeSummary, status: claudeStatus,
                            expanded: $displaySettings.claudeExpanded) { claudeDetails }
                }
                if displaySettings.showsAGY {
                    if displaySettings.showsCodex || displaySettings.showsClaude { Divider() }
                    section("Google Antigravity", summary: nil, status: agyStatus,
                            expanded: $displaySettings.agyExpanded) { agyDetails }
                }
        }
        .padding(.horizontal, 14)
    }

    private func section<Details: View>(
        _ title: String, summary: String?, status: String?, expanded: Binding<Bool>,
        @ViewBuilder details: () -> Details
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let summary {
                        Text(summary)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([title, summary, expanded.wrappedValue ? "접기" : "펼치기"]
                .compactMap { $0 }.joined(separator: ", "))
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            if expanded.wrappedValue { details().padding(.top, 10) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
    }

    private var codexSummary: String {
        if let snapshot = store.snapshot { return snapshot.menuBarSummary ?? "한도 데이터 없음" }
        if store.isRefreshing { return "조회 중" }
        return store.errorMessage == nil ? "데이터 없음" : "조회 실패"
    }

    private var codexStatus: String? {
        if store.errorMessage != nil { return store.snapshot == nil ? "연결 오류" : "조회 실패 · 이전 데이터" }
        if store.isRefreshing { return "갱신 중" }
        if store.snapshot?.windows.contains(where: { $0.remainingPercent <= 0 }) == true { return "일부 한도 소진" }
        return nil
    }

    private var codexDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isRefreshing { ProgressView("조회 중").controlSize(.small).font(.caption) }
            if let message = store.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let snapshot = store.snapshot, !snapshot.windows.isEmpty {
                ForEach(UsageWindowKind.allCases) { kind in codexWindow(kind, snapshot: snapshot) }
                resetCreditsSection(snapshot.resetCredits)
                Text(CompactDateTime.lastRefreshText(for: snapshot.fetchedAt))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(CompactDateTime.fullString(for: snapshot.fetchedAt))
            } else if !store.isRefreshing && store.errorMessage == nil {
                Text("표시할 한도 데이터가 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// ChatGPT rate-limit reset credits (read-only), shown only inside the expanded Codex section.
    private func resetCreditsSection(_ credits: RateLimitResetCredits?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("사용 한도 재설정").font(.caption.weight(.medium))
                Spacer()
                if let credits {
                    Text(ResetCreditText.countText(credits))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                } else {
                    Text("정보 없음").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(ResetCreditText.detailLines(credits), id: \.self) { line in
                Text(line).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func codexWindow(_ kind: UsageWindowKind, snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind.title).font(.caption.weight(.medium))
                Spacer()
                if let window = snapshot.window(kind) {
                    RemainingPercentLabel(percent: window.remainingPercent)
                } else {
                    Text("데이터 없음").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let window = snapshot.window(kind) {
                ProgressView(value: window.remainingPercent, total: 100)
                    .tint(color(for: window.remainingLevel))
                    .remainingLevelFill(percent: window.remainingPercent, level: window.remainingLevel, dark: colorScheme == .dark)
                    .accessibilityLabel("\(kind.title) 남은 한도")
                    .accessibilityValue(RemainingLevelCopy.accessibilityValue(window.remainingPercent, decimals: 1))
                Text("사용 \(String(format: "%.1f%%", window.usedPercent)) · \(resetText(window.resetsAt))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(window.resetsAt.map(CompactDateTime.fullString) ?? "초기화 시각 미제공")
            }
        }
    }

    private var claudeSummary: String {
        switch externalStore.state(for: .claude) {
        case .idle: return "수신 대기"
        case .loading: return "조회 중"
        case .success(let value): return claudeSummary(value)
        case .failure(.claudeStaleData, let previous): return previous.map(claudeSummary) ?? "최신 데이터 없음"
        case .failure(_, let previous): return previous.map(claudeSummary) ?? "조회 불가"
        }
    }

    private func claudeSummary(_ snapshot: ExternalUsageSnapshot) -> String {
        guard case .quotas(let quotas) = snapshot.metrics else { return "한도 데이터 없음" }
        return quotas.map { "\($0.name == "5시간 한도" ? "5h" : "7d") \(Int($0.remainingPercent.rounded()))%" }
            .joined(separator: " · ")
    }

    private var claudeStatus: String? {
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
        UsagePopoverCopy.claudeStatus(externalStore.state(for: .claude), direct: externalStore.claudeDirectStatus)
#else
        UsagePopoverCopy.claudeStatus(externalStore.state(for: .claude))
#endif
    }

    private var claudeDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
            if let direct = externalStore.claudeDirectStatus,
               let notice = UsagePopoverCopy.claudeDirectDetail(direct, manual: externalStore.claudeManualRetry) {
                Text(notice).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
#endif
            switch externalStore.state(for: .claude) {
            case .idle: Text(UsagePopoverCopy.claudeIdleDetail).font(.caption).foregroundStyle(.secondary)
            case .loading: ProgressView(UsagePopoverCopy.claudeLoadingDetail).controlSize(.small).font(.caption)
            case .failure(let error, let previous):
                Text(UsagePopoverCopy.claudeDetail(error)).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous {
                    claudeMetrics(previous.metrics)
                    Text("이전 데이터 · \(claudeReceipt(previous))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(CompactDateTime.fullString(for: previous.fetchedAt))
                }
            case .success(let value):
                claudeMetrics(value.metrics)
                Text(claudeReceipt(value))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(CompactDateTime.fullString(for: value.fetchedAt))
            }
        }
    }

    private func claudeReceipt(_ snapshot: ExternalUsageSnapshot) -> String {
#if TOKENLY_CLAUDE_DEV
        if ClaudeDevelopmentConfiguration.isEnabled,
           let direct = snapshot.sourceTimes[.directCLI] {
            let prefix = ClaudeDevelopmentConfiguration.isMock ? "가상 SDK 조회" : "SDK 조회"
            var pieces = ["\(prefix) 마지막 성공 \(CompactDateTime.string(for: direct))"]
            if let feed = snapshot.sourceTimes[.statusLine] {
                pieces.append("상태줄 마지막 수신 \(CompactDateTime.string(for: feed))")
            }
            return pieces.joined(separator: " · ")
        }
#endif
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
        if let direct = snapshot.sourceTimes[.directCLI] {
            let receipt = "마지막 갱신 \(CompactDateTime.string(for: direct))"
            if let feed = snapshot.sourceTimes[.statusLine] {
                return receipt + " · 마지막 수신 \(CompactDateTime.string(for: feed))"
            }
            return receipt
        }
        return "상태줄 데이터 · 마지막 수신 \(CompactDateTime.string(for: snapshot.fetchedAt))"
#else
        return "마지막 수신 \(CompactDateTime.string(for: snapshot.fetchedAt))"
#endif
    }

    @ViewBuilder
    private func claudeMetrics(_ metrics: ExternalMetrics) -> some View {
        if case .quotas(let quotas) = metrics {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(quotas) { quota in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(quota.name).font(.caption.weight(.medium))
                            Spacer()
                            RemainingPercentLabel(percent: quota.remainingPercent)
                        }
                        ProgressView(value: quota.remainingPercent, total: 100)
                            .tint(color(for: RemainingLevel(percent: quota.remainingPercent)))
                            .remainingLevelFill(percent: quota.remainingPercent, level: RemainingLevel(percent: quota.remainingPercent),
                                                dark: colorScheme == .dark)
                            .accessibilityLabel("Claude \(quota.name) 남은 한도")
                            .accessibilityValue(RemainingLevelCopy.accessibilityValue(quota.remainingPercent))
                        Text(resetText(quota.resetsAt))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(quota.resetsAt.map(CompactDateTime.fullString) ?? "초기화 시각 미제공")
                    }
                }
            }
        }
    }

    private var agyInfoQuotas: [QuotaMetric] {
        let state = externalStore.state(for: .antigravity)
        let snapshot = state.snapshot ?? externalStore.settledState(for: .antigravity).snapshot
        guard let snapshot, case .quotas(let quotas) = snapshot.metrics else { return [] }
        return quotas.sorted { AGYPopoverPresentation.infoOrder($0.name) < AGYPopoverPresentation.infoOrder($1.name) }
    }

    private var agyStatus: String? {
        UsagePopoverCopy.agyStatus(externalStore.state(for: .antigravity))
    }

    private var agyDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch externalStore.state(for: .antigravity) {
            case .idle: Text("데이터 없음").font(.caption).foregroundStyle(.secondary)
            case .loading: ProgressView("갱신 중").controlSize(.small).font(.caption)
            case .failure(let error, let previous):
                Text(UsagePopoverCopy.agyDetail(error)).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous {
                    agyMetrics(previous.metrics)
                    Text("이전 데이터 · \(UsagePopoverCopy.agyTimestamp(previous))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(CompactDateTime.fullString(for: previous.fetchedAt))
                }
            case .success(let value):
                agyMetrics(value.metrics)
                Text(UsagePopoverCopy.agyTimestamp(value))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(CompactDateTime.fullString(for: value.fetchedAt))
            }
        }
    }

    @ViewBuilder
    private func agyMetrics(_ metrics: ExternalMetrics) -> some View {
        if case .quotas(let quotas) = metrics {
            if let gemini = AGYPopoverPresentation.geminiQuota(in: quotas) {
                quotaRows([gemini])
            } else {
                Text(AGYPopoverPresentation.missingGeminiMessage(for: quotas))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func quotaRows(_ quotas: [QuotaMetric]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(quotas) { quota in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gemini")
                            .font(.caption.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        RemainingPercentLabel(percent: quota.remainingPercent)
                    }
                    ProgressView(value: quota.remainingPercent, total: 100)
                        .tint(color(for: RemainingLevel(percent: quota.remainingPercent)))
                        .remainingLevelFill(percent: quota.remainingPercent, level: RemainingLevel(percent: quota.remainingPercent),
                                            dark: colorScheme == .dark)
                        .accessibilityLabel("Gemini 그룹 남은 한도")
                        .accessibilityValue(RemainingLevelCopy.accessibilityValue(quota.remainingPercent))
                    Text(resetText(quota.resetsAt))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(quota.resetsAt.map(CompactDateTime.fullString) ?? "초기화 시각 미제공")
                }
            }
        }
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "초기화 시각 미제공" }
        return "초기화 \(CompactDateTime.string(for: date))"
    }

    /// Native tint under the drawn fill (`remainingLevelFill` paints over it). Healthy uses RAM's mint (UI colour
    /// harmony, 2026-10-29); caution and low use the AI-only cream and pearl (v0.4.1), so RAM's amber is untouched.
    private func color(for level: RemainingLevel) -> Color {
        let dark = colorScheme == .dark
        switch level {
        case .healthy: return HarmonyPalette.mint(dark: dark).color
        case .caution: return AIWarningPalette.cream(dark: dark).color
        case .low: return AIWarningPalette.pearl[0].color
        }
    }
}

enum UsagePopoverCopy {
    static var claudeIdleDetail: String {
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
        return "Claude SDK 자동 조회를 기다립니다. 실행 환경이 없으면 Claude Code 사용 시 갱신됩니다."
#else
        return "Claude Code 사용 시 갱신됩니다."
#endif
    }

    static var claudeLoadingDetail: String {
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
        return "Claude 사용량 확인 중"
#else
        return "로컬 수신 파일 확인 중"
#endif
    }

    static var footer: String {
#if TOKENLY_CLAUDE_DEV
        if ClaudeDevelopmentConfiguration.isEnabled {
            return ClaudeDevelopmentConfiguration.isMock
                ? "가상 Claude 데이터 · 실제 계정 조회 없음"
                : "Codex · AGY 자동 갱신 | Claude SDK 개발 검증 중"
        }
#endif
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
        return "Codex · AGY · Claude 자동 갱신"
#else
        return "Codex · AGY 자동 갱신 | Claude 사용 중 갱신"
#endif
    }

    static var refreshHelp: String {
#if TOKENLY_CLAUDE_DEV
        if ClaudeDevelopmentConfiguration.isEnabled {
            return "Codex·AGY를 조회하고 Claude 개발용 SDK 조회 조건을 확인합니다"
        }
#endif
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
        return "Codex·AGY·Claude의 조회 조건을 확인합니다"
#else
        return "Codex·AGY는 공식 CLI로 조회하고 Claude는 로컬 상태줄 파일을 다시 읽습니다"
#endif
    }

    /// A stopped or waiting direct route outranks the data label, so statusLine data never hides it.
    static func claudeStatus(_ state: ExternalLoadState, direct: ClaudeDirectRefreshStatus?) -> String? {
        if let direct, direct.isInterrupted {
            switch direct.phase {
            case .paused(.authenticationRequired): return "직접 조회 중지 · 로그인 필요"
            case .paused(.permissionDenied): return "직접 조회 중지 · 권한 확인 필요"
            case .paused(.incompatibleSDK): return "직접 조회 중지 · 업데이트 필요"
            case .paused(.unexpectedModelActivity): return "직접 조회 안전 정지"
            case .paused: return "직접 조회 중지"
            case .rateLimited: return "요청 제한 · 직접 조회 대기"
            case .retryWaiting: return "직접 조회 재시도 대기"
            case .ready, .inFlight: break
            }
        }
        return claudeStatus(state)
    }

    /// Explains a direct-route interruption and the manual refresh outcome; nil while the route is healthy.
    static func claudeDirectDetail(_ status: ClaudeDirectRefreshStatus,
                                   manual: ClaudeManualRetryDecision? = nil) -> String? {
        var lines: [String] = []
        switch status.phase {
        case .ready, .inFlight: break
        case .retryWaiting(let until):
            lines.append("직접 조회가 일시적으로 실패했습니다. \(CompactDateTime.string(for: until)) 이후 자동으로 다시 시도하며, 새로고침으로 바로 재시도할 수 있습니다.")
        case .rateLimited(let until):
            lines.append("Claude 요청 제한으로 \(CompactDateTime.string(for: until))까지 직접 조회를 쉽니다.")
        case .paused(.authenticationRequired):
            lines.append("Claude CLI 로그인이 필요합니다. 터미널에서 claude에 다시 로그인한 뒤 새로고침하세요.")
        case .paused(.permissionDenied):
            lines.append("Claude 계정의 사용량 조회 권한을 확인한 뒤 새로고침하세요.")
        case .paused(.incompatibleSDK):
            lines.append("Claude SDK 응답 형식이 맞지 않아 직접 조회를 멈췄습니다. Tokenly 업데이트가 필요할 수 있습니다.")
        case .paused(.unexpectedModelActivity):
            lines.append("예상하지 않은 모델 활동이 감지되어 안전을 위해 직접 조회를 멈췄습니다. 새로고침으로는 다시 시작하지 않습니다.")
        case .paused(.checkpointUnavailable):
            lines.append("조회 기록 파일을 사용할 수 없어 직접 조회를 멈췄습니다.")
        case .paused:
            lines.append("직접 조회가 반복해서 실패해 멈췄습니다. 새로고침으로 다시 시도할 수 있습니다.")
        }
        if case .refused(let refusal) = manual {
            switch refusal {
            case .inFlight: lines.append("이미 조회 중입니다.")
            case .tooSoon(let until): lines.append("다시 시도는 \(CompactDateTime.string(for: until)) 이후에 가능합니다.")
            case .rateLimited, .safetyStop, .limitedTrial, .checkpointUnavailable: break
            }
        }
        guard !lines.isEmpty else { return nil }
        if status.isInterrupted {
            lines.append(status.lastSuccessAt.map { "마지막 정상 직접 조회 \(CompactDateTime.string(for: $0))" }
                         ?? "정상 직접 조회 기록 없음")
        }
        return lines.joined(separator: "\n")
    }

    static func claudeStatus(_ state: ExternalLoadState) -> String? {
#if TOKENLY_CLAUDE_PRODUCT_CANDIDATE && !TOKENLY_CLAUDE_DEV
        switch state {
        case .idle: return "자동 갱신 대기"
        case .loading: return "갱신 중"
        case .failure(_, let previous): return previous == nil ? "데이터 없음" : "이전 데이터 · 갱신 지연"
        case .success(let value):
            if case .quotas(let quotas) = value.metrics, quotas.contains(where: { $0.remainingPercent <= 0 }) {
                return "일부 한도 소진"
            }
            return value.source == .directCLI ? "자동 갱신" : "상태줄 데이터"
        }
#else
        switch state {
        case .idle: return "사용 중 갱신"
        case .loading: return "갱신 중"
        case .failure(.claudeStaleData, let previous):
            return previous == nil ? "사용 중 갱신" : "이전 데이터 · 사용 중 갱신"
        case .failure(.setupRequired, let previous), .failure(.noData, let previous):
            return previous == nil ? "사용 중 갱신" : "이전 데이터 · 사용 중 갱신"
        case .failure(_, let previous): return previous == nil ? "데이터 없음" : "이전 데이터 · 사용 중 갱신"
        case .success(let value):
            if case .quotas(let quotas) = value.metrics, quotas.contains(where: { $0.remainingPercent <= 0 }) {
                return "일부 한도 소진"
            }
            return nil
        }
#endif
    }

    static func claudeDetail(_ error: ExternalProviderError) -> String {
        switch error {
        case .claudeStaleData, .noData: return "Claude Code 사용 시 갱신됩니다."
        case .setupRequired: return "Claude Code 연결 설정을 확인하세요."
        default: return error.message
        }
    }

    static func agyStatus(_ state: ExternalLoadState) -> String {
        switch state {
        case .idle: return "데이터 없음"
        case .loading: return "갱신 중"
        case .failure(_, let previous): return previous == nil ? "데이터 없음" : "갱신 지연"
        case .success(let value):
            if case .quotas(let quotas) = value.metrics, AGYQuotaSummary.hasExhaustedBucket(quotas) {
                return "일부 한도 소진"
            }
            return value.source == .directCLI ? "자동 갱신" : "갱신 지연"
        }
    }

    static func agyDetail(_ error: ExternalProviderError) -> String {
        switch error {
        case .staleData: return "최근 갱신이 지연되고 있습니다."
        case .noData: return "표시할 사용량 데이터가 없습니다."
        default: return error.message
        }
    }

    static func agyTimestamp(_ snapshot: ExternalUsageSnapshot) -> String {
        let label = snapshot.source == .directCLI ? "마지막 갱신" : "마지막 수신"
        return "\(label) · \(CompactDateTime.string(for: snapshot.fetchedAt))"
    }
}

enum AGYPopoverPresentation {
    static func geminiQuota(in quotas: [QuotaMetric]) -> QuotaMetric? {
        quotas.first { $0.name == "gemini-weekly" }
    }

    static func missingGeminiMessage(for quotas: [QuotaMetric]) -> String {
        quotas.isEmpty ? "데이터 없음" : "Gemini 한도 정보 없음 · 다른 항목은 정보(i)에서 확인"
    }

    static func infoOrder(_ name: String) -> Int {
        switch name {
        case "gemini-weekly": return 0
        case "3p-weekly": return 1
        default: return 2
        }
    }
}

enum CompactDateTime {
    /// A successful local retrieval time, not the service's internal accounting time.
    static func lastRefreshText(for date: Date, now: Date = Date(),
                                locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "마지막 갱신 시간 \(string(for: date, now: now, locale: locale, timeZone: timeZone))"
    }

    static func string(for date: Date, now: Date = Date(),
                       locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        calendar.locale = locale
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.calendar = calendar
        let dayLabel: String
        if calendar.isDate(date, inSameDayAs: now) ||
            calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) {
            let relative = RelativeDateTimeFormatter()
            relative.locale = locale
            relative.dateTimeStyle = .named
            let days = calendar.isDate(date, inSameDayAs: now) ? 0 : 1
            dayLabel = relative.localizedString(from: DateComponents(day: days))
        } else {
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            dateFormatter.setLocalizedDateFormatFromTemplate(sameYear ? "Md" : "yMd")
            dayLabel = dateFormatter.string(from: date)
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.timeStyle = .short
        return "\(dayLabel) \(timeFormatter.string(from: date))"
    }

    static func fullString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter.string(from: date)
    }
}

/// Wording for the Codex reset-credit section; dates in Korean local date and time.
enum ResetCreditText {
    static func countText(_ credits: RateLimitResetCredits, now: Date = Date()) -> String {
        let count = credits.usableCount(now: now)
        return count == 0 ? "사용 가능 없음" : "\(count)회 사용 가능"
    }

    /// One line per usable credit, earliest deadline first: "1회차 사용 기한: 10월 30일 오전 4:25".
    /// "만료" was dropped because it read as "already expired".
    static func detailLines(_ credits: RateLimitResetCredits?, now: Date = Date(),
                            timeZone: TimeZone = .current) -> [String] {
        guard let credits else { return ["Codex가 재설정 권한 정보를 제공하지 않았습니다."] }
        guard credits.credits != nil else {
            return credits.usableCount(now: now) > 0 ? ["사용 기한 정보는 제공되지 않았습니다."] : []
        }
        let usable = credits.usableCredits(now: now)
        var lines = usable.enumerated().map { index, credit in
            credit.expiresAt.map { "\(index + 1)회차 사용 기한: \(deadline($0, now: now, timeZone: timeZone))" }
                ?? "\(index + 1)회차 사용 기한 없음"
        }
        // The backend may cap the detail list: say so, rather than let the listed rows look like all credits.
        let missing = credits.usableCount(now: now) - usable.count
        if missing > 0 { lines.append("나머지 \(missing)회는 사용 기한 정보가 제공되지 않았습니다.") }
        return lines
    }

    /// "10월 30일 오전 4:25"; the year is added only when it differs from the current one.
    static func deadline(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "M월 d일 a h:mm" : "yyyy년 M월 d일 a h:mm"
        return formatter.string(from: date)
    }
}

/// Every AI remaining-limit bar gets a drawn fill over the native bar (UI colour harmony, 2026-10-29; v0.4.1). The
/// native linear `ProgressView` takes one tint colour only, so the bar itself is kept (size, track, rounding, position
/// and accessibility unchanged) and the fill is drawn over it: a capsule of the track's height, vertically centred,
/// whose width is the remaining fraction, starting at the leading edge like the native fill.
/// Healthy: RAM's mint → blue → lavender. Caution: cream yellow. Low: pearl white with sparkles (`PearlSparkles`).
/// In light mode the cream and pearl fills get a 1 pt edge so they do not disappear into the light track.
extension View {
    func remainingLevelFill(percent: Double, level: RemainingLevel, dark: Bool) -> some View {
        overlay(alignment: .leading) {
            GeometryReader { geometry in
                let width = geometry.size.width * HealthyGradientFill.fraction(percent)
                let height = min(HealthyGradientFill.trackHeight, geometry.size.height)
                ZStack(alignment: .leading) {
                    if width > 0 {
                        Capsule()
                            .fill(AIWarningPalette.fill(level, dark: dark))
                            .overlay(Capsule().strokeBorder(AIWarningPalette.edge(level, dark: dark), lineWidth: 1))
                            .shadow(color: AIWarningPalette.glow(level, dark: dark), radius: 3)
                            .frame(width: width, height: height)
                    }
                    if level == .low {
                        PearlSparkles(fillWidth: width, trackHeight: height, dark: dark)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// AI remaining-limit warning colours (v0.4.1, design B "반짝이는 펄"). Separate from `HarmonyPalette.amber`, which the
/// RAM pressure badge shares, so the system monitor's warning colours do not change. Thresholds stay in `RemainingLevel`.
enum AIWarningPalette {
    private static func hex(_ value: UInt32) -> AuroraPalette.RGB { HarmonyPalette.hex(value) }
    /// Caution cream yellow: #FFF0C4 dark, #F6E2A6 light; the fill fades down from #FFFAF0 at the top.
    static func cream(dark: Bool) -> AuroraPalette.RGB { hex(dark ? 0xFFF0C4 : 0xF6E2A6) }
    static let creamHighlight = hex(0xFFFAF0)
    /// Low pearl white, left to right: white → faint lavender → faint aqua → warm white.
    static let pearl = [hex(0xFFFFFF), hex(0xF5EFFF), hex(0xEEF8FB), hex(0xFFFDF5)]
    /// Star and "부족" ink: near-white lavender in dark mode, #5F5490 (about 7:1 on the light popover) in light mode.
    static func pearlInk(dark: Bool) -> AuroraPalette.RGB { hex(dark ? 0xF6F2FF : 0x5F5490) }
    /// Popover sparkles: white in dark mode, #7D6CC4 in light mode so they show against the light track.
    static func spark(dark: Bool) -> AuroraPalette.RGB { hex(dark ? 0xFFFFFF : 0x7D6CC4) }
    /// The pearl sheen: a lavender and an aqua band.
    static func sheen(dark: Bool) -> [Color] {
        dark ? [hex(0xC4B2FF).color.opacity(0.85), hex(0xAAE8F6).color.opacity(0.8)]
             : [hex(0xBAA8FF).color.opacity(0.75), hex(0xA0DEEC).color.opacity(0.7)]
    }

    static func fill(_ level: RemainingLevel, dark: Bool) -> LinearGradient {
        switch level {
        case .healthy:
            return LinearGradient(colors: HarmonyPalette.progressGradient(dark: dark), startPoint: .leading, endPoint: .trailing)
        case .caution:
            return LinearGradient(stops: [.init(color: creamHighlight.color, location: 0),
                                          .init(color: cream(dark: dark).color, location: 0.7)],
                                  startPoint: .top, endPoint: .bottom)
        case .low:
            return LinearGradient(stops: zip(pearl, [0, 0.38, 0.7, 1]).map { .init(color: $0.0.color, location: $0.1) },
                                  startPoint: .leading, endPoint: .trailing)
        }
    }

    /// 1 pt edge in light mode only: gold on cream, lavender grey on pearl. Healthy keeps no edge.
    static func edge(_ level: RemainingLevel, dark: Bool) -> Color {
        guard !dark else { return .clear }
        switch level {
        case .healthy: return .clear
        case .caution: return hex(0x966C18).color.opacity(0.6)
        case .low: return hex(0x5C508C).color.opacity(0.55)
        }
    }

    /// A soft glow lifts the pearl off the dark track; nothing elsewhere.
    static func glow(_ level: RemainingLevel, dark: Bool) -> Color {
        dark && level == .low ? hex(0xEBE1FF).color.opacity(0.55) : .clear
    }
}

private struct RemainingSparkleActiveKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while the AI popover is on screen. Off by default, so a sparkle never animates where no one sees it.
    var remainingSparkleActive: Bool {
        get { self[RemainingSparkleActiveKey.self] }
        set { self[RemainingSparkleActiveKey.self] = newValue }
    }
}

/// A four-point star, the same outline as the menu bar's low-state star.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path { Path(MenuBarNumericImage.starPath(in: rect)) }
}

/// Low-state decoration at the end of a pearl fill: three small stars and, every cycle, one sheen across the fill.
/// Animation runs only while the popover is on screen and Reduce Motion is off, as short eased transitions driven by
/// a sleeping task (no per-frame timer): about 7 s per cycle, of which the last 3.2 s are idle. With Reduce Motion
/// the stars are drawn still and there is no sheen.
struct PearlSparkles: View {
    let fillWidth: CGFloat
    let trackHeight: CGFloat
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.remainingSparkleActive) private var onScreen
    @State private var lit = [false, false, false]
    @State private var swept = false

    /// Star centre offsets from the fill's end on the track's midline, and box sizes, as in the approved preview.
    static let stars: [(dx: CGFloat, dy: CGFloat, size: CGFloat)] = [(-1.5, -7.5, 7), (5.5, 4.5, 5), (-11, 6, 4)]
    static let restingOpacity = 0.85

    private var animates: Bool { onScreen && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let midY = geometry.size.height / 2
            let spark = AIWarningPalette.spark(dark: dark).color
            ZStack(alignment: .topLeading) {
                if animates && fillWidth > 0 {
                    LinearGradient(colors: [.clear] + AIWarningPalette.sheen(dark: dark) + [.clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: fillWidth * 0.6, height: trackHeight)
                        .offset(x: swept ? fillWidth * 1.2 : -fillWidth * 0.6)
                        .frame(width: fillWidth, height: trackHeight, alignment: .leading)
                        .clipShape(Capsule())
                        .position(x: fillWidth / 2, y: midY)
                }
                ForEach(Self.stars.indices, id: \.self) { index in
                    let star = Self.stars[index]
                    let x = min(max(fillWidth + star.dx, star.size / 2), geometry.size.width - star.size / 2)
                    SparkleShape()
                        .fill(spark)
                        .shadow(color: spark.opacity(0.8), radius: 0.75)
                        .frame(width: star.size, height: star.size)
                        .scaleEffect(animates ? (lit[index] ? 1 : 0.5) : 1)
                        .opacity(animates ? (lit[index] ? 1 : 0) : Self.restingOpacity)
                        .position(x: x, y: midY + star.dy)
                }
            }
        }
        .task(id: animates) {
            guard animates else { return }
            await twinkle()
        }
    }

    private func twinkle() async {
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 1.4)) { swept = true }
            for index in lit.indices {
                guard await pause(index == 0 ? 0.3 : 0.75) else { return reset() }
                withAnimation(.easeOut(duration: 0.45)) { lit[index] = true }
                guard await pause(0.45) else { return reset() }
                withAnimation(.easeIn(duration: 0.6)) { lit[index] = false }
            }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { swept = false }
            guard await pause(3.2) else { return reset() }
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        (try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))) != nil
    }

    private func reset() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { lit = [false, false, false]; swept = false }
    }
}

/// "12% 남음", or "✦ 12% 남음 · 부족" at or below 20 %, so the low state is never colour alone. Same caption font.
struct RemainingPercentLabel: View {
    let percent: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ink = AIWarningPalette.pearlInk(dark: colorScheme == .dark).color
        HStack(spacing: 3) {
            if RemainingLevelCopy.isLow(percent) {
                SparkleShape().fill(ink).frame(width: 8, height: 8)
            }
            Text(RemainingLevelCopy.percentText(percent))
                .font(.caption.weight(.semibold)).monospacedDigit()
            if RemainingLevelCopy.isLow(percent) {
                Text(RemainingLevelCopy.lowSuffix).font(.caption.weight(.semibold)).foregroundStyle(ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RemainingLevelCopy.spoken(percent))
    }
}

enum RemainingLevelCopy {
    static let lowSuffix = "· 부족"
    static func isLow(_ percent: Double) -> Bool { RemainingLevel(percent: percent) == .low }
    static func percentText(_ percent: Double) -> String { "\(Int(percent.rounded()))% 남음" }
    /// What the popover row reads, with the star written as ✦.
    static func displayText(_ percent: Double) -> String {
        isLow(percent) ? "✦ \(percentText(percent)) \(lowSuffix)" : percentText(percent)
    }
    static func spoken(_ percent: Double) -> String {
        isLow(percent) ? "\(percentText(percent)), 한도 부족" : percentText(percent)
    }
    static func accessibilityValue(_ percent: Double, decimals: Int = 0) -> String {
        let value = String(format: "%.\(decimals)f퍼센트", percent)
        return isLow(percent) ? "\(value), 한도 부족" : value
    }
}

enum HealthyGradientFill {
    /// The native linear bar draws an 8 pt capsule track centred in a taller (20 pt) frame. There is no API for the
    /// track height; 8 pt was measured pixel by pixel on macOS 27 (track and native fill rows identical).
    static let trackHeight: CGFloat = 8

    /// Remaining percent → fill fraction, as the native bar clamps it (0...1).
    static func fraction(_ percent: Double) -> CGFloat {
        guard percent.isFinite else { return 0 }
        return CGFloat(min(max(percent / 100, 0), 1))
    }
}
