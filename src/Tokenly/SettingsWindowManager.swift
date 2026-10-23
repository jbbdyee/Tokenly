import AppKit
import SwiftUI

@MainActor
final class SettingsWindowManager {
    weak var window: NSWindow?

    func show(openSettings: () -> Void) {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct SettingsWindowCapture: NSViewRepresentable {
    let manager: SettingsWindowManager

    func makeNSView(context: Context) -> NSView {
        WindowObservingView(manager: manager)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowObservingView: NSView {
        let manager: SettingsWindowManager

        init(manager: SettingsWindowManager) {
            self.manager = manager
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            manager.window = window
        }
    }
}
