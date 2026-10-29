import Foundation
import IOKit.ps

/// Raw result of reading the AppleSmartBattery registry entry, kept separate so parsing is testable without IOKit.
enum BatteryRegistryRead {
    /// No AppleSmartBattery service exists (desktop Macs, most VMs).
    case noService
    case failed(kern_return_t)
    /// The battery service's properties, and the `BatteryData` of its one `AppleSmartBatteryPack` child when present
    /// (macOS keeps the live gauge values, such as the temperature, there).
    case properties([String: Any], pack: [String: Any]? = nil)
}

/// Battery health values from the AppleSmartBattery registry entry. Each field is independently available.
///
/// Sources (capacities are Smart Battery Data Specification registers reported by the gas gauge, in mAh):
/// - cycleCount: top-level `CycleCount` (matches System Information).
/// - designCapacityMAh: `BatteryData.DesignCapacity`, else top-level `DesignCapacity`.
/// - maximumCapacityMAh: `BatteryData.FullChargeCapacity`, else top-level `AppleRawMaxCapacity`.
///   Top-level `MaxCapacity` is never used: it is a percentage on Apple silicon but mAh on Intel Macs.
/// - healthFraction: maximum ÷ design. Not clamped, so a new battery may read above 1. It can differ from
///   System Information's "Maximum Capacity", which Apple derives from values not exposed in the registry.
/// - temperatureCelsius (6-4f): the battery pack's `BatteryData.Temperature` (child `AppleSmartBatteryPack`; the
///   service's own properties do not have it on macOS 27). Undocumented integer in hundredths of a degree Celsius:
///   2939 matched the gas gauge's own thermal sensor at 29.40 °C, while the Smart Battery 0.1 K reading would be
///   21.9 °C. Only the unit is cross-checked; its accuracy against a real thermometer is not verified. Missing or
///   non-integer is unsupported; outside -20...80 °C is inconsistent. Never another sensor (CPU, SSD) as a stand-in.
struct BatteryStatus: Equatable {
    let cycleCount: SystemMetric<Int>
    let designCapacityMAh: SystemMetric<Int>
    let maximumCapacityMAh: SystemMetric<Int>
    let healthFraction: SystemMetric<Double>
    let temperatureCelsius: SystemMetric<Double>

    static func make(from read: BatteryRegistryRead) -> SystemMetric<BatteryStatus> {
        switch read {
        case .noService:
            return .unavailable(.noBattery)
        case .failed(let code):
            return .unavailable(.readFailed(code))
        case .properties(let properties, let pack):
            if let installed = properties["BatteryInstalled"] as? Bool, !installed { return .unavailable(.noBattery) }
            return .available(parse(properties, pack: pack))
        }
    }

    static let temperatureRange: ClosedRange<Double> = -20...80

    /// Hundredths of a degree Celsius → °C, within `temperatureRange`.
    static func temperature(fromPackValue value: Any?) -> SystemMetric<Double> {
        guard case .available(let raw) = registryInteger(value, minimum: .min) else { return .unavailable(.unsupported) }
        let celsius = Double(raw) / 100
        return temperatureRange.contains(celsius) ? .available(celsius) : .unavailable(.inconsistentValues)
    }

    private static func parse(_ properties: [String: Any], pack: [String: Any]?) -> BatteryStatus {
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        let cycleCount = registryInteger(properties["CycleCount"], minimum: 0)
        let design = registryInteger(batteryData["DesignCapacity"] ?? properties["DesignCapacity"], minimum: 1)
        let maximum = registryInteger(batteryData["FullChargeCapacity"] ?? properties["AppleRawMaxCapacity"], minimum: 1)

        let health: SystemMetric<Double>
        switch (maximum, design) {
        case (.available(let maximum), .available(let design)): health = .available(Double(maximum) / Double(design))
        case (.unavailable(let reason), _), (_, .unavailable(let reason)): health = .unavailable(reason)
        }
        return BatteryStatus(cycleCount: cycleCount, designCapacityMAh: design, maximumCapacityMAh: maximum,
                             healthFraction: health, temperatureCelsius: temperature(fromPackValue: pack?["Temperature"]))
    }
}

/// Missing or non-integer values are unsupported; integers below `minimum` are inconsistent.
private func registryInteger(_ value: Any?, minimum: Int) -> SystemMetric<Int> {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
          !CFNumberIsFloatType(number) else { return .unavailable(.unsupported) }
    let integer = number.intValue
    return integer >= minimum ? .available(integer) : .unavailable(.inconsistentValues)
}

/// Missing values and anything other than a CFBoolean are unsupported.
private func registryBool(_ value: Any?) -> SystemMetric<Bool> {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return .unavailable(.unsupported) }
    return .available(number.boolValue)
}

// MARK: - Live charge state (IOPowerSources)

/// A public IOPowerSources time value: minutes, or -1 "still calculating".
enum BatteryTimeEstimate: Equatable {
    case minutes(Int)
    case calculating
}

