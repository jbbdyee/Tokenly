import AppKit
import SwiftUI

/// Remembers each widget's last menu bar image. A store publish re-evaluates every label, but a widget's image is
/// rendered again only when its own display value, the menu bar appearance, the pixel scale, (CPU·RAM·Disk·GPU
/// only) the display style or (Battery only) the battery frame changed.
@MainActor
final class SystemWidgetImageCache {
    struct Key: Equatable {
        let display: SystemWidgetDisplay
        let dark: Bool
        let scale: Int
        /// Already resolved per widget (`applied(to:)`), so Battery's key never changes with the style.
        let style: SystemWidgetLayout
        /// Resolved the same way: only Battery's key changes with the frame.
        let frame: BatteryFrameStyle
    }

    private var entries: [SystemWidget: (key: Key, image: NSImage)] = [:]
    /// Renders per widget, for tests and cost checks.
    private(set) var renderCount: [SystemWidget: Int] = [:]

    func image(for display: SystemWidgetDisplay, dark: Bool, scale: Int, style: SystemWidgetLayout = .unified,
               frame: BatteryFrameStyle = .minimal) -> NSImage? {
        let style = style.applied(to: display.widget)
        let frame = frame.applied(to: display.widget)
        let key = Key(display: display, dark: dark, scale: scale, style: style, frame: frame)
        if let entry = entries[display.widget], entry.key == key { return entry.image }
        guard let image = MenuBarSystemImage.make(display, dark: dark, scale: scale, style: style, frame: frame) else { return nil }
        entries[display.widget] = (key, image)
        renderCount[display.widget, default: 0] += 1
        return image
    }
}

/// One system widget's menu bar label. Only these labels observe the store, so its 1 s publishes never re-evaluate
/// the app's scenes (and so never touch the AI labels).
struct SystemWidgetLabel: View {
    let widget: SystemWidget
    @ObservedObject var store: SystemMonitorStore
    let cache: SystemWidgetImageCache
    /// Display style from `SystemWidgetController.layout`, passed down by the scene.
    var style: SystemWidgetLayout = .unified
    /// Battery look from `SystemWidgetController.batteryFrame`; ignored by the other widgets.
    var frame: BatteryFrameStyle = .minimal
    /// The menu bar's own appearance, as the AI labels use it.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let display = SystemWidgetPresentation.display(widget, store: store)
        // At least 2x, like `MenuBarNumericImage.make`.
        let scale = max(2, Int(displayScale.rounded()))
        if let image = cache.image(for: display, dark: colorScheme == .dark, scale: scale, style: style, frame: frame) {
            Image(nsImage: image)
                .accessibilityLabel(display.accessibilityText)
        } else {
            Text(display.text)
                .monospacedDigit()
                .accessibilityLabel(display.accessibilityText)
        }
    }
}

/// Placeholder menu until the 6-4 popovers: the current value and a way to the settings tab.
struct SystemWidgetMenu: View {
    let widget: SystemWidget
    @ObservedObject var store: SystemMonitorStore

    var body: some View {
        Text(SystemWidgetPresentation.display(widget, store: store).accessibilityText)
        Divider()
        SettingsLink {
            Text("시스템 모니터 설정…")
        }
    }
}

/// The five system widgets as independent menu bar items (Doc/SYSTEM-MONITOR.md §7.2).
///
/// Each item's `isInserted` is `controller.binding(for:)`, the same binding the settings toggle uses: inserting,
/// removing (also ⌘-dragging out of the menu bar) and restoring all go through `SystemWidgetController.setInserted`.
/// The UI never calls `SystemMonitorStore.setEnabled` itself. This scene re-evaluates when the controller publishes,
/// which happens only on on/off, support, display style and battery frame changes.
struct SystemMonitorMenuBarScenes: Scene {
    /// Must be observed. As a plain `let`, SwiftUI kept this body's earlier `isInserted == false` after a toggle,
    /// pushed it to the status item, and its KVO write-back turned the widget off again (6-3 GUI bug,
    /// Doc/HANDOFF.md).
    @ObservedObject var controller: SystemWidgetController
    let cache: SystemWidgetImageCache
    /// For the CPU popover (6-4b): settings access and process icons. Appearance comes app-wide
    /// (`AppAppearanceApplier`).
    let settingsWindow: SettingsWindowManager
    let processIcons: ProcessIconProvider

    var body: some Scene {
        cpuItem()
        memoryItem()
        diskItem()
        gpuItem()
        batteryItem()
    }

    /// CPU opens its detail popover (window style, like the AI item). Since 6-4f every system widget has one.
    private func cpuItem() -> some Scene {
        MenuBarExtra(isInserted: controller.binding(for: .cpu)) {
            if let processTop = controller.processTop {
                CPUPopoverView(controller: controller, store: controller.store, processTop: processTop,
                               icons: processIcons, settingsWindow: settingsWindow)
            } else {
                SystemWidgetMenu(widget: .cpu, store: controller.store)
            }
        } label: {
            SystemWidgetLabel(widget: .cpu, store: controller.store, cache: cache, style: controller.layout,
                              frame: controller.batteryFrame)
        }
        .menuBarExtraStyle(.window)
    }

    /// RAM opens its detail popover (6-4c), the same way as CPU.
    private func memoryItem() -> some Scene {
        MenuBarExtra(isInserted: controller.binding(for: .memory)) {
            if let processTop = controller.processTop {
                RAMPopoverView(controller: controller, store: controller.store, processTop: processTop,
                               icons: processIcons, settingsWindow: settingsWindow)
            } else {
                SystemWidgetMenu(widget: .memory, store: controller.store)
            }
        } label: {
            SystemWidgetLabel(widget: .memory, store: controller.store, cache: cache, style: controller.layout,
                              frame: controller.batteryFrame)
        }
        .menuBarExtraStyle(.window)
    }

    /// GPU opens its detail popover (6-4d). No process scan.
    private func diskItem() -> some Scene {
        MenuBarExtra(isInserted: controller.binding(for: .disk)) {
            DiskPopoverView(store: controller.store, settingsWindow: settingsWindow)
        } label: {
            SystemWidgetLabel(widget: .disk, store: controller.store, cache: cache, style: controller.layout,
                              frame: controller.batteryFrame)
        }
        .menuBarExtraStyle(.window)
    }

    private func batteryItem() -> some Scene {
        MenuBarExtra(isInserted: controller.binding(for: .battery)) {
            BatteryPopoverView(store: controller.store, settingsWindow: settingsWindow)
        } label: {
            SystemWidgetLabel(widget: .battery, store: controller.store, cache: cache, style: controller.layout,
                              frame: controller.batteryFrame)
        }
        .menuBarExtraStyle(.window)
    }

    private func gpuItem() -> some Scene {
        MenuBarExtra(isInserted: controller.binding(for: .gpu)) {
            GPUPopoverView(store: controller.store, settingsWindow: settingsWindow)
        } label: {
            SystemWidgetLabel(widget: .gpu, store: controller.store, cache: cache, style: controller.layout,
                              frame: controller.batteryFrame)
        }
        .menuBarExtraStyle(.window)
    }

    private func item(_ widget: SystemWidget) -> some Scene {
        MenuBarExtra(isInserted: controller.binding(for: widget)) {
            SystemWidgetMenu(widget: widget, store: controller.store)
        } label: {
            SystemWidgetLabel(widget: widget, store: controller.store, cache: cache, style: controller.layout,
                              frame: controller.batteryFrame)
        }
    }
}
