import IOKit
import XCTest
@testable import Tokenly

/// Battery parsing with fixed registry dictionaries, plus a smoke test against the real IORegistry.
final class BatterySamplerTests: XCTestCase {
    /// Shape of AppleSmartBattery on an Apple silicon MacBook running current macOS (no top-level mAh capacities).
    private let appleSilicon: [String: Any] = [
        "BatteryInstalled": true,
        "CycleCount": 114,
        "MaxCapacity": 100,
        "BatteryData": ["DesignCapacity": 4_629, "FullChargeCapacity": 4_166, "NominalChargeCapacity": 4_762, "MaxCapacity": 100],
    ]

    private func status(_ properties: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> BatteryStatus {
        try XCTUnwrap(BatteryStatus.make(from: .properties(properties)).value, file: file, line: line)
    }

    func testAppleSiliconRegistryValues() throws {
        let battery = try status(appleSilicon)
        XCTAssertEqual(battery.cycleCount, .available(114))
        XCTAssertEqual(battery.designCapacityMAh, .available(4_629))
        XCTAssertEqual(battery.maximumCapacityMAh, .available(4_166))
        XCTAssertEqual(try XCTUnwrap(battery.healthFraction.value), 4_166.0 / 4_629.0, accuracy: 1e-12)
    }

    func testTopLevelFallbackIgnoresPercentMaxCapacity() throws {
        let battery = try status(["CycleCount": 300, "DesignCapacity": 5_000, "AppleRawMaxCapacity": 4_500, "MaxCapacity": 100])
        XCTAssertEqual(battery.maximumCapacityMAh, .available(4_500))
        XCTAssertEqual(try XCTUnwrap(battery.healthFraction.value), 0.9, accuracy: 1e-12)

        let percentOnly = try status(["CycleCount": 300, "DesignCapacity": 5_000, "MaxCapacity": 100])
        XCTAssertEqual(percentOnly.maximumCapacityMAh, .unavailable(.unsupported))
        XCTAssertEqual(percentOnly.healthFraction, .unavailable(.unsupported))
    }

    func testHealthIsNotClampedAboveDesign() throws {
        let battery = try status(["BatteryData": ["DesignCapacity": 4_629, "FullChargeCapacity": 4_635]])
        XCTAssertGreaterThan(try XCTUnwrap(battery.healthFraction.value), 1)
    }

    func testTemperatureIsUnsupportedEvenWhenAKeyIsPresent() throws {
        var properties = appleSilicon
        properties["Temperature"] = 3_050
        properties["VirtualTemperature"] = 3_000
        XCTAssertEqual(try status(properties).temperatureCelsius, .unavailable(.unsupported))
    }

    func testNoBatteryIsDistinctFromReadFailure() {
        XCTAssertEqual(BatteryStatus.make(from: .noService), .unavailable(.noBattery))
        XCTAssertEqual(BatteryStatus.make(from: .properties(["BatteryInstalled": false, "CycleCount": 5])), .unavailable(.noBattery))
        XCTAssertEqual(BatteryStatus.make(from: .failed(kIOReturnNotPermitted)), .unavailable(.readFailed(kIOReturnNotPermitted)))
    }

    func testMissingOrMistypedValuesAreUnsupportedNotZero() throws {
        let empty = try status([:])
        XCTAssertEqual(empty.cycleCount, .unavailable(.unsupported))
        XCTAssertEqual(empty.designCapacityMAh, .unavailable(.unsupported))
        XCTAssertEqual(empty.healthFraction, .unavailable(.unsupported))

        let mistyped = try status(["CycleCount": "114", "BatteryData": ["DesignCapacity": true, "FullChargeCapacity": 4_166.5]])
        XCTAssertEqual(mistyped.cycleCount, .unavailable(.unsupported))
        XCTAssertEqual(mistyped.designCapacityMAh, .unavailable(.unsupported))
        XCTAssertEqual(mistyped.maximumCapacityMAh, .unavailable(.unsupported))
    }

    func testOutOfRangeValuesAreInconsistent() throws {
        let battery = try status(["CycleCount": -1, "BatteryData": ["DesignCapacity": 0, "FullChargeCapacity": 4_000]])
        XCTAssertEqual(battery.cycleCount, .unavailable(.inconsistentValues))
        XCTAssertEqual(battery.designCapacityMAh, .unavailable(.inconsistentValues))
        XCTAssertEqual(battery.maximumCapacityMAh, .available(4_000))
        XCTAssertEqual(battery.healthFraction, .unavailable(.inconsistentValues))
    }

    func testLiveSamplerReportsBatteryOrNoBattery() throws {
        switch BatterySampler().sample() {
        case .unavailable(let reason):
            XCTAssertEqual(reason, .noBattery, "A real read must either succeed or report no battery")
        case .available(let battery):
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(battery.cycleCount.value), 0)
            // 6-4f: read from the AppleSmartBatteryPack child where present; otherwise unsupported, never another sensor.
            switch battery.temperatureCelsius {
            case .available(let celsius): XCTAssertTrue(BatteryStatus.temperatureRange.contains(celsius))
            case .unavailable(let reason): XCTAssertTrue([.unsupported, .inconsistentValues].contains(reason))
            }
            if let health = battery.healthFraction.value { XCTAssertTrue(health > 0 && health < 2) }
        }
    }

    // MARK: Live charge state (IOPowerSources)

