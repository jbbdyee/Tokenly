import IOKit.ps
import SwiftUI
import XCTest
@testable import Tokenly

/// 6-4f Battery popover: status priority, time estimates, cycles / maximum capacity / temperature text, adapter
/// watts, the pack temperature parse, the store's read time stamp, and the live read on this Mac.
@MainActor
final class BatteryPopoverTests: XCTestCase {
    private func state(_ percent: Int?, ac: Bool?, charging: Bool?, full: Bool?,
                       toEmpty: SystemMetric<BatteryTimeEstimate> = .unavailable(.unsupported),
                       toFull: SystemMetric<BatteryTimeEstimate> = .unavailable(.unsupported),
                       watts: SystemMetric<Int> = .unavailable(.unsupported)) -> SystemMetric<BatteryPowerState> {
        func metric<T>(_ value: T?) -> SystemMetric<T> { value.map { .available($0) } ?? .unavailable(.unsupported) }
        return .available(BatteryPowerState(chargePercent: metric(percent), isExternalPowerConnected: metric(ac), isCharging: metric(charging),
                                            isAtFullCapacity: metric(full), timeToEmpty: toEmpty, timeToFull: toFull, adapterWatts: watts))
    }

    private func status(_ metric: SystemMetric<BatteryPowerState>?) -> BatteryPopoverStatus { BatteryPopoverPresentation.status(metric) }

    // MARK: Status

    func testStatusClassification() {
        XCTAssertEqual(status(state(57, ac: true, charging: true, full: false)), .charging)
        XCTAssertEqual(status(state(47, ac: false, charging: false, full: false)), .onBattery)
        XCTAssertEqual(status(state(100, ac: true, charging: false, full: true)), .full)
        XCTAssertEqual(status(state(80, ac: true, charging: false, full: false)), .holding, "Connected, not charging, not full")
        XCTAssertEqual(status(state(12, ac: false, charging: false, full: false)), .low)
        XCTAssertEqual(status(state(20, ac: false, charging: false, full: false)), .low, "20 % is low")
        XCTAssertEqual(status(state(21, ac: false, charging: false, full: false)), .onBattery)
        XCTAssertEqual(status(state(12, ac: true, charging: true, full: false)), .charging, "Charging wins over a low charge")
        XCTAssertEqual(status(state(12, ac: true, charging: false, full: false)), .holding, "Low but on a charger is not 배터리 부족")
        XCTAssertEqual(status(state(nil, ac: false, charging: false, full: nil)), .onBattery, "Unknown charge: no low claim")
        XCTAssertEqual(status(state(80, ac: nil, charging: false, full: false)), .unknown)
        XCTAssertEqual(status(state(80, ac: true, charging: nil, full: nil)), .unknown, "Cannot tell full from held")
        XCTAssertEqual(status(.unavailable(.readFailed(5))), .unknown)
        XCTAssertEqual(status(.unavailable(.noBattery)), .noBattery)
        XCTAssertEqual(status(nil), .loading)
        for case let s in [BatteryPopoverStatus.charging, .onBattery, .low, .full, .holding, .noBattery, .unknown] {
            XCTAssertFalse(BatteryPopoverPresentation.badge(s)?.text.isEmpty ?? true, "Every state has text, not only colour")
        }
        XCTAssertEqual(BatteryPopoverPresentation.badge(.charging)?.text, "충전 중")
        XCTAssertEqual(BatteryPopoverPresentation.badge(.holding)?.symbol, "pause.circle.fill")
        XCTAssertNil(BatteryPopoverPresentation.badge(.loading))
    }

    func testHeadlineIsTheMenuBarValue() {
        for percent in [0, 1, 20, 57, 100] {
            let metric = state(percent, ac: false, charging: false, full: false)
            guard case .percent(let widget) = SystemWidgetPresentation.battery(metric).value else { return XCTFail("\(percent)") }
            XCTAssertEqual(BatteryPopoverPresentation.headline(metric).value, "\(widget)")
        }
        XCTAssertEqual(BatteryPopoverPresentation.headline(nil).note, "측정 중")
        XCTAssertEqual(BatteryPopoverPresentation.headline(.unavailable(.readFailed(5))).note, "확인 불가")
        XCTAssertEqual(BatteryPopoverPresentation.headline(.unavailable(.noBattery)).note, "배터리 없음")
    }

    // MARK: Time

