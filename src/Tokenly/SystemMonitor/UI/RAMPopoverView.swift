import AppKit
import SwiftUI

/// The RAM widget's popover, design approved 2026-10-28 (Doc/SYSTEM-MONITOR.md §7.7-2): the CPU popover's card and
/// B1 graph, plus the memory composition bar. Values come from the app's one `SystemMonitorStore` and
/// `ProcessTopStore`; appearance comes app-wide (`AppAppearanceApplier`), never per window.
struct RAMPopoverView: View {
    let controller: SystemWidgetController
    @ObservedObject var store: SystemMonitorStore
    @ObservedObject var processTop: ProcessTopStore
    let icons: ProcessIconProvider
    let settingsWindow: SettingsWindowManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsAvailableHelp = false
    @State private var showsTopHelp = false
    @State private var windowHandle = PopoverWindowHandle()

    /// Confirmed palette.
    static let appColor = Color(red: 0xA5 / 255, green: 0xE2 / 255, blue: 0xD7 / 255)
    static let wiredColor = Color(red: 0xA8 / 255, green: 0xCD / 255, blue: 0xF4 / 255)
    static let compressedColor = Color(red: 0xC5 / 255, green: 0xB3 / 255, blue: 0xEE / 255)
    static let availableColor = Color(red: 0x73 / 255, green: 0x77 / 255, blue: 0x82 / 255)

