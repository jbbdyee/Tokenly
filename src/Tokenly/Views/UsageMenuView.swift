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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tokenly").font(.headline)
                Spacer()
                Button { store.refresh(); externalStore.refreshSelected(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Codex·AGY는 공식 CLI로 조회하고 Claude는 로컬 상태줄 파일을 다시 읽습니다")
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
                        Text("Claude는 Claude Code 사용 중 전달된 한도를 표시합니다. 앱에서 서버에 직접 조회하지 않습니다.")
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
                    Text("\(Int(window.remainingPercent.rounded()))% 남음")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                } else {
                    Text("데이터 없음").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let window = snapshot.window(kind) {
                ProgressView(value: window.remainingPercent, total: 100)
                    .tint(color(for: window.remainingLevel))
                    .healthyGradientFill(percent: window.remainingPercent, level: window.remainingLevel, dark: colorScheme == .dark)
                    .accessibilityLabel("\(kind.title) 남은 한도")
                    .accessibilityValue("\(String(format: "%.1f", window.remainingPercent))퍼센트")
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
        UsagePopoverCopy.claudeStatus(externalStore.state(for: .claude))
    }

    private var claudeDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch externalStore.state(for: .claude) {
            case .idle: Text("Claude Code 사용 시 갱신됩니다.").font(.caption).foregroundStyle(.secondary)
            case .loading: ProgressView("로컬 수신 파일 확인 중").controlSize(.small).font(.caption)
            case .failure(let error, let previous):
                Text(UsagePopoverCopy.claudeDetail(error)).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous {
                    claudeMetrics(previous.metrics)
                    Text("이전 데이터 · 마지막 수신 \(CompactDateTime.string(for: previous.fetchedAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(CompactDateTime.fullString(for: previous.fetchedAt))
                }
            case .success(let value):
                claudeMetrics(value.metrics)
                Text("마지막 수신 \(CompactDateTime.string(for: value.fetchedAt))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(CompactDateTime.fullString(for: value.fetchedAt))
            }
        }
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
                            Text("\(Int(quota.remainingPercent.rounded()))% 남음")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        ProgressView(value: quota.remainingPercent, total: 100)
                            .tint(color(for: RemainingLevel(percent: quota.remainingPercent)))
                            .healthyGradientFill(percent: quota.remainingPercent, level: RemainingLevel(percent: quota.remainingPercent),
                                                 dark: colorScheme == .dark)
                            .accessibilityLabel("Claude \(quota.name) 남은 한도")
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
                        Text("\(Int(quota.remainingPercent.rounded()))% 남음")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    ProgressView(value: quota.remainingPercent, total: 100)
                        .tint(color(for: RemainingLevel(percent: quota.remainingPercent)))
                        .healthyGradientFill(percent: quota.remainingPercent, level: RemainingLevel(percent: quota.remainingPercent),
                                             dark: colorScheme == .dark)
                        .accessibilityLabel("Gemini 그룹 남은 한도")
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

    /// Remaining-limit bar colour. Healthy uses RAM's mint (UI colour harmony, 2026-10-29; was system green; the
    /// gradient is drawn over it), caution RAM's soft warning amber (was system orange), low keeps the system red.
    private func color(for level: RemainingLevel) -> Color {
        switch level {
        case .healthy: HarmonyPalette.mint(dark: colorScheme == .dark).color
        case .caution: HarmonyPalette.amber(dark: colorScheme == .dark).color
        case .low: .red
        }
    }
}

enum UsagePopoverCopy {
    static let footer = "Codex · AGY 자동 갱신 | Claude 사용 중 갱신"

    static func claudeStatus(_ state: ExternalLoadState) -> String? {
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

/// The healthy remaining-limit bars get RAM's mint → blue → lavender as a fill (UI colour harmony, 2026-10-29).
/// The native linear `ProgressView` takes one tint colour only, so the bar itself is kept (size, track, rounding,
/// position and accessibility unchanged) and the gradient is drawn over its fill: a capsule of the track's height,
/// vertically centred, whose width is the remaining fraction, starting at the leading edge like the native fill.
/// Caution uses HarmonyPalette.amber; low retains the system red tint.
extension View {
    func healthyGradientFill(percent: Double, level: RemainingLevel, dark: Bool) -> some View {
        overlay(alignment: .leading) {
            if level == .healthy {
                GeometryReader { geometry in
                    Capsule()
                        .fill(LinearGradient(colors: HarmonyPalette.progressGradient(dark: dark), startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * HealthyGradientFill.fraction(percent),
                               height: min(HealthyGradientFill.trackHeight, geometry.size.height))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
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
