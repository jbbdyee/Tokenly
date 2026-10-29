import AppKit
import SwiftUI

struct UsageMenuView: View {
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
                Button { store.refresh(); externalStore.refreshSelected() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Codex는 새로 조회하고 AGY·Claude는 로컬 상태줄 파일을 다시 읽습니다")
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
                Text("5분마다 갱신 · 상태줄은 로컬 재읽기").font(.caption2).foregroundStyle(.secondary)
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
                    section("Google Antigravity", summary: agySummary, status: agyStatus,
                            expanded: $displaySettings.agyExpanded) { agyDetails }
                }
        }
        .padding(.horizontal, 14)
    }

    private func section<Details: View>(
        _ title: String, summary: String, status: String?, expanded: Binding<Bool>,
        @ViewBuilder details: () -> Details
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(summary)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(summary), \(expanded.wrappedValue ? "접기" : "펼치기")")
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
                Text("마지막 성공 \(CompactDateTime.string(for: snapshot.fetchedAt))")
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
                    .accessibilityLabel("\(kind.title) 남은 한도")
                    .accessibilityValue("\(String(format: "%.1f", window.remainingPercent))퍼센트")
                Text("사용 \(String(format: "%.1f%%", window.usedPercent)) · \(resetText(window.resetsAt))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(window.resetsAt.map(CompactDateTime.fullString) ?? "초기화 시각 미제공")
            }
        }
    }

    private var agySummary: String {
        switch externalStore.state(for: .antigravity) {
        case .idle: return "조회 대기"
        case .loading: return "조회 중"
        case .success(let value): return summary(value)
        case .failure(.staleData, let previous): return previous.map(summary) ?? "최신 데이터 없음"
        case .failure(_, let previous): return previous.map(summary) ?? "조회 불가"
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
        switch externalStore.state(for: .claude) {
        case .failure(.claudeStaleData, _): return "상태줄 갱신 대기"
        case .failure(_, let previous): return previous == nil ? "연결 또는 수신 오류" : "조회 실패 · 이전 데이터"
        case .success(let value):
            if case .quotas(let quotas) = value.metrics, quotas.contains(where: { $0.remainingPercent <= 0 }) {
                return "일부 한도 소진"
            }
            return nil
        default: return nil
        }
    }

    private var claudeDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch externalStore.state(for: .claude) {
            case .idle: Text("수신 대기 중").font(.caption).foregroundStyle(.secondary)
            case .loading: ProgressView("로컬 수신 파일 확인 중").controlSize(.small).font(.caption)
            case .failure(let error, let previous):
                Text(error.message).font(.caption).foregroundStyle(.orange)
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

    private func summary(_ value: ExternalUsageSnapshot) -> String {
        guard case .quotas(let quotas) = value.metrics else { return "쿼터 데이터 없음" }
        return AGYQuotaSummary.text(for: quotas)
    }

    private var agyStatus: String? {
        switch externalStore.state(for: .antigravity) {
        case .failure(.staleData, _): return "상태줄 갱신 대기"
        case .failure(_, let previous): return previous == nil ? "연결 또는 조회 오류" : "조회 실패 · 이전 데이터"
        case .success(let value):
            if case .quotas(let quotas) = value.metrics, AGYQuotaSummary.hasExhaustedBucket(quotas) {
                return "일부 버킷 소진"
            }
            return nil
        default: return nil
        }
    }

    private var agyDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch externalStore.state(for: .antigravity) {
            case .idle: Text("조회 대기 중").font(.caption).foregroundStyle(.secondary)
            case .loading: ProgressView("조회 중").controlSize(.small).font(.caption)
            case .failure(let error, let previous):
                Text(error.message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous {
                    agyMetrics(previous.metrics)
                    Text("이전 데이터 · 마지막 수신 \(CompactDateTime.string(for: previous.fetchedAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(CompactDateTime.fullString(for: previous.fetchedAt))
                }
            case .success(let value):
                agyMetrics(value.metrics)
                Text("마지막 수신 \(CompactDateTime.string(for: value.fetchedAt))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(CompactDateTime.fullString(for: value.fetchedAt))
            }
        }
    }

    @ViewBuilder
    private func agyMetrics(_ metrics: ExternalMetrics) -> some View {
        if case .quotas(let quotas) = metrics {
            if quotas.count > 2 && !needsBoundedProviderScroll {
                ScrollView { quotaRows(quotas) }
                    .frame(height: min(CGFloat(quotas.count) * 76, quotaScrollLimit))
            } else { quotaRows(quotas) }
        }
    }

    private var quotaScrollLimit: CGFloat {
        max(120, min(230, (NSScreen.main?.visibleFrame.height ?? 700) - 430))
    }

    private func quotaRows(_ quotas: [QuotaMetric]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(quotas) { quota in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(AGYQuotaLabel.displayName(for: quota.name))
                            .font(.caption.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(Int(quota.remainingPercent.rounded()))% 남음")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    ProgressView(value: quota.remainingPercent, total: 100)
                        .tint(color(for: RemainingLevel(percent: quota.remainingPercent)))
                        .accessibilityLabel("\(quota.name) 남은 한도")
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

    /// Remaining-limit bar colour. Healthy uses RAM's mint (UI colour harmony, 2026-10-29; was system green);
    /// caution and low keep the system orange and red, so a warning never looks like the normal state.
    private func color(for level: RemainingLevel) -> Color {
        switch level {
        case .healthy: HarmonyPalette.mint(dark: colorScheme == .dark).color
        case .caution: .orange
        case .low: .red
        }
    }
}

enum CompactDateTime {
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