    /// Pressure badge colours (approved 2026-10-28). Dark values as given; light values keep the same pastel hues
    /// with text dark enough for WCAG AA (≥ 4.5:1) on its own background. Unknown is neutral grey, never mint.
    static func pressureBadge(_ pressure: SystemMetric<MemoryPressure>?, dark: Bool) -> (text: AuroraPalette.RGB, background: AuroraPalette.RGB) {
        func rgb(_ hex: UInt32) -> AuroraPalette.RGB {
            AuroraPalette.RGB(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
        }
        switch (pressure?.value, dark) {
        case (.normal?, true): return (rgb(0xA5E2D7), rgb(0x254A46))
        case (.warning?, true): return (rgb(0xF4D39A), rgb(0x53452F))
        case (.critical?, true): return (rgb(0xF2B1C4), rgb(0x593A46))
        case (nil, true): return (rgb(0xC1C4CD), rgb(0x41444B))
        case (.normal?, false): return (rgb(0x1F6B5E), rgb(0xD9F2EC))
        case (.warning?, false): return (rgb(0x7A5212), rgb(0xFAEBCF))
        case (.critical?, false): return (rgb(0x8E3553), rgb(0xF8DEE6))
        case (nil, false): return (rgb(0x4E525B), rgb(0xE6E7EB))
        }
    }

    private var dark: Bool { colorScheme == .dark }
    private var memory: MemoryUsage? { store.memory?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
                .padding(.horizontal, 8).padding(.top, 8)
            topFive
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .onAppear { SystemPopoverVisibility.set(.memory, visible: true, controller: controller, source: "appear") }
        .onDisappear { SystemPopoverVisibility.set(.memory, visible: false, controller: controller, source: "disappear") }
        .background(WindowVisibilityReporter(handle: windowHandle) { visible in
            SystemPopoverVisibility.set(.memory, visible: visible, controller: controller, source: "window")
        })
        .onChange(of: processTop.snapshot) { _, snapshot in
            // The CPU and RAM popovers share the icon cache; keep both lists.
            let top = snapshot?.value
            let keys = (top?.cpu.map { ProcessIconProvider.Key(pid: $0.pid, startTicks: $0.startTicks) } ?? [])
                + (top?.memory.map { ProcessIconProvider.Key(pid: $0.pid, startTicks: $0.startTicks) } ?? [])
            icons.retain(Set(keys))
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("RAM").font(.system(size: 13, weight: .semibold))
                    if store.memoryPressure != nil {
                        let badge = Self.pressureBadge(store.memoryPressure, dark: dark)
                        Text("메모리 압박 \(SystemWidgetPresentation.memoryPressureText(store.memoryPressure))")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(badge.text.color)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(badge.background.color, in: Capsule())
                            .help("macOS가 보고하는 메모리 압박 수준입니다. 사용률과는 다른 지표입니다.")
                    }
                    Spacer()
                    Button(action: openSettingsInFront) { Image(systemName: "gearshape").font(.system(size: 12)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("설정 열기")
                        .accessibilityLabel("설정 열기")
                }
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(memory.flatMap { SystemWidgetPresentation.usagePercent($0.usedFraction * 100) }.map { "\($0)" } ?? "—")
                            .font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                        if memory != nil {
                            Text("%").font(.system(size: 21, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let memory {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(SystemWidgetPresentation.processMemoryText(memory.usedBytes)) 사용").fontWeight(.semibold)
                            Text("전체 \(SystemWidgetPresentation.processMemoryText(memory.totalBytes))").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11).monospacedDigit())
                    }
                }
                if let memory {
                    let parts = SystemWidgetPresentation.memoryComposition(memory)
                    MemoryCompositionBar(parts: parts).padding(.top, 8)
                    legend(parts).padding(.top, 8)
                    if showsAvailableHelp { helpText(SystemWidgetPresentation.memoryAvailableHelp).padding(.top, 6) }
                }
            }
            .padding(.horizontal, 14).padding(.top, 11)
            AuroraGraph(history: store.memoryHistory, fadesAreaEdges: true)
                .frame(height: 84).clipped().padding(.top, 8)
        }
    }

    private func legend(_ parts: [SystemWidgetPresentation.MemoryPart]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(stride(from: 0, to: parts.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(parts[start..<min(start + 2, parts.count)], id: \.title) { part in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Self.color(part.kind, legend: true)).frame(width: 8, height: 8)
                            Text(part.title).font(.system(size: 11)).foregroundStyle(.secondary)
                            if part.kind == .available {
                                Button { showsAvailableHelp.toggle() } label: {
                                    Image(systemName: "info.circle").font(.system(size: 9))
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.tertiary)
                                .help(SystemWidgetPresentation.memoryAvailableHelp)
                                .accessibilityLabel("사용 가능 설명")
                            }
                            Spacer(minLength: 4)
                            Text(SystemWidgetPresentation.processMemoryText(part.bytes))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                        .frame(width: 142)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    static func color(_ kind: SystemWidgetPresentation.MemoryPart.Kind, legend: Bool = false) -> Color {
        switch kind {
        case .app: appColor
        case .wired: wiredColor
        case .compressed: compressedColor
        case .available: availableColor.opacity(legend ? 0.7 : 0.45)
        }
    }

    /// Same as the CPU popover: the popover floats above normal windows, so close it first, then bring the
    /// settings window forward.
    private func openSettingsInFront() {
        let popover = windowHandle.window
        dismiss()
        DispatchQueue.main.async {
            if let popover, popover.isVisible { popover.orderOut(nil) }
            settingsWindow.show(openSettings: openSettings.callAsFunction)
        }
    }

    // MARK: TOP 5

    private var topFive: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("프로세스 TOP 5").font(.system(size: 12, weight: .semibold))
                Button { showsTopHelp.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 10)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(SystemWidgetPresentation.memoryTopHelp)
                    .accessibilityLabel("TOP 5 도움말")
                Spacer()
            }
            switch processTop.snapshot {
            case nil:
                note("불러오는 중…")
            case .unavailable?:
                note("프로세스 목록을 읽을 수 없습니다")
            case .available(let snapshot)?:
                if snapshot.memory.isEmpty {
                    note("표시할 프로세스가 없습니다")
                } else {
                    ForEach(SystemWidgetPresentation.memoryTopRows(snapshot.memory), id: \.pid) { row in
                        HStack(spacing: 8) {
                            ProcessIconView(image: icons.icon(pid: row.pid, startTicks: row.startTicks))
                            Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                .help(row.name)
                            Spacer(minLength: 8)
                            Text(row.bytesText).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .fixedSize().layoutPriority(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if showsTopHelp { helpText(SystemWidgetPresentation.memoryTopHelp) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func helpText(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 8 pt bar, rounded ends, 2 pt gaps. Widths are the parts' exact fractions of total memory (a 3 pt minimum keeps a
/// tiny non-zero part visible; a zero part is not drawn).
struct MemoryCompositionBar: View {
    let parts: [SystemWidgetPresentation.MemoryPart]

    var body: some View {
        GeometryReader { geometry in
            let visible = parts.filter { $0.bytes > 0 }
            let gap: CGFloat = 2
            let usable = max(0, geometry.size.width - gap * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, part in
                    let first = index == 0, last = index == visible.count - 1
                    UnevenRoundedRectangle(topLeadingRadius: first ? 4 : 1.5, bottomLeadingRadius: first ? 4 : 1.5,
                                           bottomTrailingRadius: last ? 4 : 1.5, topTrailingRadius: last ? 4 : 1.5)
                        .fill(part.kind == .available ? RAMPopoverView.color(.available) : RAMPopoverView.color(part.kind).opacity(0.95))
                        .frame(width: max(3, usable * CGFloat(part.fraction)))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
