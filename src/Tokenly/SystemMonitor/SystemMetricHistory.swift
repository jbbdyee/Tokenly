import Foundation

/// The last 60 seconds of one metric, kept in memory only. Unavailable samples are stored as gaps (`nil`), never as 0.
struct SystemMetricHistory: Equatable {
    struct Point: Equatable {
        let date: Date
        let value: Double?
    }

    static let window: TimeInterval = 60

    /// Upper bound independent of timing, so jittery or bursty sampling can never grow the buffer.
    let capacity: Int
    private(set) var points: [Point] = []

    init(capacity: Int = 60) {
        self.capacity = capacity
    }

    mutating func append(_ value: Double?, at date: Date) {
        // A clock moved backwards makes every stored age meaningless; start over rather than draw a folded graph.
        if let last = points.last, date < last.date { points.removeAll() }
        points.append(Point(date: date, value: value))
        points.removeAll { date.timeIntervalSince($0.date) >= Self.window }
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }

    mutating func removeAll() {
        points.removeAll()
    }
}
