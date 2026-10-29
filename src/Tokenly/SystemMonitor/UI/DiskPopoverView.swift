import AppKit
import SwiftUI

/// The APFS space of the container behind `/`, split into three parts that add up to the total exactly
/// (Doc/SYSTEM-MONITOR.md §7.7-4). All from one `DiskUsage` read, so the parts never mix different moments or scopes.
///
/// - used: total − available (macOS's estimate, `availableForImportantUsageBytes`): the menu bar basis.
/// - reclaimable: available − free now. What macOS says it could free when needed (caches, local snapshots, …);
///   an estimate, **not** an exact purgeable total.
/// - freeNow: `availableBytes`, free right now without deleting anything.
struct DiskSpaceBreakdown: Equatable {
    let total: UInt64
    let used: UInt64
    let reclaimable: UInt64
    let freeNow: UInt64

    var available: UInt64 { reclaimable + freeNow }

    /// `nil` when macOS gave no estimate or the values contradict each other (estimate below the free space, or
    /// above the total): then there is no honest three-way split.
    static func make(_ disk: DiskUsage) -> DiskSpaceBreakdown? {
        guard disk.totalBytes > 0, disk.availableBytes <= disk.totalBytes,
              let important = disk.availableForImportantUsageBytes.value,
              important >= disk.availableBytes, important <= disk.totalBytes else { return nil }
        return DiskSpaceBreakdown(total: disk.totalBytes, used: disk.totalBytes - important,
                                  reclaimable: important - disk.availableBytes, freeNow: disk.availableBytes)
    }

    /// Bar widths, from the raw bytes (never from rounded text).
    var fractions: (used: Double, reclaimable: Double, freeNow: Double) {
        let total = Double(self.total)
        return (Double(used) / total, Double(reclaimable) / total, Double(freeNow) / total)
    }
}

enum DiskPopoverPresentation {
    static let help = "사용 가능 공간에는 macOS가 필요할 때 확보할 수 있는 공간이 포함될 수 있습니다. 이 값은 시스템 추정치이며 APFS 공유 공간, 캐시, 로컬 스냅샷 등의 영향을 받을 수 있습니다. Finder나 시스템 설정과 계산 시점 및 기준에 따라 차이가 날 수 있습니다."

    /// The big number: the menu bar Disk widget's own value and rounding (§7.5), so the two never differ.
    static func headline(_ metric: SystemMetric<DiskUsage>?) -> (value: String, note: String?) {
        switch SystemWidgetPresentation.disk(metric).value {
        case .loading: ("—", "측정 중")
        case .unavailable: ("—", "확인 불가")
        case .percent(let percent): ("\(percent)", nil)
        }
    }