    func testTimeEstimatesFollowThePowerState() {
        let onBattery = state(47, ac: false, charging: false, full: false, toEmpty: .available(.minutes(265)), toFull: .available(.minutes(30)))
        XCTAssertEqual(BatteryPopoverPresentation.timeLine(status(onBattery), onBattery), "남은 시간 약 4시간 25분")
        let charging = state(64, ac: true, charging: true, full: false, toEmpty: .available(.minutes(500)), toFull: .available(.minutes(72)))
        XCTAssertEqual(BatteryPopoverPresentation.timeLine(status(charging), charging), "완충까지 약 1시간 12분", "Not the time to empty")
        let calculating = state(91, ac: false, charging: false, full: false, toEmpty: .available(.calculating))
        XCTAssertEqual(BatteryPopoverPresentation.timeLine(status(calculating), calculating), "시간 계산 중")
        let low = state(12, ac: false, charging: false, full: false, toEmpty: .available(.minutes(48)))
        XCTAssertEqual(BatteryPopoverPresentation.timeLine(status(low), low), "남은 시간 약 48분")
        let missing = state(47, ac: false, charging: false, full: false)
        XCTAssertNil(BatteryPopoverPresentation.timeLine(status(missing), missing), "No value: no line, never 0 minutes")
        let full = state(100, ac: true, charging: false, full: true, toEmpty: .available(.minutes(600)), toFull: .available(.minutes(5)))
        XCTAssertNil(BatteryPopoverPresentation.timeLine(status(full), full), "Full: no estimate")
        let holding = state(80, ac: true, charging: false, full: false, toFull: .available(.minutes(40)))
        XCTAssertNil(BatteryPopoverPresentation.timeLine(status(holding), holding), "Held: time to full does not apply")
        XCTAssertEqual(BatteryPopoverPresentation.duration(60), "약 1시간")
        XCTAssertEqual(BatteryPopoverPresentation.duration(1), "약 1분")
    }

    func testEstimateParsing() {
        XCTAssertEqual(BatteryPowerState.estimate(-1), .available(.calculating))
        XCTAssertEqual(BatteryPowerState.estimate(0), .unavailable(.unsupported), "0 is no estimate")
        XCTAssertEqual(BatteryPowerState.estimate(265), .available(.minutes(265)))
        XCTAssertEqual(BatteryPowerState.estimate(-5), .unavailable(.inconsistentValues), "Invalid negative")
        XCTAssertEqual(BatteryPowerState.estimate(65_535), .unavailable(.inconsistentValues), "Sentinel, not an estimate")
        XCTAssertEqual(BatteryPowerState.estimate(nil), .unavailable(.unsupported))
        XCTAssertEqual(BatteryPowerState.estimate(12.5), .unavailable(.unsupported))
        let parsed = BatteryPowerState.make(from: .sources([["Type": "InternalBattery", "Is Present": true, "Current Capacity": 64, "Max Capacity": 100,
                                                             "Power Source State": "AC Power", "Is Charging": true,
                                                             "Time to Empty": 0, "Time to Full Charge": 72]]),
                                            adapter: [kIOPSPowerAdapterWattsKey: 30]).value
        XCTAssertEqual(parsed?.timeToFull, .available(.minutes(72)))
        XCTAssertEqual(parsed?.timeToEmpty, .unavailable(.unsupported))
        XCTAssertEqual(parsed?.adapterWatts, .available(30))
    }

    // MARK: Power line and details

    func testPowerLineUsesTheReportedWattsOnly() {
        XCTAssertEqual(BatteryPopoverPresentation.powerLine(state(80, ac: true, charging: true, full: false, watts: .available(96)))?.text,
                       "전원 어댑터 연결됨 · 96W")
        XCTAssertEqual(BatteryPopoverPresentation.powerLine(state(80, ac: true, charging: true, full: false))?.text, "전원 어댑터 연결됨")
        XCTAssertEqual(BatteryPopoverPresentation.powerLine(state(80, ac: false, charging: false, full: false))?.text, "배터리 전원")
        XCTAssertNil(BatteryPopoverPresentation.powerLine(state(80, ac: nil, charging: false, full: false)))
        XCTAssertEqual(BatteryPowerState.watts([kIOPSPowerAdapterWattsKey: 0]), .unavailable(.inconsistentValues))
        XCTAssertEqual(BatteryPowerState.watts(["Name": "30W USB-C Power Adapter"]), .unavailable(.unsupported), "No guessing from the name")
        XCTAssertEqual(BatteryPowerState.watts(nil), .unavailable(.unsupported))
        // Watts only for a connected adapter.
        let unplugged = BatteryPowerState.make(from: .sources([["Type": "InternalBattery", "Current Capacity": 50, "Max Capacity": 100,
                                                                "Power Source State": "Battery Power", "Is Charging": false]]),
                                               adapter: [kIOPSPowerAdapterWattsKey: 30]).value
        XCTAssertEqual(unplugged?.adapterWatts, .unavailable(.unsupported))
    }

