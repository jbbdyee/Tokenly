import AppKit
import SwiftUI

/// What the Battery popover says the battery is doing (Doc/SYSTEM-MONITOR.md §7.7-5). Charging wins over a low
/// charge, so a 12 % battery on a charger reads "충전 중", not "배터리 부족".
enum BatteryPopoverStatus: Equatable {
    /// No read yet since the widget was turned on.
    case loading
    case charging
    case onBattery
    /// On battery power at `BatteryPopoverPresentation.lowThreshold` % or less.
    case low
    /// External power and the gauge reports full (raw capacities equal).
    case full
    /// External power, not charging, not full. The reason (optimized charging, a limit, …) is not known.
    case holding
    case noBattery
    /// The power state could not be read, or the facts needed to tell the cases apart are missing.
    case unknown
}

enum BatteryPopoverPresentation {
    /// "배터리 부족" at 20 % or less, only on battery power (approved 2026-10-28).
    static let lowThreshold = 20
    /// A temperature read longer ago than this (e.g. right after wake, before the next read) is shown as "—".
    static let temperatureMaxAge: TimeInterval = 120
    /// Above this the battery-reported ratio is not a plausible capacity (e.g. a corrupt design capacity).
    static let maximumCapacityLimit = 1.5

    static let maximumCapacityHelp = "배터리가 보고한 현재 완충 용량을 설계 용량과 비교한 값입니다. macOS 시스템 설정의 배터리 성능 상태나 최대 용량 표시와 다를 수 있습니다."
    static let temperatureHelp = "배터리에서 보고한 온도입니다. macOS의 문서화되지 않은 시스템 값을 사용하므로 실제 온도와 차이가 있을 수 있습니다. 약 1분마다 갱신됩니다."

    static func status(_ power: SystemMetric<BatteryPowerState>?) -> BatteryPopoverStatus {
        switch power {
        case nil: return .loading
        case .unavailable(.noBattery)?: return .noBattery
        case .unavailable?: return .unknown
        case .available(let state)?:
            if state.isCharging == .available(true) { return .charging }
            switch state.isExternalPowerConnected {
            case .available(false):
                if let percent = state.chargePercent.value, percent <= lowThreshold { return .low }
                return .onBattery
            case .available(true):
                if state.isAtFullCapacity == .available(true) { return .full }
                if state.isCharging == .available(false), state.isAtFullCapacity == .available(false) { return .holding }
                return .unknown
            case .unavailable:
                return .unknown
            }
        }
    }

    /// SF Symbol and text; the state is never told by colour alone.
    static func badge(_ status: BatteryPopoverStatus) -> (symbol: String, text: String)? {
        switch status {
        case .loading: nil
        case .charging: ("bolt.fill", "충전 중")
        case .onBattery: ("battery.75percent", "배터리 사용 중")
        case .low: ("battery.25percent", "배터리 부족")
        case .full: ("checkmark.circle.fill", "완충됨")
        case .holding: ("pause.circle.fill", "충전 대기")
        case .noBattery: ("minus.circle", "배터리 없음")
        case .unknown: ("questionmark.circle", "상태 확인 불가")
        }
    }

    /// The big number: the menu bar Battery widget's own value, so the two never differ.
    static func headline(_ power: SystemMetric<BatteryPowerState>?) -> (value: String, note: String?) {
        if case .unavailable(.noBattery)? = power { return ("—", "배터리 없음") }
        switch SystemWidgetPresentation.battery(power).value {
        case .loading: return ("—", "측정 중")
        case .unavailable: return ("—", "확인 불가")
        case .percent(let percent): return ("\(percent)", nil)
        }
    }

