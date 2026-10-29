import AppKit
import SwiftUI

/// The GPU widget's popover, design approved 2026-10-28 (Doc/SYSTEM-MONITOR.md §7.7-3): the CPU/RAM card with the
/// GPU aurora palette. No process list (per-process GPU use is undocumented and on hold). The utilization is the
/// existing experimental measurement from `SystemMonitorStore`; chip name and core count are read once
/// (`GPUDeviceInfo.current`). Appearance comes app-wide (`AppAppearanceApplier`).
struct GPUPopoverView: View {
    @ObservedObject var store: SystemMonitorStore
    let settingsWindow: SettingsWindowManager
    var device: GPUDeviceInfo = .current
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsHelp = false
    @State private var windowHandle = PopoverWindowHandle()

    private var dark: Bool { colorScheme == .dark }
    /// Soft baby blue accent, matching the GPU graph.
    private var accent: Color {
        dark ? Color(red: 0.66, green: 0.80, blue: 0.96) : Color(red: 0.16, green: 0.42, blue: 0.74)
    }

    var body: some View {
        card
            .padding(8)
            .frame(width: 340)
            .background(.regularMaterial)
            // No process scan here; the reporter only keeps the window for the settings button.
            .background(WindowVisibilityReporter(handle: windowHandle) { _ in })
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("GPU").font(.system(size: 13, weight: .semibold))
                    Button { showsHelp.toggle() } label: {
                        HStack(spacing: 3) {
                            Text("실험적")
                            Image(systemName: "info.circle").font(.system(size: 8))
                        }
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(accent.opacity(dark ? 0.16 : 0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(SystemWidgetPresentation.gpuExperimentalHelp)
                    .accessibilityLabel("실험적 측정, 설명 보기")
                    Spacer()
                    Button(action: openSettingsInFront) { Image(systemName: "gearshape").font(.system(size: 12)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("설정 열기")
                        .accessibilityLabel("설정 열기")
                }
                HStack(alignment: .firstTextBaseline) {
                    let headline = SystemWidgetPresentation.gpuHeadline(store.gpu)
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
                        if let name = device.name { Text(name).fontWeight(.semibold) }
                        if let cores = device.coreCount { Text("GPU 코어 \(cores)개").foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 11).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                if showsHelp {
                    Text(SystemWidgetPresentation.gpuExperimentalHelp).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 14).padding(.top, 11)
            AuroraGraph(history: store.gpuHistory, palette: .gpu, fadesAreaEdges: true)
                .frame(height: 84).clipped().padding(.top, 6)
        }
    }

    /// Same as the CPU and RAM popovers: close the popover, then bring the settings window forward.
    private func openSettingsInFront() {
        let popover = windowHandle.window
        dismiss()
        DispatchQueue.main.async {
            if let popover, popover.isVisible { popover.orderOut(nil) }
            settingsWindow.show(openSettings: openSettings.callAsFunction)
        }
    }
}