    private func health(cycles: SystemMetric<Int> = .available(114), fraction: SystemMetric<Double> = .available(4631.0 / 4629),
                        temperature: SystemMetric<Double> = .available(29.39)) -> SystemMetric<BatteryStatus> {
        .available(BatteryStatus(cycleCount: cycles, designCapacityMAh: .available(4629), maximumCapacityMAh: .available(4631),
                                 healthFraction: fraction, temperatureCelsius: temperature))
    }

    func testCyclesAndMaximumCapacity() {
        XCTAssertEqual(BatteryPopoverPresentation.cycles(health()), "114회")
        XCTAssertEqual(BatteryPopoverPresentation.cycles(health(cycles: .unavailable(.unsupported))), "확인 불가")
        XCTAssertEqual(BatteryPopoverPresentation.cycles(.unavailable(.readFailed(5))), "확인 불가")
        XCTAssertEqual(BatteryPopoverPresentation.cycles(nil), "—")
        XCTAssertEqual(BatteryPopoverPresentation.maximumCapacity(health()), "100%", "4631 / 4629 mAh, as the battery reports")
        XCTAssertEqual(BatteryPopoverPresentation.maximumCapacity(health(fraction: .available(0.976))), "98%")
        XCTAssertEqual(BatteryPopoverPresentation.maximumCapacity(health(fraction: .available(1.03))), "103%", "Not capped at 100")
        XCTAssertEqual(BatteryPopoverPresentation.maximumCapacity(health(fraction: .available(1.5))), "150%")
        XCTAssertEqual(BatteryPopoverPresentation.maximumCapacity(health(fraction: .available(1.51))), "확인 불가")
        XCTAssertEqual(BatteryPopoverPresentation.maximumCapacity(health(fraction: .available(0))), "확인 불가")
        XCTAssertEqual(BatteryPopoverPresentation.maximumCapacity(health(fraction: .unavailable(.inconsistentValues))), "확인 불가", "Design 0 mAh")
        XCTAssertFalse(BatteryPopoverPresentation.maximumCapacityHelp.contains("배터리 성능 상태와 같"))
        XCTAssertTrue(BatteryPopoverPresentation.maximumCapacityHelp.contains("다를 수 있습니다"))
    }

    func testTemperatureTextFreshStaleAndFailed() {
        let read = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func text(_ h: SystemMetric<BatteryStatus>?, age: TimeInterval, readAt: Date? = read) -> String {
            BatteryPopoverPresentation.temperature(h, readAt: readAt, now: read.addingTimeInterval(age))
        }
        XCTAssertEqual(text(health(), age: 0), "29°C", "Whole degrees")
        XCTAssertEqual(text(health(temperature: .available(29.5)), age: 30), "30°C")
        XCTAssertEqual(text(health(), age: 120), "29°C", "Exactly 120 s is still shown")
        XCTAssertEqual(text(health(), age: 121), "—", "Older than 120 s")
        XCTAssertEqual(text(health(temperature: .unavailable(.unsupported)), age: 10), "확인 불가", "No key on this Mac")
        XCTAssertEqual(text(health(temperature: .unavailable(.unsupported)), age: 500), "—", "Stale wins: nothing current is known")
        XCTAssertEqual(text(.unavailable(.readFailed(5)), age: 10), "확인 불가")
        XCTAssertEqual(text(nil, age: 0), "—")
        XCTAssertEqual(text(health(), age: 0, readAt: nil), "—")
        XCTAssertEqual(text(health(), age: -3600), "—", "Clock moved back")
        XCTAssertTrue(BatteryPopoverPresentation.temperatureHelp.contains("문서화되지 않은"))
    }