    /// "완충까지 …" while charging, "남은 시간 …" on battery, "시간 계산 중" for -1; nothing otherwise (never 0 minutes,
    /// never an estimate of our own).
    static func timeLine(_ status: BatteryPopoverStatus, _ power: SystemMetric<BatteryPowerState>?) -> String? {
        guard let state = power?.value else { return nil }
        let estimate: SystemMetric<BatteryTimeEstimate>, prefix: String
        switch status {
        case .charging: (estimate, prefix) = (state.timeToFull, "완충까지")
        case .onBattery, .low: (estimate, prefix) = (state.timeToEmpty, "남은 시간")
        default: return nil
        }
        switch estimate {
        case .available(.calculating): return "시간 계산 중"
        case .available(.minutes(let minutes)): return "\(prefix) \(duration(minutes))"
        case .unavailable: return nil
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "약 \(minutes)분" }
        return minutes % 60 == 0 ? "약 \(minutes / 60)시간" : "약 \(minutes / 60)시간 \(minutes % 60)분"
    }

    /// The adapter's rated output when known; it is not the power being drawn or charged.
    static func powerLine(_ power: SystemMetric<BatteryPowerState>?) -> (symbol: String, text: String)? {
        guard let state = power?.value else { return nil }
        switch state.isExternalPowerConnected {
        case .available(true): return ("powerplug.fill", state.adapterWatts.value.map { "전원 어댑터 연결됨 · \($0)W" } ?? "전원 어댑터 연결됨")
        case .available(false): return ("battery.100", "배터리 전원")
        case .unavailable: return nil
        }
    }

    static func cycles(_ health: SystemMetric<BatteryStatus>?) -> String {
        guard let health else { return "—" }
        return health.value?.cycleCount.value.map { "\($0)회" } ?? "확인 불가"
    }

