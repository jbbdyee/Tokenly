import Foundation

/// What one system menu bar widget shows. A plain value: the renderer (6-2) draws it, tests check it.
struct SystemWidgetDisplay: Equatable {
    enum Value: Equatable {
        /// No sample yet since the widget was turned on: `—`, dimmed.
        case loading
        /// Measured but unavailable (failure, unsupported, missing basis): `—`.
        case unavailable
        /// An integer percentage in 0...100.
        case percent(Int)
    }

    /// Why the battery widget shows its green bolt. The image is the same; the reason only changes VoiceOver.
    enum Bolt: Equatable {
        case none
        /// The battery reports that it is charging.
        case charging
        /// External power is connected and the battery is really full (raw capacity, not a rounded 100).
        case fullOnExternalPower
    }

    let widget: SystemWidget
    let value: Value
    /// Battery only: a green bolt left of the number, only with a known charge level (Doc/SYSTEM-MONITOR.md §7.1).
    /// There is no battery outline in any state.
    var bolt: Bolt = .none

    var showsBolt: Bool { bolt != .none }

    /// `24%`, or `—` without a `%` sign.
    var text: String {
        if case .percent(let percent) = value { return "\(percent)%" }
        return "—"
    }

    var isDimmed: Bool { value == .loading }

    /// VoiceOver text for the menu bar item, e.g. "CPU 24%", "배터리 82%, 충전 중", "GPU 측정 불가".
    var accessibilityText: String {
        let name = widget == .battery ? "배터리" : widget.title
        switch value {
        case .loading: return "\(name) 측정 중"
        case .unavailable: return "\(name) 측정 불가"
        case .percent(let percent):
            switch bolt {
            case .none: return "\(name) \(percent)%"
            case .charging: return "\(name) \(percent)%, 충전 중"
            case .fullOnExternalPower: return "\(name) \(percent)%, 전원 연결됨"
            }
        }
    }
}

/// The four battery states the widget tells apart (§7.6).
enum BatteryDisplayState: Equatable {
    case notMeasured
    case noBattery
    /// Any other unavailable reason, e.g. a transient read failure.
    case unavailable(SystemMetricUnavailableReason)
    /// `isCharging` and `isFullOnExternalPower` are true only when the battery reports them; unknown is false.
    case measured(percent: Int?, isCharging: Bool, isFullOnExternalPower: Bool)
}

/// Converts store values into widget text and chart data. Pure functions.
enum SystemWidgetPresentation {
    /// System usage for the menu bar: rounded to an integer and kept in 0...100. Not for per-process CPU, which
    /// may exceed 100 (`processCPUText`).
    static func usagePercent(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(min(max(value, 0), 100).rounded())
    }

    private static func display(_ widget: SystemWidget, _ percent: Double??) -> SystemWidgetDisplay {
        guard let measured = percent else { return SystemWidgetDisplay(widget: widget, value: .loading) }
        guard let value = measured, let rounded = usagePercent(value) else {
            return SystemWidgetDisplay(widget: widget, value: .unavailable)
        }
        return SystemWidgetDisplay(widget: widget, value: .percent(rounded))
    }

    static func cpu(_ metric: SystemMetric<CPUUsage>?) -> SystemWidgetDisplay {
        display(.cpu, metric.map { $0.value?.totalPercent })
    }

    static func memory(_ metric: SystemMetric<MemoryUsage>?) -> SystemWidgetDisplay {
        display(.memory, metric.map { $0.value.map { $0.usedFraction * 100 } })
    }

    /// A failed GPU read is `—`, never 0 %.
    static func gpu(_ metric: SystemMetric<Double>?) -> SystemWidgetDisplay {
        display(.gpu, metric.map(\.value))
    }

    static func disk(_ metric: SystemMetric<DiskUsage>?) -> SystemWidgetDisplay {
        display(.disk, metric.map { $0.value.flatMap(diskUsedPercent) })
    }

    /// Menu bar Disk usage (§7.5): (total − available for important usage) ÷ total × 100, the basis close to
    /// System Settings > Storage. Nil when that value is unavailable; deliberately **not** replaced by the
    /// conservative `DiskUsage.usedFraction`, which would make the number jump by about 5 points.
    static func diskUsedPercent(_ disk: DiskUsage) -> Double? {
        guard disk.totalBytes > 0, let important = disk.availableForImportantUsageBytes.value,
              important <= disk.totalBytes else { return nil }
        return Double(disk.totalBytes - important) / Double(disk.totalBytes) * 100
    }