    private func power(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var description: [String: Any] = ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 57,
                                          "Max Capacity": 100, "Power Source State": "AC Power", "Is Charging": true]
        for (key, value) in overrides { description[key] = value }
        return description
    }

    private func powerState(_ sources: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) throws -> BatteryPowerState {
        try XCTUnwrap(BatteryPowerState.make(from: .sources(sources)).value, file: file, line: line)
    }

    func testConnectedAndChargingAreSeparate() throws {
        let charging = try powerState([power()])
        XCTAssertEqual(charging, BatteryPowerState(chargePercent: .available(57), isExternalPowerConnected: .available(true),
                                                   isCharging: .available(true), isAtFullCapacity: .available(false)))

        // Plugged in but held (full, optimized charging or a charge limit).
        let held = try powerState([power(["Current Capacity": 80, "Is Charging": false])])
        XCTAssertEqual(held.isExternalPowerConnected, .available(true))
        XCTAssertEqual(held.isCharging, .available(false))

        let onBattery = try powerState([power(["Power Source State": "Battery Power", "Is Charging": false])])
        XCTAssertEqual(onBattery.isExternalPowerConnected, .available(false))
        XCTAssertEqual(onBattery.isCharging, .available(false))
    }

    func testChargePercentUsesCurrentOverMaxAndRounds() throws {
        XCTAssertEqual(try powerState([power(["Current Capacity": 2_000, "Max Capacity": 4_629])]).chargePercent, .available(43))
        XCTAssertEqual(try powerState([power(["Current Capacity": 0])]).chargePercent, .available(0))
        XCTAssertEqual(try powerState([power(["Current Capacity": 100])]).chargePercent, .available(100))
    }

    /// Full is decided on the raw integers, before rounding: 4,627 of 4,629 shows 100 % but is not full (6-3 policy).
    func testFullCapacityIsRawNotRounded() throws {
        let nearlyFull = try powerState([power(["Current Capacity": 4_627, "Max Capacity": 4_629, "Is Charging": false])])
        XCTAssertEqual(nearlyFull.chargePercent, .available(100))
        XCTAssertEqual(nearlyFull.isAtFullCapacity, .available(false))

        let full = try powerState([power(["Current Capacity": 4_629, "Max Capacity": 4_629, "Is Charging": false])])
        XCTAssertEqual(full.isAtFullCapacity, .available(true))
        XCTAssertEqual(try powerState([power(["Current Capacity": 100])]).isAtFullCapacity, .available(true))
        XCTAssertEqual(try powerState([power(["Current Capacity": 99])]).isAtFullCapacity, .available(false))

        // Without a valid level, fullness is unknown for the same reason.
        XCTAssertEqual(try powerState([power(["Current Capacity": 101])]).isAtFullCapacity, .unavailable(.inconsistentValues))
        let missing = try powerState([power(["Max Capacity": "x"])])
        XCTAssertNil(missing.isAtFullCapacity.value)
        guard case .unavailable(let reason) = missing.chargePercent else { return XCTFail("level must be unavailable") }
        XCTAssertEqual(missing.isAtFullCapacity, .unavailable(reason))
    }

    func testInternalBatteryIsPickedAmongOtherSources() throws {
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 10, "Max Capacity": 100, "Power Source State": "Battery Power"]
        XCTAssertEqual(try powerState([ups, power()]).chargePercent, .available(57))
    }

    func testNoInternalBatteryIsDistinctFromReadFailure() {
        XCTAssertEqual(BatteryPowerState.make(from: .sources([])), .unavailable(.noBattery))
        XCTAssertEqual(BatteryPowerState.make(from: .sources([["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100]])),
                       .unavailable(.noBattery))
        XCTAssertEqual(BatteryPowerState.make(from: .sources([power(["Is Present": false])])), .unavailable(.noBattery))
        XCTAssertEqual(BatteryPowerState.make(from: .failed), .unavailable(.readFailed(kIOReturnError)))
    }

    func testMissingMistypedOrInconsistentPowerValuesAreNotZero() throws {
        var description = power()
        description["Current Capacity"] = nil
        description["Power Source State"] = nil
        description["Is Charging"] = nil
        let missing = try powerState([description])
        XCTAssertEqual(missing.chargePercent, .unavailable(.unsupported))
        XCTAssertEqual(missing.isExternalPowerConnected, .unavailable(.unsupported))
        XCTAssertEqual(missing.isCharging, .unavailable(.unsupported))

        let mistyped = try powerState([power(["Is Charging": 1, "Power Source State": "Off Line", "Current Capacity": 57.5])])
        XCTAssertEqual(mistyped.isCharging, .unavailable(.unsupported))
        XCTAssertEqual(mistyped.isExternalPowerConnected, .unavailable(.unsupported))
        XCTAssertEqual(mistyped.chargePercent, .unavailable(.unsupported))

        XCTAssertEqual(try powerState([power(["Current Capacity": 101])]).chargePercent, .unavailable(.inconsistentValues))
        XCTAssertEqual(try powerState([power(["Max Capacity": 0])]).chargePercent, .unavailable(.inconsistentValues))
        XCTAssertEqual(try powerState([power(["Current Capacity": -1])]).chargePercent, .unavailable(.inconsistentValues))
    }

    func testLivePowerStateReportsBatteryOrNoBattery() throws {
        switch BatterySampler().samplePowerState() {
        case .unavailable(let reason):
            XCTAssertEqual(reason, .noBattery, "A real read must either succeed or report no battery")
        case .available(let state):
            XCTAssertTrue((0...100).contains(try XCTUnwrap(state.chargePercent.value)))
            XCTAssertNotNil(state.isExternalPowerConnected.value)
            XCTAssertNotNil(state.isCharging.value)
        }
    }
}
