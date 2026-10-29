import Foundation
import IOKit.ps

/// A running timer or observer. `cancel()` is idempotent, and releasing the object cancels it.
protocol SystemMonitorCancellable: AnyObject {
    func cancel()
}

/// Time and event sources for SystemMonitorStore. Injectable so tests can fire them deterministically.
@MainActor
protocol SystemMonitorScheduling {
    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable
    /// Fires once after `delay` seconds (0 or less fires on the next run-loop pass).
    func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable
    /// Fires when any power source changes (plug/unplug, charge level, charging state).
    func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable
}

@MainActor
final class LiveSystemMonitorScheduler: SystemMonitorScheduling {
    func repeating(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { action() } }
        // Lets macOS coalesce wakeups with other timers; a 1 s graph does not need exact spacing.
        timer.tolerance = interval * 0.1
        // Common modes keep sampling while menus or the popover track events.
        RunLoop.main.add(timer, forMode: .common)
        return TimerJob(timer: timer)
    }

    func once(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        let timer = Timer(timeInterval: max(delay, 0), repeats: false) { _ in MainActor.assumeIsolated { action() } }
        // Small enough to keep a GPU read inside its 100 ms slot (offsets stay 5 ms from the edges).
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        return TimerJob(timer: timer)
    }

    func onPowerSourceChange(_ action: @escaping @MainActor () -> Void) -> any SystemMonitorCancellable {
        PowerSourceObserver(action: action)
    }
}

private final class TimerJob: SystemMonitorCancellable {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    deinit { cancel() }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// IOPSNotificationCreateRunLoopSource on the main run loop. The callback context is this object, unretained; the
/// source is removed in `cancel()`/`deinit`, before the object goes away, so the callback never sees a freed context.
private final class PowerSourceObserver: SystemMonitorCancellable {
    private let action: @MainActor () -> Void
    private var source: CFRunLoopSource?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.action() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    deinit { cancel() }

    func cancel() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }
}
