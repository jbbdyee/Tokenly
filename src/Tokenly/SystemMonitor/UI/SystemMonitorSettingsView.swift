import SwiftUI

/// The settings tab for the system widgets: one toggle each, bound through `SystemWidgetController` like the menu
/// bar items, so the toggle, the item, the stored choice and the measurement never disagree.
///
/// Opening the tab (every time it appears: window opened on it, or switched to it) calls
/// `recheckUnsupportedWidgets()`, which probes only widgets currently unsupported; when all are supported it does
/// no work at all.
struct SystemMonitorSettingsView: View {
    @ObservedObject var controller: SystemWidgetController

    var body: some View {
        // Compact spacing: the settings window is fixed at 440 × 300 pt.
        VStack(alignment: .leading, spacing: 6) {
            Text("시스템 모니터").font(.headline)
            Text("메뉴 막대에 표시할 항목을 고릅니다. 켠 항목만 측정합니다.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach([SystemWidget.cpu, .memory, .disk, .gpu, .battery]) { widget in
                VStack(alignment: .leading, spacing: 2) {
                    SystemWidgetSwitchRow(
                        title: widget == .battery ? "배터리" : widget.title,
                        isOn: controller.binding(for: widget),
                        isSupported: controller.isSupported(widget)
                    )
                    if let reason = controller.support[widget]?.reasonText {
                        Text(reason).font(.caption2).foregroundStyle(.secondary)
                    } else if widget == .gpu {
                        Text("실험적: Apple이 문서화하지 않은 값을 읽은 추정 사용률입니다.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("메뉴 막대가 가득 차면 켠 항목이 보이지 않을 수 있습니다. 보이지 않아도 측정은 계속됩니다.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onAppear { controller.recheckUnsupportedWidgets() }
    }
}

/// Keeps the full-width label and the native switch's original layout/hit area while shrinking only its drawing.
private struct SystemWidgetSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    let isSupported: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isSupported else { return }
                    isOn.toggle()
                }
                .accessibilityHidden(true)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.85)
                .frame(width: 54, height: 24)
                .contentShape(Rectangle())
                .accessibilityLabel(title)
        }
        .disabled(!isSupported)
    }
}

/// "시스템 위젯 표시 방식" in the 테마 tab. Applies to CPU·RAM·Disk·GPU; AI widgets and Battery are not affected.
struct SystemWidgetLayoutPicker: View {
    @ObservedObject var controller: SystemWidgetController

    var body: some View {
        Picker("시스템 위젯 표시 방식", selection: controller.layoutBinding()) {
            ForEach(SystemWidgetLayout.allCases) { layout in
                Text(layout.title).tag(layout)
            }
        }
        .pickerStyle(.radioGroup)
        Text("CPU·RAM·Disk·GPU에 적용됩니다. AI 위젯과 배터리는 바뀌지 않습니다.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// "배터리 표시 스타일" in the 테마 tab. Only the Battery widget changes; its numbers and bolt stay the same.
struct BatteryFramePicker: View {
    @ObservedObject var controller: SystemWidgetController

    var body: some View {
        Picker("배터리 표시 스타일", selection: controller.batteryFrameBinding()) {
            ForEach(BatteryFrameStyle.allCases) { frame in
                Text(frame.title).tag(frame)
            }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
    }
}
