import Metal
import SwiftUI
import XCTest
@testable import Tokenly

/// 6-4d GPU popover: headline (0 % vs failure vs not yet measured), consistency with the menu bar widget, gaps in the
/// graph, the GPU palette (CPU/RAM unchanged), and the one-shot chip name / core count.
@MainActor
final class GPUPopoverTests: XCTestCase {
    // MARK: Headline

    func testHeadlineSeparatesZeroFailureAndNotYetMeasured() {
        XCTAssertEqual(SystemWidgetPresentation.gpuHeadline(.available(0)).value, "0", "A measured 0 % is 0")
        XCTAssertNil(SystemWidgetPresentation.gpuHeadline(.available(0)).note)
        XCTAssertEqual(SystemWidgetPresentation.gpuHeadline(.available(37.6)).value, "38")
        let failed = SystemWidgetPresentation.gpuHeadline(.unavailable(.insufficientSamples))
        XCTAssertEqual(failed.value, "—"); XCTAssertEqual(failed.note, "확인 불가")
        XCTAssertEqual(SystemWidgetPresentation.gpuHeadline(.unavailable(.readFailed(5))).note, "확인 불가")
        XCTAssertEqual(SystemWidgetPresentation.gpuHeadline(.available(.nan)).value, "—", "Never shown as 0")
        let pending = SystemWidgetPresentation.gpuHeadline(nil)
        XCTAssertEqual(pending.value, "—"); XCTAssertEqual(pending.note, "측정 중")
    }

    /// The popover number and the menu bar widget come from the same value with the same rounding.
    func testHeadlineMatchesTheMenuBarWidget() {
        for value: Double in [0, 0.4, 0.5, 12.49, 12.5, 63.2, 99.6, 100] {
            let widget = SystemWidgetPresentation.gpu(.available(value)).text
            XCTAssertEqual(SystemWidgetPresentation.gpuHeadline(.available(value)).value + "%", widget, "\(value)")
        }
        XCTAssertEqual(SystemWidgetPresentation.gpu(.unavailable(.insufficientSamples)).text, "—")
    }

    // MARK: Graph

    /// Failed windows are `nil` in `gpuHistory` (and a dropped stale window leaves no point): the graph splits there
    /// and draws no 0 for them; a measured 0 % stays a point.
    func testFailedWindowsAreGapsNotZero() {
        let end = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var history = SystemMetricHistory()
        for (offset, value) in [(-9.0, 12.0), (-8, 15), (-7, nil), (-6, nil), (-5, 0), (-4, 3), (0, 20)] as [(Double, Double?)] {
            history.append(value, at: end.addingTimeInterval(offset))
        }
        let layout = AuroraGraphLayout(history: history, size: CGSize(width: 324, height: 84))
        XCTAssertEqual(layout.segments.map(\.count), [2, 2, 1], "nil gap and the 4 s pause both split")
        XCTAssertEqual(layout.segments.flatMap { $0 }.filter { $0.y == 84 }.count, 1, "Only the measured 0 % is at the bottom")
        XCTAssertEqual(layout.currentValue, 20)
    }

    // MARK: Palette

    func testGPUPaletteIsTheApprovedHexAndCPURAMAreUnchanged() {
        func hex(_ c: AuroraPalette.RGB) -> String { String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
        XCTAssertEqual(AuroraPalette.stops(dark: true, scheme: .gpu).map { hex($0.rgb) }, ["A8CDF4", "A9B6F0", "C5B3EE"])
        XCTAssertEqual(AuroraPalette.stops(dark: true, scheme: .gpu).map(\.value), [0, 50, 100])
        // Light mode: same hue family, deeper, so the line reads on a light background.
        for stop in AuroraPalette.stops(dark: false, scheme: .gpu) { XCTAssertLessThan(stop.rgb.r + stop.rgb.g + stop.rgb.b, 2.2) }
        // CPU / RAM (standard) unchanged, also through the new parameter.
        XCTAssertEqual(AuroraPalette.stops(dark: true).map { hex($0.rgb) }, AuroraPalette.stops(dark: true, scheme: .standard).map { hex($0.rgb) })
        XCTAssertEqual(AuroraPalette.stops(dark: true)[0].rgb, .init(r: 0.25, g: 0.85, b: 0.72))
        XCTAssertEqual(AuroraPalette.rgb(for: 40, dark: true), AuroraPalette.rgb(for: 40, dark: true, scheme: .standard))
        // Height rule kept: higher is more lavender (more red) in the GPU palette.
        XCTAssertLessThan(AuroraPalette.rgb(for: 55, dark: true, scheme: .gpu).r, AuroraPalette.rgb(for: 95, dark: true, scheme: .gpu).r)
    }

    // MARK: Device info

    func testCoreCountIsAcceptedOnlyWhenPlausible() {
        XCTAssertEqual(GPUDeviceInfo.coreCount(from: NSNumber(value: 8)), 8)
        XCTAssertEqual(GPUDeviceInfo.coreCount(from: 40), 40)
        for bad: Any? in [nil, NSNumber(value: 0), NSNumber(value: -3), NSNumber(value: 5000), NSNumber(value: 8.5), "8", Data([8])] {
            XCTAssertNil(GPUDeviceInfo.coreCount(from: bad), "\(String(describing: bad)) hides the row")
        }
    }

    func testNameFallsBackAndIsNeverHardCoded() {
        XCTAssertEqual(GPUDeviceInfo.make(metalName: "Apple M9", registryModel: "Apple M4", coreValue: nil).name, "Apple M9", "Metal first")
        XCTAssertEqual(GPUDeviceInfo.make(metalName: nil, registryModel: "Apple M4", coreValue: nil).name, "Apple M4")
        XCTAssertEqual(GPUDeviceInfo.make(metalName: "  ", registryModel: nil, coreValue: nil).name, nil, "Nothing known: no name line")
        XCTAssertNil(GPUDeviceInfo.make(metalName: nil, registryModel: nil, coreValue: nil).coreCount)
    }

    /// On this Mac the info comes from the system (Metal and the measured IOAccelerator), not from constants.
    func testRealDeviceInfoOnThisMac() {
        let info = GPUDeviceInfo.readSystem()
        XCTAssertEqual(info.name, MTLCreateSystemDefaultDevice()?.name)
        if let cores = info.coreCount { XCTAssertTrue(GPUDeviceInfo.coreRange.contains(cores)) }
        XCTAssertEqual(GPUDeviceInfo.current, GPUDeviceInfo.current, "Read once and reused")
    }
}
