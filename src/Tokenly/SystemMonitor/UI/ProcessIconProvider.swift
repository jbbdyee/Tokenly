import AppKit

/// App icons for the CPU popover's TOP 5, by process identity, never by name.
///
/// A process gets its app's icon only when macOS knows it as a running application with an `.app` bundle and a
/// non-prohibited activation policy (`NSRunningApplication(processIdentifier:)`). Daemons, WindowServer and helper
/// processes such as WebKit's get the shared generic icon instead of a guessed one. Results are cached per
/// (PID, start time), so a reused PID is looked up again, and entries for processes that left the list are dropped.
@MainActor
final class ProcessIconProvider {
    struct Key: Hashable {
        let pid: Int32
        let startTicks: UInt64
    }

    private let lookup: (Int32) -> NSImage?
    /// `nil` value: looked up, no app icon (generic).
    private var cache: [Key: NSImage?] = [:]
    /// Lookups performed, for tests and cost checks.
    private(set) var lookupCount = 0

    init(lookup: @escaping (Int32) -> NSImage? = ProcessIconProvider.runningApplicationIcon) {
        self.lookup = lookup
    }

    /// The app icon, or nil for "use the generic icon".
    func icon(pid: Int32, startTicks: UInt64) -> NSImage? {
        let key = Key(pid: pid, startTicks: startTicks)
        if let cached = cache[key] { return cached }
        lookupCount += 1
        let image = lookup(pid)
        cache[key] = image
        return image
    }

    /// Keeps only the processes currently listed.
    func retain(_ keys: Set<Key>) {
        cache = cache.filter { keys.contains($0.key) }
    }

    var cachedKeys: Set<Key> { Set(cache.keys) }

    nonisolated static func runningApplicationIcon(_ pid: Int32) -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy != .prohibited, let url = app.bundleURL, url.pathExtension == "app" else { return nil }
        return app.icon
    }
}
