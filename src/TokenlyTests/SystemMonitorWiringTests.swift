import AppKit
import SwiftUI
import XCTest
@testable import Tokenly

/// 6-3 wiring: image re-render rules, Store → label values, real support probes, settings text.
@MainActor
final class SystemMonitorWiringTests: XCTestCase {
    // MARK: Image cache (render only when a widget's own display, appearance or scale changes)

    func testSameDisplayIsNotRenderedAgain() {
        let cache = SystemWidgetImageCache()
        let display = SystemWidgetDisplay(widget: .cpu, value: .percent(24))
        let first = cache.image(for: display, dark: false, scale: 2)
        let second = cache.image(for: display, dark: false, scale: 2)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "The same NSImage is reused")
        XCTAssertEqual(cache.renderCount[.cpu], 1)
    }

    func testOneWidgetChangingDoesNotRenderTheOthers() {
        let cache = SystemWidgetImageCache()
        let others: [SystemWidgetDisplay] = [
            .init(widget: .memory, value: .percent(71)), .init(widget: .disk, value: .percent(73)),
            .init(widget: .gpu, value: .unavailable), .init(widget: .battery, value: .percent(82)),
        ]
        for display in others { _ = cache.image(for: display, dark: false, scale: 2) }
        for percent in [24, 25, 26] {
            _ = cache.image(for: .init(widget: .cpu, value: .percent(percent)), dark: false, scale: 2)
            // A store publish re-evaluates every label; the others ask again with unchanged values.
            for display in others { _ = cache.image(for: display, dark: false, scale: 2) }
        }
        XCTAssertEqual(cache.renderCount[.cpu], 3)
        for display in others { XCTAssertEqual(cache.renderCount[display.widget], 1, "\(display.widget) re-rendered") }
    }

    func testAppearanceScaleAndChargingChangesRenderAgain() {
        let cache = SystemWidgetImageCache()
        let battery = SystemWidgetDisplay(widget: .battery, value: .percent(82))
        _ = cache.image(for: battery, dark: false, scale: 2)
        _ = cache.image(for: battery, dark: true, scale: 2)
        _ = cache.image(for: battery, dark: true, scale: 3)
        _ = cache.image(for: SystemWidgetDisplay(widget: .battery, value: .percent(82), bolt: .charging), dark: true, scale: 3)
        XCTAssertEqual(cache.renderCount[.battery], 4)
        let image = cache.image(for: battery, dark: false, scale: 2)
        XCTAssertEqual(image?.isTemplate, false, "Non-template so the green bolt keeps its colour")
        XCTAssertEqual(image?.size, MenuBarSystemImage.size(battery))
    }

    /// Switching the display style redraws only the CPU·RAM·Disk·GPU images; Battery reuses its image. The same
    /// style again draws nothing.
    func testStyleChangeRendersOnlyTheTwoRowWidgets() {
        let cache = SystemWidgetImageCache()
        let displays: [SystemWidgetDisplay] = [
            .init(widget: .cpu, value: .percent(24)), .init(widget: .memory, value: .percent(71)),
            .init(widget: .disk, value: .percent(73)), .init(widget: .gpu, value: .unavailable),
            .init(widget: .battery, value: .percent(82), bolt: .charging),
        ]
        var batteryImages: [NSImage?] = []
        for style in [SystemWidgetLayout.unified, .unified, .split, .split, .unified] {
            for display in displays {
                let image = cache.image(for: display, dark: false, scale: 2, style: style)
                if display.widget == .battery { batteryImages.append(image) }
            }
        }
        for widget in [SystemWidget.cpu, .memory, .disk, .gpu] {
            XCTAssertEqual(cache.renderCount[widget], 3, "\(widget): unified, split, unified")
        }
        XCTAssertEqual(cache.renderCount[.battery], 1, "Battery is not redrawn for a style change")
        XCTAssertTrue(batteryImages.allSatisfy { $0 === batteryImages[0] })
    }

    /// Switching the battery frame redraws only Battery; the other widgets reuse their images.
    func testBatteryFrameChangeRendersOnlyBattery() {
        let cache = SystemWidgetImageCache()
        let displays: [SystemWidgetDisplay] = [
            .init(widget: .cpu, value: .percent(24)), .init(widget: .memory, value: .percent(71)),
            .init(widget: .disk, value: .percent(73)), .init(widget: .gpu, value: .percent(9)),
            .init(widget: .battery, value: .percent(82), bolt: .charging),
        ]
        for frame in [BatteryFrameStyle.minimal, .minimal, .rounded, .rounded, .minimal] {
            for display in displays { _ = cache.image(for: display, dark: false, scale: 2, style: .split, frame: frame) }
        }
        XCTAssertEqual(cache.renderCount[.battery], 3, "minimal, rounded, minimal")
        for widget in [SystemWidget.cpu, .memory, .disk, .gpu] { XCTAssertEqual(cache.renderCount[widget], 1, "\(widget)") }
        let rounded = cache.image(for: displays[4], dark: false, scale: 2, frame: .rounded)
        XCTAssertEqual(rounded?.size, MenuBarSystemImage.size(displays[4], frame: .rounded))
    }

    func testLabelsTakeTheControllersLayout() {
        let store = SystemMonitorStore(makeSampler: { ValueSampler() }, scheduler: SilentScheduler())
        let suite = "tokenly.wiring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SystemWidgetController(store: store, defaults: defaults, supportProbe: { _ in .supported })
        controller.setLayout(.split)
        controller.setBatteryFrame(.rounded)
        let label = SystemWidgetLabel(widget: .cpu, store: store, cache: SystemWidgetImageCache(), style: controller.layout,
                                      frame: controller.batteryFrame)
        XCTAssertEqual(label.style, .split)
        XCTAssertEqual(label.frame, .rounded)
    }

    // MARK: Store → label value (review L3)

    private struct ValueSampler: SystemSampler {
        func sample() async throws -> SystemSnapshot {
            SystemSnapshot(sampledAt: Date(), cpu: .available(CPUUsage(totalPercent: 23.6, userPercent: 20, systemPercent: 3.6)),
                           memory: .available(MemoryUsage(totalBytes: 1_000, usedBytes: 714, appBytes: 714, wiredBytes: 0,
                                                          compressedBytes: 0, cachedFilesBytes: 0)))
        }
    }

    private final class SilentScheduler: SystemMonitorScheduling {
        final class Job: SystemMonitorCancellable { func cancel() {} }
        func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { Job() }
        func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { Job() }
        func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { Job() }
    }

    func testLabelValuesComeFromTheStore() async {
        let store = SystemMonitorStore(makeSampler: { ValueSampler() }, scheduler: SilentScheduler())
        XCTAssertEqual(SystemWidgetPresentation.display(.cpu, store: store).value, .loading, "Off: nothing measured yet")
        store.setEnabled(.cpu, true)
        store.setEnabled(.memory, true)
        await store.pendingSample?.value
        XCTAssertEqual(SystemWidgetPresentation.display(.cpu, store: store).text, "24%")
        XCTAssertEqual(SystemWidgetPresentation.display(.memory, store: store).text, "71%")
        XCTAssertEqual(SystemWidgetPresentation.display(.gpu, store: store).value, .loading, "GPU is off")
        store.setEnabled(.cpu, false)
        store.setEnabled(.memory, false)
        XCTAssertEqual(SystemWidgetPresentation.display(.cpu, store: store).value, .loading)
    }

    func testControllerKeepsTheStoreAndScannerItWasGiven() {
        let store = SystemMonitorStore(makeSampler: { ValueSampler() }, scheduler: SilentScheduler())
        let scanner = ProcessTopStore(scheduler: SilentScheduler())
        let suite = "tokenly.wiring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SystemWidgetController(store: store, processTop: scanner, defaults: defaults, supportProbe: { _ in .supported })
        XCTAssertTrue(controller.store === store)
        XCTAssertTrue(controller.processTop === scanner)
    }

    // MARK: Real support probes on this Mac (review L3)

    func testRealSupportProbe() {
        for widget in [SystemWidget.cpu, .memory, .disk] {
            XCTAssertEqual(SystemWidgetSupport.probe(widget), .supported)
        }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Only the verified MacBook (Mac16,12, macOS 27.0.1) must support GPU and battery; elsewhere either answer
        // is acceptable, but it must be one of the defined findings.
        if String(cString: model) == "Mac16,12", (os.majorVersion, os.minorVersion, os.patchVersion) == (27, 0, 1) {
            XCTAssertEqual(SystemWidgetSupport.probe(.gpu), .supported)
            XCTAssertEqual(SystemWidgetSupport.probe(.battery), .supported)
        } else {
            print("SUPPORT_PROBE gpu=\(SystemWidgetSupport.probe(.gpu)) battery=\(SystemWidgetSupport.probe(.battery))")
        }
    }

    // MARK: Scene observation (6-3 GUI bug: toggles turned themselves off)

    /// `SystemMonitorMenuBarScenes` must observe the controller. With a plain reference SwiftUI did not re-evaluate the
    /// scene after a toggle, and `MenuBarExtra`'s KVO write-back of the stale `isInserted == false` turned the widget
    /// off again within ~10 ms. The real menu bar path cannot run in XCTest; see the HANDOFF reproduction steps.
    func testMenuBarScenesObserveTheController() {
        let store = SystemMonitorStore(makeSampler: { ValueSampler() }, scheduler: SilentScheduler())
        let suite = "tokenly.wiring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SystemWidgetController(store: store, defaults: defaults, supportProbe: { _ in .supported })
        let scenes = SystemMonitorMenuBarScenes(controller: controller, cache: SystemWidgetImageCache(),
                                                settingsWindow: SettingsWindowManager(), processIcons: ProcessIconProvider())
        let wrapper = Mirror(reflecting: scenes).children.first { $0.label == "_controller" }?.value
        XCTAssertTrue(wrapper is ObservedObject<SystemWidgetController>, "controller must be @ObservedObject, found \(type(of: wrapper))")
    }

    // MARK: Settings and accessibility text

    func testReasonTextOnlyForUnsupported() {
        XCTAssertNil(SystemWidgetSupport.supported.reasonText)
        XCTAssertEqual(SystemWidgetSupport.noBattery.reasonText, "이 Mac에는 배터리가 없습니다.")
        XCTAssertEqual(SystemWidgetSupport.gpuUnavailable(.notAppleSilicon).reasonText, "Apple Silicon Mac에서만 지원합니다.")
        XCTAssertEqual(SystemWidgetSupport.gpuUnavailable(.multipleAccelerators(2)).reasonText, "GPU가 여러 개인 Mac은 지원하지 않습니다.")
        XCTAssertEqual(SystemWidgetSupport.gpuUnavailable(.noUtilizationKey).reasonText, "이 Mac에서는 GPU 사용률을 읽을 수 없습니다.")
    }

    func testAccessibilityText() {
        XCTAssertEqual(SystemWidgetDisplay(widget: .cpu, value: .percent(24)).accessibilityText, "CPU 24%")
        XCTAssertEqual(SystemWidgetDisplay(widget: .gpu, value: .unavailable).accessibilityText, "GPU 측정 불가")
        XCTAssertEqual(SystemWidgetDisplay(widget: .memory, value: .loading).accessibilityText, "RAM 측정 중")
        XCTAssertEqual(SystemWidgetDisplay(widget: .battery, value: .percent(82), bolt: .charging).accessibilityText, "배터리 82%, 충전 중")
        XCTAssertEqual(SystemWidgetDisplay(widget: .battery, value: .percent(82)).accessibilityText, "배터리 82%")
    }
}