    static func batteryState(_ metric: SystemMetric<BatteryPowerState>?) -> BatteryDisplayState {
        switch metric {
        case nil:
            return .notMeasured
        case .unavailable(.noBattery):
            return .noBattery
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let power):
            return .measured(percent: power.chargePercent.value, isCharging: power.isCharging == .available(true),
                             isFullOnExternalPower: power.isExternalPowerConnected == .available(true)
                                 && power.isAtFullCapacity == .available(true))
        }
    }

    /// The bolt policy (Doc/SYSTEM-MONITOR.md §7.1):
    /// - on battery: `82%`
    /// - actually charging: `⚡82%`
    /// - external power and really full: `⚡100%` (a 99.6 % battery rounded to 100 is not full: `100%`)
    /// - external power, not full, not charging (charge held): `82%`
    /// - a state that is unknown never adds the bolt
    /// - no charge level: `—` without a bolt, whatever else is known
    static func battery(_ metric: SystemMetric<BatteryPowerState>?) -> SystemWidgetDisplay {
        switch batteryState(metric) {
        case .notMeasured:
            return SystemWidgetDisplay(widget: .battery, value: .loading)
        case .noBattery, .unavailable:
            return SystemWidgetDisplay(widget: .battery, value: .unavailable)
        case .measured(let percent, let isCharging, let isFullOnExternalPower):
            guard let rounded = percent.flatMap({ usagePercent(Double($0)) }) else {
                return SystemWidgetDisplay(widget: .battery, value: .unavailable)
            }
            let bolt: SystemWidgetDisplay.Bolt = isCharging ? .charging : isFullOnExternalPower ? .fullOnExternalPower : .none
            return SystemWidgetDisplay(widget: .battery, value: .percent(rounded), bolt: bolt)
        }
    }

    @MainActor
    static func display(_ widget: SystemWidget, store: SystemMonitorStore) -> SystemWidgetDisplay {
        switch widget {
        case .cpu: cpu(store.cpu)
        case .memory: memory(store.memory)
        case .battery: battery(store.batteryPower)
        case .disk: disk(store.disk)
        case .gpu: gpu(store.gpu)
        }
    }

    // MARK: CPU popover

    /// CPU load wording for the popover header. Words, not only colour, and never "danger": high CPU use is
    /// normal work. Boundaries: below 40 → relaxed, 40 up to below 80 → normal, 80 and above → high.
    enum CPULoad: Equatable {
        case relaxed, normal, high

        var text: String {
            switch self {
            case .relaxed: "여유"
            case .normal: "보통"
            case .high: "높음"
            }
        }
    }

    /// From the unrounded total, so 39.9 % is relaxed although the header shows `40`.
    static func cpuLoad(_ percent: Double?) -> CPULoad? {
        guard let percent, percent.isFinite else { return nil }
        if percent >= 80 { return .high }
        if percent >= 40 { return .normal }
        return .relaxed
    }

    /// One row of the CPU popover's TOP 5: highest first, at most five, per-core percent text.
    struct CPUTopRow: Equatable {
        let pid: Int32
        let startTicks: UInt64
        let name: String
        let percentText: String
    }

    static func cpuTopRows(_ entries: [ProcessCPUEntry]) -> [CPUTopRow] {
        entries.sorted { $0.percent == $1.percent ? $0.pid < $1.pid : $0.percent > $1.percent }
            .prefix(5)
            .map { CPUTopRow(pid: $0.pid, startTicks: $0.startTicks, name: $0.name, percentText: processCPUText($0.percent)) }
    }

    // MARK: GPU popover

    /// Big number of the GPU popover: the same rounding as the menu bar widget (`gpu(_:)`), so both agree. A
    /// failed read is "—" with "확인 불가", never 0; before the first window it is "—" with "측정 중".
    static func gpuHeadline(_ metric: SystemMetric<Double>?) -> (value: String, note: String?) {
        switch metric {
        case nil: return ("—", "측정 중")
        case .unavailable?: return ("—", "확인 불가")
        case .available(let percent)?:
            guard let rounded = usagePercent(percent) else { return ("—", "확인 불가") }
            return ("\(rounded)", nil)
        }
    }

    static let gpuExperimentalHelp = "GPU 사용률은 macOS의 문서화되지 않은 시스템 값에 기반한 실험적 측정치입니다. 다른 모니터링 앱과 수치가 다를 수 있습니다."

    // MARK: RAM popover

    /// The four parts of the RAM composition bar. App (anonymous − purgeable), wired and compressed (pages held by
    /// the compressor) are disjoint page sets whose sum is `usedBytes`, the same value as the usage percent;
    /// "available" is total − used: free pages, cached files and pages macOS does not classify, all of which it can
    /// hand out. The four sum to exactly `totalBytes`.
    struct MemoryPart: Equatable {
        enum Kind: Equatable { case app, wired, compressed, available }
        let kind: Kind
        let bytes: UInt64
        let fraction: Double

        var title: String {
            switch kind {
            case .app: "앱 메모리"
            case .wired: "와이어드"
            case .compressed: "압축"
            case .available: "사용 가능"
            }
        }
    }

    static func memoryComposition(_ memory: MemoryUsage) -> [MemoryPart] {
        guard memory.totalBytes > 0, memory.usedBytes <= memory.totalBytes else { return [] }
        let total = Double(memory.totalBytes)
        return [(MemoryPart.Kind.app, memory.appBytes), (.wired, memory.wiredBytes), (.compressed, memory.compressedBytes),
                (.available, memory.totalBytes - memory.usedBytes)]
            .map { MemoryPart(kind: $0.0, bytes: $0.1, fraction: Double($0.1) / total) }
    }

    static let memoryAvailableHelp = "사용 가능 = 전체 − 사용(앱 메모리 + 와이어드 + 압축)입니다. 비어 있는 메모리와 캐시된 파일처럼 macOS가 필요하면 바로 내줄 수 있는 메모리가 포함됩니다."

    static let memoryTopHelp = "프로세스 메모리는 각 프로세스가 실제로 차지한 메모리(phys_footprint, 활동 모니터의 \"메모리\" 열과 같은 기준)입니다. 공유 메모리 등이 있어 합계가 위의 사용량과 같지 않습니다. 권한에 따라 일부 프로세스는 표시되지 않을 수 있습니다."

    /// Pressure wording: never inferred from usage; an unreadable level is "확인 불가", never "정상".
    static func memoryPressureText(_ pressure: SystemMetric<MemoryPressure>?) -> String {
        switch pressure {
        case .available(.normal)?: "정상"
        case .available(.warning)?: "주의"
        case .available(.critical)?: "높음"
        default: "확인 불가"
        }
    }

    struct MemoryTopRow: Equatable {
        let pid: Int32
        let startTicks: UInt64
        let name: String
        let bytesText: String
    }

    /// Largest footprint first, at most five.
    static func memoryTopRows(_ entries: [ProcessMemoryEntry]) -> [MemoryTopRow] {
        entries.sorted { $0.footprintBytes == $1.footprintBytes ? $0.pid < $1.pid : $0.footprintBytes > $1.footprintBytes }
            .prefix(5)
            .map { MemoryTopRow(pid: $0.pid, startTicks: $0.startTicks, name: $0.name, bytesText: processMemoryText($0.footprintBytes)) }
    }

    // MARK: Process TOP 5

    /// Percent of one core, like Activity Monitor: one decimal, **not** capped at 100 (a multithreaded process
    /// can exceed it). Not the AI 0...100 formatter.
    static func processCPUText(_ percent: Double) -> String {
        guard percent.isFinite, percent >= 0 else { return "—" }
        return String(format: "%.1f%%", percent)
    }

    static func processMemoryText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    // MARK: Charts

    /// One unbroken run of measured points, drawn as its own line so a failure never joins its neighbours.
    struct ChartSegment: Equatable {
        struct Point: Equatable {
            let date: Date
            let value: Double
        }

        let points: [Point]
    }

    /// Longest time between two neighbouring measured points that is still drawn as one line: 2.5 × the 1 s
    /// sampling interval, so timer jitter and one skipped tick stay joined while longer pauses are not.
    static let chartMaxGap: TimeInterval = 2.5

    /// Splits a history into lines (review M1). A line ends at a gap (`nil` = not measured) and also where two
    /// neighbouring measured points are more than `maxGap` apart: sleep, a stalled timer or a dropped GPU window
    /// leave time without any point at all, and joining across it would draw values that were never measured.
    /// Exactly `maxGap` stays joined. A measured 0 % is a point; a gap is never 0 %. The history is not changed.
    static func segments(_ history: SystemMetricHistory, maxGap: TimeInterval = chartMaxGap) -> [ChartSegment] {
        var segments: [ChartSegment] = []
        var current: [ChartSegment.Point] = []
        func close() {
            if !current.isEmpty { segments.append(ChartSegment(points: current)) }
            current = []
        }
        for point in history.points {
            guard let value = point.value else { close(); continue }
            if let last = current.last, point.date.timeIntervalSince(last.date) > maxGap { close() }
            current.append(.init(date: point.date, value: value))
        }
        close()
        return segments
    }
}