    func testPackTemperatureParse() {
        XCTAssertEqual(BatteryStatus.temperature(fromPackValue: 2939), .available(29.39), "Hundredths of °C")
        XCTAssertEqual(BatteryStatus.temperature(fromPackValue: -500), .available(-5))
        XCTAssertEqual(BatteryStatus.temperature(fromPackValue: 2950.0), .unavailable(.unsupported), "Integers only")
        XCTAssertEqual(BatteryStatus.temperature(fromPackValue: "2939"), .unavailable(.unsupported))
        XCTAssertEqual(BatteryStatus.temperature(fromPackValue: nil), .unavailable(.unsupported))
        XCTAssertEqual(BatteryStatus.temperature(fromPackValue: 29_390), .unavailable(.inconsistentValues), "293.9 °C")
        XCTAssertEqual(BatteryStatus.temperature(fromPackValue: 2_950 * 10), .unavailable(.inconsistentValues))
        let withPack = BatteryStatus.make(from: .properties(["CycleCount": 114], pack: ["Temperature": 2939, "VirtualTemperature": 9999])).value
        XCTAssertEqual(withPack?.temperatureCelsius, .available(29.39), "Only Temperature is used")
        let noPack = BatteryStatus.make(from: .properties(["CycleCount": 114, "Temperature": 2939])).value
        XCTAssertEqual(noPack?.temperatureCelsius, .unavailable(.unsupported), "No pack child: no value, not the service's keys")
    }

    // MARK: Store

    func testStoreStampsEachBatteryReadAndClearsOnDisable() {
        let scheduler = Scheduler(), battery = FakeBattery()
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = SystemMonitorStore(battery: battery, scheduler: scheduler, now: { now })
        store.setEnabled(.battery, true)
        XCTAssertEqual(store.batteryReadDate, now)
        XCTAssertEqual(battery.reads, 1)
        XCTAssertEqual(scheduler.intervals, [SystemMonitorStore.batteryFallbackInterval], "Only the existing 60 s fallback, no new timer")
        now = now.addingTimeInterval(60)
        scheduler.fire()
        XCTAssertEqual(store.batteryReadDate, now)
        XCTAssertEqual(battery.reads, 2)
        store.setEnabled(.battery, true)
        XCTAssertEqual(battery.reads, 2, "No duplicate job")
        store.setEnabled(.battery, false)
        XCTAssertNil(store.batteryReadDate)
        XCTAssertNil(store.batteryHealth)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    // MARK: This Mac

    func testLiveReadOnThisMac() {
        let sampler = BatterySampler()
        guard case .available(let power) = sampler.samplePowerState() else { return }   // a Mac without a battery
        if power.isExternalPowerConnected == .available(false) { XCTAssertEqual(power.adapterWatts, .unavailable(.unsupported)) }
        guard case .available(let health) = sampler.sample() else { return XCTFail("Power state without battery health") }
        if let celsius = health.temperatureCelsius.value {
            XCTAssertTrue((10...60).contains(celsius), "A battery in use, not 0.1 K (\(celsius))")
        }
    }
}

// MARK: - Doubles

private final class FakeBattery: BatterySampling {
    private(set) var reads = 0
    func sample() -> SystemMetric<BatteryStatus> {
        .available(BatteryStatus(cycleCount: .available(1), designCapacityMAh: .available(100), maximumCapacityMAh: .available(99),
                                 healthFraction: .available(0.99), temperatureCelsius: .available(30)))
    }
    func samplePowerState() -> SystemMetric<BatteryPowerState> {
        reads += 1
        return .available(BatteryPowerState(chargePercent: .available(50), isExternalPowerConnected: .available(false), isCharging: .available(false)))
    }
}

@MainActor
private final class Scheduler: SystemMonitorScheduling {
    final class Job: SystemMonitorCancellable {
        let interval: TimeInterval?
        let action: @MainActor () -> Void
        var cancelled = false
        init(_ interval: TimeInterval?, _ action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private var jobs: [Job] = []
    var intervals: [TimeInterval] { jobs.filter { !$0.cancelled }.compactMap(\.interval) }

    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let job = Job(interval, action)
        jobs.append(job)
        return job
    }
    func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable { Job(nil, action) }
    func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let job = Job(nil, action)
        jobs.append(job)
        return job
    }
    func fire() {
        for job in jobs where job.interval != nil && !job.cancelled { job.action() }
    }
}