    /// Decimal units, like Finder and System Settings: 1 GB = 10⁹ bytes, 1 TB = 10¹² bytes.
    static func size(_ bytes: UInt64) -> String {
        bytes >= 1_000_000_000_000
            ? String(format: "%.2f TB", Double(bytes) / 1e12)
            : String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    /// Current speed (1 MB = 10⁶ bytes), the one formatter for read and write. A measured 0 stays "0 MB/s", a
    /// non-zero speed below 0.1 MB/s is "<0.1 MB/s"; no reading is "—".
    static func rate(_ megabytesPerSecond: Double?) -> String {
        guard let value = megabytesPerSecond, value.isFinite, value >= 0 else { return "—" }
        if value >= 1000 { return String(format: "%.2f GB/s", value / 1000) }
        if value >= 10 { return String(format: "%.0f MB/s", value) }
        if value >= 0.1 { return String(format: "%.1f MB/s", value) }
        return value > 0 ? "<0.1 MB/s" : "0 MB/s"
    }

    /// The graph's top, labelled as a scale and not as a measured maximum.
    static func scaleLabel(_ megabytesPerSecond: Double) -> String {
        megabytesPerSecond >= 1000
            ? "눈금 상한 \(Int(megabytesPerSecond / 1000)) GB/s"
            : "눈금 상한 \(Int(megabytesPerSecond)) MB/s"
    }

    /// Text next to "읽기"/"쓰기": the speed, or why there is none.
    static func activityValue(_ metric: SystemMetric<DiskActivityRate>?, write: Bool) -> String {
        switch metric {
        case nil, .unavailable(.awaitingBaseline)?: "측정 중"
        case .unavailable?: "확인 불가"
        case .available(let rate)?: Self.rate(write ? rate.writeMBps : rate.readMBps)
        }
    }

    /// P1 aqua · mint (approved 2026-10-28): dark = the approved hex, light = deeper versions of the same hues.
    enum Palette {
        static func read(dark: Bool) -> Color { hex(dark ? 0x9FE3E6 : 0x1F8A96) }
        static func write(dark: Bool) -> Color { hex(dark ? 0xB2E8C8 : 0x2E9467) }
        static func blue(dark: Bool) -> Color { hex(dark ? 0xA7C9F2 : 0x3B76B8) }

        static func hex(_ value: UInt32) -> Color {
            Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
    }
}

/// The Disk widget's popover, design B + P1 approved 2026-10-28 (Doc/SYSTEM-MONITOR.md §7.7-4): the CPU/RAM/GPU card
/// with the space composition, then live read and write graphs. Everything comes from the app's one
/// `SystemMonitorStore` (no polling of its own). Appearance comes app-wide (`AppAppearanceApplier`).
struct DiskPopoverView: View {
    @ObservedObject var store: SystemMonitorStore
    let settingsWindow: SettingsWindowManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsHelp = false
    @State private var windowHandle = PopoverWindowHandle()

    private var dark: Bool { colorScheme == .dark }
    private var accent: Color { DiskPopoverPresentation.Palette.read(dark: dark) }
    private var usage: DiskUsage? { store.disk?.value }
    private var breakdown: DiskSpaceBreakdown? { usage.flatMap(DiskSpaceBreakdown.make) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
                .padding(.horizontal, 8).padding(.top, 8)
            activity
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        }
        .frame(width: 340)
        .background(.regularMaterial)
        // No sampling here; the reporter only keeps the window for the settings button.
        .background(WindowVisibilityReporter(handle: windowHandle) { _ in })
    }

    // MARK: Card: space

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Disk").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openSettingsInFront) { Image(systemName: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("설정 열기")
                    .accessibilityLabel("설정 열기")
            }
            HStack(alignment: .firstTextBaseline) {
                let headline = DiskPopoverPresentation.headline(store.disk)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(headline.value).font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    if let note = headline.note {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
                    } else {
                        Text("%").font(.system(size: 21, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if let breakdown { Text("\(DiskPopoverPresentation.size(breakdown.used)) 사용").fontWeight(.semibold) }
                    if let usage { Text("전체 \(DiskPopoverPresentation.size(usage.totalBytes))").foregroundStyle(.secondary) }
                }
                .font(.system(size: 11).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            bar.frame(height: 8).padding(.top, 8)
            VStack(alignment: .leading, spacing: 3) {
                legend(AnyView(Capsule().fill(usedGradient)), "사용 중", breakdown.map { DiskPopoverPresentation.size($0.used) })
                legend(AnyView(stripes.clipShape(Capsule())), "필요 시 확보 가능 (추정)",
                       breakdown.map { DiskPopoverPresentation.size($0.reclaimable) }, info: true)
                legend(AnyView(Capsule().fill(.quaternary)), "지금 비어 있음", usage.map { DiskPopoverPresentation.size($0.availableBytes) })
                Divider().padding(.vertical, 2)
                HStack {
                    Text("사용 가능").fontWeight(.semibold)
                    Spacer()
                    Text(breakdown.map { DiskPopoverPresentation.size($0.available) } ?? "—").fontWeight(.semibold)
                }
                .font(.system(size: 11).monospacedDigit())
            }
            .padding(.top, 9)
            if showsHelp {
                Text(DiskPopoverPresentation.help).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
            if let summary = store.diskDevice?.summary {
                // A little brighter than the approved preview's tertiary in dark mode, for legibility.
                Text(summary).font(.system(size: 10))
                    .foregroundStyle(dark ? AnyShapeStyle(Color.primary.opacity(0.42)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 12)
    }

    private var usedGradient: LinearGradient {
        LinearGradient(colors: [accent, DiskPopoverPresentation.Palette.blue(dark: dark)], startPoint: .leading, endPoint: .trailing)
    }

    private var stripes: some View {
        ZStack { accent.opacity(0.18); DiskStripes().stroke(accent.opacity(0.65), lineWidth: 1) }
    }

    /// Used | may be freed (estimate, striped) | free now (the neutral track). Widths from raw bytes.
    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let fractions = breakdown?.fractions {
                    HStack(spacing: 0) {
                        usedGradient.frame(width: geometry.size.width * fractions.used)
                        stripes.frame(width: geometry.size.width * fractions.reclaimable).clipped()
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func legend(_ swatch: AnyView, _ title: String, _ value: String?, info: Bool = false) -> some View {
        HStack(spacing: 6) {
            swatch.frame(width: 10, height: 6)
            Text(title).foregroundStyle(.secondary)
            if info {
                Button { showsHelp.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 9)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(DiskPopoverPresentation.help)
                    .accessibilityLabel("사용 가능 공간 도움말")
            }
            Spacer()
            Text(value ?? "—")
        }
        .font(.system(size: 11).monospacedDigit())
    }

    // MARK: Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("디스크 활동").font(.system(size: 12, weight: .semibold))
                Text("최근 60초").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
            DiskActivityLane(title: "읽기", value: DiskPopoverPresentation.activityValue(store.diskActivity, write: false),
                             history: store.diskReadHistory, color: DiskPopoverPresentation.Palette.read(dark: dark))
            DiskActivityLane(title: "쓰기", value: DiskPopoverPresentation.activityValue(store.diskActivity, write: true),
                             history: store.diskWriteHistory, color: DiskPopoverPresentation.Palette.write(dark: dark))
        }
    }

    /// Same as the CPU, RAM and GPU popovers: close the popover, then bring the settings window forward.
    private func openSettingsInFront() {
        let popover = windowHandle.window
        dismiss()
        DispatchQueue.main.async {
            if let popover, popover.isVisible { popover.orderOut(nil) }
            settingsWindow.show(openSettings: openSettings.callAsFunction)
        }
    }
}

/// One speed graph (read or write): its own colour and its own scale (`DiskActivityScale`), so heights of the two
/// lanes are not comparable; the current value is written out. Reuses the Aurora curve and gap rules (M1).
struct DiskActivityLane: View {
    let title: String
    let value: String
    let history: SystemMetricHistory
    let color: Color

    var body: some View {
        let top = DiskActivityScale.upperBound(history)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
            ZStack(alignment: .topTrailing) {
                DiskActivityGraph(history: Self.scaled(history, top: top), color: color).frame(height: 38)
                Text(DiskPopoverPresentation.scaleLabel(top)).font(.system(size: 8.5).monospacedDigit())
                    .foregroundStyle(.tertiary).padding(.trailing, 2)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 0.5) }
        }
    }

    /// MB/s → percent of the lane's scale, keeping gaps (`nil`) and time stamps.
    static func scaled(_ history: SystemMetricHistory, top: Double) -> SystemMetricHistory {
        var scaled = SystemMetricHistory(capacity: history.capacity)
        for point in history.points { scaled.append(point.value.map { $0 / top * 100 }, at: point.date) }
        return scaled
    }
}

/// A single-colour Aurora line (glow, soft fill, line, current point). Gaps follow `AuroraGraphLayout` (M1).
struct DiskActivityGraph: View {
    let history: SystemMetricHistory
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let layout = AuroraGraphLayout(history: history, size: geometry.size)
            ZStack(alignment: .topLeading) {
                if layout.segments.isEmpty {
                    Text("측정 데이터 없음").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, points in
                    let line = AuroraCurve.path(points)
                    let area = Self.area(line, points, bottom: geometry.size.height)
                    area.fill(color).opacity(colorScheme == .dark ? 0.22 : 0.16).blur(radius: 6)
                    area.fill(LinearGradient(colors: [color.opacity(0.26), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(color, style: StrokeStyle(lineWidth: AuroraPalette.lineWidth, lineCap: .round, lineJoin: .round))
                    if points.count == 1, let point = points.first {
                        Circle().fill(color).frame(width: 3, height: 3).position(point)
                    }
                }
                if let current = layout.current {
                    ZStack {
                        Circle().fill(color.opacity(0.25)).frame(width: 9, height: 9)
                        Circle().fill(color).frame(width: 4, height: 4)
                    }
                    .position(current)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func area(_ line: Path, _ points: [CGPoint], bottom: CGFloat) -> Path {
        var area = line
        guard let first = points.first, let last = points.last else { return area }
        area.addLine(to: CGPoint(x: last.x, y: bottom))
        area.addLine(to: CGPoint(x: first.x, y: bottom))
        area.closeSubpath()
        return area
    }
}

/// Diagonal hatching for the estimated "may be freed" part.
struct DiskStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 4
        }
        return path
    }
}