    /// Full-charge ÷ design capacity as the battery reports it, rounded, not capped at 100 % (a new battery may read
    /// slightly above). Not the System Settings figure.
    static func maximumCapacity(_ health: SystemMetric<BatteryStatus>?) -> String {
        guard let health else { return "—" }
        guard let fraction = health.value?.healthFraction.value, fraction.isFinite, fraction > 0,
              fraction <= maximumCapacityLimit else { return "확인 불가" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Whole degrees. "—" when not read yet or the last read is older than `temperatureMaxAge`; "확인 불가" when
    /// the latest read had no valid value.
    static func temperature(_ health: SystemMetric<BatteryStatus>?, readAt: Date?, now: Date) -> String {
        guard let health, let readAt else { return "—" }
        let age = now.timeIntervalSince(readAt)
        guard age >= -5, age <= temperatureMaxAge else { return "—" }
        guard let celsius = health.value?.temperatureCelsius.value else { return "확인 불가" }
        return "\(Int(celsius.rounded()))°C"
    }

    /// Soft lime / pastel green / yellow-green, soft amber when low (approved 2026-10-28). Light = deeper same hues.
    enum Palette {
        static func lime(dark: Bool) -> Color { DiskPopoverPresentation.Palette.hex(dark ? 0xCDEB9B : 0x5E8F1E) }
        static func green(dark: Bool) -> Color { DiskPopoverPresentation.Palette.hex(dark ? 0xA6E3B0 : 0x2E8A4A) }
        static func yellowGreen(dark: Bool) -> Color { DiskPopoverPresentation.Palette.hex(dark ? 0xE2EBA0 : 0x7C8A16) }
        static func low(dark: Bool) -> Color { DiskPopoverPresentation.Palette.hex(dark ? 0xF2C08A : 0xA9621C) }
    }
}

/// The Battery widget's popover (Doc/SYSTEM-MONITOR.md §7.7-5, approved 2026-10-28): the shared card with charge,
/// status, time, a level bar and the power line, then cycles, maximum capacity and temperature. It only shows what
/// the store's existing Battery job read (power-source notifications + 60 s); it reads nothing itself. Appearance
/// comes app-wide (`AppAppearanceApplier`).
struct BatteryPopoverView: View {
    @ObservedObject var store: SystemMonitorStore
    let settingsWindow: SettingsWindowManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsCapacityHelp = false
    @State private var showsTemperatureHelp = false
    @State private var windowHandle = PopoverWindowHandle()

    private var dark: Bool { colorScheme == .dark }
    private var status: BatteryPopoverStatus { BatteryPopoverPresentation.status(store.batteryPower) }
    private var accent: Color {
        status == .low ? BatteryPopoverPresentation.Palette.low(dark: dark) : BatteryPopoverPresentation.Palette.green(dark: dark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
                .padding(.horizontal, 8).padding(.top, 8)
            details
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        }
        .frame(width: 340)
        .background(.regularMaterial)
        // No reads here; the reporter only keeps the window for the settings button.
        .background(WindowVisibilityReporter(handle: windowHandle) { _ in })
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Battery").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openSettingsInFront) { Image(systemName: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("설정 열기")
                    .accessibilityLabel("설정 열기")
            }
            HStack(alignment: .firstTextBaseline) {
                let headline = BatteryPopoverPresentation.headline(store.batteryPower)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(headline.value).font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    if let note = headline.note {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
                    } else {
                        Text("%").font(.system(size: 21, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let badge = BatteryPopoverPresentation.badge(status) {
                        HStack(spacing: 4) {
                            Image(systemName: badge.symbol).font(.system(size: 10, weight: .semibold))
                            Text(badge.text)
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(accent.opacity(dark ? 0.16 : 0.13), in: Capsule())
                    }
                    if let time = BatteryPopoverPresentation.timeLine(status, store.batteryPower) {
                        Text(time).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            gauge.frame(height: 10).padding(.top, 8)
            if let power = BatteryPopoverPresentation.powerLine(store.batteryPower) {
                HStack(spacing: 5) {
                    Image(systemName: power.symbol).font(.system(size: 10))
                    Text(power.text)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 12)
    }

    /// Fill = charge. Yellow-green → lime → green, soft amber when low, a soft hatch while charging. No animation.
    private var gauge: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let percent = store.batteryPower?.value?.chargePercent.value {
                    let colors = status == .low
                        ? [BatteryPopoverPresentation.Palette.low(dark: dark), BatteryPopoverPresentation.Palette.low(dark: dark)]
                        : [BatteryPopoverPresentation.Palette.yellowGreen(dark: dark), BatteryPopoverPresentation.Palette.lime(dark: dark),
                           BatteryPopoverPresentation.Palette.green(dark: dark)]
                    ZStack {
                        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        if status == .charging {
                            BatteryChargingStripes().stroke(Color.white.opacity(dark ? 0.22 : 0.35), lineWidth: 1.5)
                        }
                    }
                    .frame(width: geometry.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                    .clipShape(Capsule())
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("배터리 정보").font(.system(size: 12, weight: .semibold)).padding(.bottom, 2)
            row("충전 사이클", BatteryPopoverPresentation.cycles(store.batteryHealth))
            row("최대 용량", BatteryPopoverPresentation.maximumCapacity(store.batteryHealth),
                help: BatteryPopoverPresentation.maximumCapacityHelp, shows: $showsCapacityHelp)
            if showsCapacityHelp { helpText(BatteryPopoverPresentation.maximumCapacityHelp) }
            // Re-evaluated while open so a value older than 120 s turns into "—" without any new read.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                row("배터리 온도", BatteryPopoverPresentation.temperature(store.batteryHealth, readAt: store.batteryReadDate, now: context.date),
                    help: BatteryPopoverPresentation.temperatureHelp, shows: $showsTemperatureHelp)
            }
            if showsTemperatureHelp { helpText(BatteryPopoverPresentation.temperatureHelp) }
        }
    }

    private func row(_ title: String, _ value: String, help: String? = nil, shows: Binding<Bool>? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            if let help, let shows {
                Button { shows.wrappedValue.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 9)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(help)
                    .accessibilityLabel("\(title) 도움말")
            }
            Spacer()
            Text(value)
        }
        .font(.system(size: 11).monospacedDigit())
    }

    private func helpText(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
    }

    /// Same as the other popovers: close the popover, then bring the settings window forward.
    private func openSettingsInFront() {
        let popover = windowHandle.window
        dismiss()
        DispatchQueue.main.async {
            if let popover, popover.isVisible { popover.orderOut(nil) }
            settingsWindow.show(openSettings: openSettings.callAsFunction)
        }
    }
}

/// The soft hatch on the level bar while charging (static).
struct BatteryChargingStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 5
        }
        return path
    }
}