/// Raw result of IOPSCopyPowerSourcesInfo, kept separate so parsing is testable without IOKit.
enum PowerSourcesRead {
    /// IOPSCopyPowerSourcesInfo or its source list returned nothing.
    case failed
    /// One description dictionary per power source (internal battery, UPS, ...).
    case sources([[String: Any]])
}

/// Live charge state of the internal battery from the public IOPowerSources API.
///
/// External power and charging are separate facts: on AC power the battery is often held (fully charged, optimized
/// charging, charge limit), so `isExternalPowerConnected == true` does not imply `isCharging == true`.
struct BatteryPowerState: Equatable {
    /// Current Capacity ÷ Max Capacity × 100, rounded (the same figure `pmset -g batt` prints).
    let chargePercent: SystemMetric<Int>
    /// Power Source State is "AC Power" (true) or "Battery Power" (false).
    let isExternalPowerConnected: SystemMetric<Bool>
    /// Is Charging.
    let isCharging: SystemMetric<Bool>
    /// Current Capacity == Max Capacity, compared on the raw integers before any rounding, so a 99.6 % battery
    /// whose `chargePercent` rounds to 100 is not reported as full. Defaults to unknown for hand-built values.
    var isAtFullCapacity: SystemMetric<Bool> = .unavailable(.unsupported)
    /// `Time to Empty` (public key, minutes). Apple only defines it on battery power while not charging; the popover
    /// shows it only then. 0 or missing is no estimate, never "0 minutes".
    var timeToEmpty: SystemMetric<BatteryTimeEstimate> = .unavailable(.unsupported)
    /// `Time to Full Charge` (public key, minutes); defined only while charging.
    var timeToFull: SystemMetric<BatteryTimeEstimate> = .unavailable(.unsupported)
    /// The connected adapter's rated output (`kIOPSPowerAdapterWattsKey`), not the power actually drawn or charged.
    var adapterWatts: SystemMetric<Int> = .unavailable(.unsupported)

    /// Longer than any real battery estimate (100 h); beyond it the value is not an estimate.
    static let maxEstimateMinutes = 6_000
    static let adapterWattsRange = 1...500

    static func estimate(_ value: Any?) -> SystemMetric<BatteryTimeEstimate> {
        guard case .available(let minutes) = registryInteger(value, minimum: .min) else { return .unavailable(.unsupported) }
        switch minutes {
        case -1: return .available(.calculating)
        case 0: return .unavailable(.unsupported)
        case 1...maxEstimateMinutes: return .available(.minutes(minutes))
        default: return .unavailable(.inconsistentValues)
        }
    }

    static func watts(_ adapter: [String: Any]?) -> SystemMetric<Int> {
        guard case .available(let watts) = registryInteger(adapter?[kIOPSPowerAdapterWattsKey], minimum: .min) else {
            return .unavailable(.unsupported)
        }
        return adapterWattsRange.contains(watts) ? .available(watts) : .unavailable(.inconsistentValues)
    }

    static func make(from read: PowerSourcesRead, adapter: [String: Any]? = nil) -> SystemMetric<BatteryPowerState> {
        guard case .sources(let sources) = read else { return .unavailable(.readFailed(kIOReturnError)) }
        guard let battery = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              battery[kIOPSIsPresentKey] as? Bool != false else { return .unavailable(.noBattery) }

        let charge: SystemMetric<Int>
        let full: SystemMetric<Bool>
        switch (registryInteger(battery[kIOPSCurrentCapacityKey], minimum: 0), registryInteger(battery[kIOPSMaxCapacityKey], minimum: 1)) {
        case (.available(let current), .available(let max)):
            if current <= max {
                charge = .available(Int((Double(current) * 100 / Double(max)).rounded()))
                full = .available(current == max)
            } else {
                charge = .unavailable(.inconsistentValues)
                full = .unavailable(.inconsistentValues)
            }
        case (.unavailable(let reason), _), (_, .unavailable(let reason)):
            charge = .unavailable(reason)
            full = .unavailable(reason)
        }

        let external: SystemMetric<Bool>
        switch battery[kIOPSPowerSourceStateKey] as? String {
        case kIOPSACPowerValue: external = .available(true)
        case kIOPSBatteryPowerValue: external = .available(false)
        default: external = .unavailable(.unsupported)
        }
        // Watts only describe a connected adapter.
        let watts: SystemMetric<Int> = external == .available(true) ? Self.watts(adapter) : .unavailable(.unsupported)
        return .available(BatteryPowerState(chargePercent: charge, isExternalPowerConnected: external,
                                            isCharging: registryBool(battery[kIOPSIsChargingKey]), isAtFullCapacity: full,
                                            timeToEmpty: estimate(battery[kIOPSTimeToEmptyKey]),
                                            timeToFull: estimate(battery[kIOPSTimeToFullChargeKey]), adapterWatts: watts))
    }
}
