import AppKit
import OSLog
import SwiftUI

/// Starts and stops the TOP 5 process scan for a widget's popover (Doc/SYSTEM-MONITOR.md §7.7).
///
/// Both the content's appear/disappear and its window's visibility call `set`. `ProcessTopStore.setVisible` is
/// idempotent per key, so the two signals together never start a second scan, and either one alone still stops it.
/// A scan never starts for a widget that is not on (the controller also stops it when the widget is removed).
@MainActor
enum SystemPopoverVisibility {
    static let log = Logger(subsystem: "io.github.jbbdyee.tokenly", category: "SystemPopover")

    static func set(_ widget: SystemWidget, visible: Bool, controller: SystemWidgetController, source: String) {
        guard let key = widget.processTopKey, let processTop = controller.processTop else { return }
        let start = visible && controller.isInserted(widget)
        log.debug("\(widget.rawValue, privacy: .public) popover \(visible ? "open" : "closed", privacy: .public) via \(source, privacy: .public) → scan \(start ? "on" : "off", privacy: .public)")
        processTop.setVisible(key, start)
    }
}

/// The popover's own window, kept so the settings button can take the popover off screen first.
@MainActor
final class PopoverWindowHandle {
    weak var window: NSWindow?
}

/// Reports whether the hosting window is on screen: ordered out or fully covered counts as not visible.
/// (Appearance is not set here: the app applies its setting app-wide, see `AppAppearanceApplier`.)
struct WindowVisibilityReporter: NSViewRepresentable {
    var handle: PopoverWindowHandle?
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReportingView { ReportingView(handle: handle, onChange: onChange) }
    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.handle = handle
    }

    final class ReportingView: NSView {
        var onChange: (Bool) -> Void
        weak var handle: PopoverWindowHandle?
        private var observers: [NSObjectProtocol] = []

        init(handle: PopoverWindowHandle?, onChange: @escaping (Bool) -> Void) {
            self.handle = handle
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            handle?.window = window
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                self?.report()
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.onChange(false)
            })
            report()
        }

        private func report() {
            guard let window else { return }
            onChange(window.isVisible && window.occlusionState.contains(.visible))
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// The CPU widget's popover, design approved 2026-10-28 (B1 "Aurora Flow"; Doc/SYSTEM-MONITOR.md §7.7-1).
/// All values come from the app's one `SystemMonitorStore` and `ProcessTopStore`.
struct CPUPopoverView: View {
    let controller: SystemWidgetController
    @ObservedObject var store: SystemMonitorStore
    @ObservedObject var processTop: ProcessTopStore
    let icons: ProcessIconProvider
    let settingsWindow: SettingsWindowManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsHelp = false
    @State private var windowHandle = PopoverWindowHandle()

    static let help = "프로세스 CPU 사용률은 코어 1개를 100%로 계산하므로 여러 코어를 쓰면 100%를 넘을 수 있습니다. 위의 전체 CPU 사용률은 모든 코어를 기준으로 계산합니다. 권한에 따라 일부 프로세스는 표시되지 않을 수 있습니다."

    private var dark: Bool { colorScheme == .dark }
    /// Accent for the load label: the graph's own teal, never a warning colour.
    private var accent: Color {
        dark ? Color(red: 0.62, green: 0.93, blue: 0.86) : Color(red: 0.08, green: 0.58, blue: 0.50)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
                .padding(.horizontal, 8).padding(.top, 8)
            topFive
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .onAppear { SystemPopoverVisibility.set(.cpu, visible: true, controller: controller, source: "appear") }
        .onDisappear { SystemPopoverVisibility.set(.cpu, visible: false, controller: controller, source: "disappear") }
        .background(WindowVisibilityReporter(handle: windowHandle) { visible in
            SystemPopoverVisibility.set(.cpu, visible: visible, controller: controller, source: "window")
        })
        .onChange(of: processTop.snapshot) { _, snapshot in
            // The CPU and RAM popovers share the icon cache; keep both lists.
            let top = snapshot?.value
            let keys = (top?.cpu.map { ProcessIconProvider.Key(pid: $0.pid, startTicks: $0.startTicks) } ?? [])
                + (top?.memory.map { ProcessIconProvider.Key(pid: $0.pid, startTicks: $0.startTicks) } ?? [])
            icons.retain(Set(keys))
        }
    }

    // MARK: Card: header and graph

    private var usage: CPUUsage? { store.cpu?.value }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 6) {
                    Text("CPU").font(.system(size: 13, weight: .semibold))
                    if let load = SystemWidgetPresentation.cpuLoad(usage?.totalPercent) {
                        Text(load.text).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(accent.opacity(dark ? 0.16 : 0.14), in: Capsule())
                    }
                    Spacer()
                    Button(action: openSettingsInFront) {
                        Image(systemName: "gearshape").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("설정 열기")
                    .accessibilityLabel("설정 열기")
                }
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(percentText(usage?.totalPercent))
                            .font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                        if usage != nil {
                            Text("%").font(.system(size: 21, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 6) { Text("사용자").foregroundStyle(.secondary); Text(percentWithSign(usage?.userPercent)).fontWeight(.semibold) }
                        HStack(spacing: 6) { Text("시스템").foregroundStyle(.secondary); Text(percentWithSign(usage?.systemPercent)).fontWeight(.semibold) }
                    }
                    .font(.system(size: 11).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
            }
            .padding(.horizontal, 14).padding(.top, 11)
            AuroraGraph(history: store.cpuHistory, fadesAreaEdges: true)
                .frame(height: 84).clipped().padding(.top, 6)
        }
    }

    /// The popover window floats above normal windows, so a settings window opened under it stayed behind it
    /// (real-app check, 2026-10-28). Close the popover first, then bring the settings window to the front.
    private func openSettingsInFront() {
        let popover = windowHandle.window
        dismiss()
        DispatchQueue.main.async {
            // If the menu bar extra ignored the dismiss action, take its window off screen ourselves.
            if let popover, popover.isVisible { popover.orderOut(nil) }
            settingsWindow.show(openSettings: openSettings.callAsFunction)
        }
    }

    private func percentText(_ value: Double?) -> String {
        value.flatMap(SystemWidgetPresentation.usagePercent).map { "\($0)" } ?? "—"
    }

    private func percentWithSign(_ value: Double?) -> String {
        value.flatMap(SystemWidgetPresentation.usagePercent).map { "\($0)%" } ?? "—"
    }

    private var accessibilitySummary: String {
        guard let usage else { return "CPU 측정 중" }
        let load = SystemWidgetPresentation.cpuLoad(usage.totalPercent)?.text ?? ""
        return "CPU \(percentText(usage.totalPercent))%, \(load), 사용자 \(percentWithSign(usage.userPercent)), 시스템 \(percentWithSign(usage.systemPercent))"
    }

    // MARK: TOP 5

    private var topFive: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("프로세스 TOP 5").font(.system(size: 12, weight: .semibold))
                Button { showsHelp.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(Self.help)
                .accessibilityLabel("TOP 5 도움말")
                Spacer()
            }
            switch processTop.snapshot {
            case nil:
                note("불러오는 중…")
            case .unavailable?:
                note("프로세스 목록을 읽을 수 없습니다")
            case .available(let snapshot)?:
                if !snapshot.cpuHasBaseline {
                    note("측정 중…")
                } else if snapshot.cpu.isEmpty {
                    note("표시할 프로세스가 없습니다")
                } else {
                    ForEach(SystemWidgetPresentation.cpuTopRows(snapshot.cpu), id: \.pid) { row in
                        HStack(spacing: 8) {
                            ProcessIconView(image: icons.icon(pid: row.pid, startTicks: row.startTicks))
                            Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                .help(row.name)
                            Spacer(minLength: 8)
                            Text(row.percentText).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .fixedSize().layoutPriority(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if showsHelp {
                Text(Self.help).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// A process's app icon, or the one generic icon for processes without an app.
struct ProcessIconView: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "gearshape.2.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
