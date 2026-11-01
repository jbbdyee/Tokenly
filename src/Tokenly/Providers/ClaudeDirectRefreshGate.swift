import Darwin
import Foundation

/// Five minutes is an experiment candidate, not an Anthropic published minimum interval.
/// The checkpoint is used only by explicitly configured development app routes.
actor ClaudeDirectRefreshGate {
    private static let maximumTransientFailures = 3
    private let maxAttempts: Int?
    private let stopOnFailure: Bool
    private let reservationDirectory: URL?
    private let checkpointURL: URL?
    private var state = ClaudeRefreshCheckpoint()

    var nextEligibleAt: Date? { state.nextEligibleAt }
    var isPaused: Bool { state.isPaused }
    var isInFlight: Bool { state.isInFlight }

    init(maxAttempts: Int? = nil, stopOnFailure: Bool = false,
         reservationDirectory: URL? = nil, checkpointURL: URL? = nil) {
        self.maxAttempts = maxAttempts
        self.stopOnFailure = stopOnFailure
        self.reservationDirectory = reservationDirectory
        self.checkpointURL = checkpointURL
    }

    func begin(at now: Date) -> Bool {
        if let checkpointURL {
            do {
                let (updated, accepted) = try ClaudeRefreshCheckpointFile.transact(at: checkpointURL) { stored in
                    guard eligible(stored, at: now), reserveAttempt(number: stored.attempts + 1) else {
                        return false
                    }
                    stored.attempts += 1
                    stored.lastAttemptAt = now
                    stored.isInFlight = true
                    return true
                }
                state = updated
                return accepted
            } catch {
                // A missing/corrupt/unwritable checkpoint must not permit an SDK request.
                state.isPaused = true
                return false
            }
        }
        guard eligible(state, at: now), reserveAttempt(number: state.attempts + 1) else { return false }
        state.attempts += 1
        state.lastAttemptAt = now
        state.isInFlight = true
        return true
    }

    private func eligible(_ value: ClaudeRefreshCheckpoint, at now: Date) -> Bool {
        !value.isPaused && !value.isInFlight &&
            (maxAttempts.map { value.attempts < $0 } ?? true) &&
            (value.lastAttemptAt.map { now >= $0 } ?? true) &&
            (value.nextEligibleAt.map { now >= $0 } ?? true)
    }

    /// A reserved slot counts even if the checkpoint write or process spawn later fails.
    private func reserveAttempt(number: Int) -> Bool {
        guard let reservationDirectory else { return true }
        guard let maxAttempts, number <= maxAttempts else { return false }
        let path = reservationDirectory.appendingPathComponent("attempt-\(number).reserved").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    func finish(error: Error?, at now: Date) {
        guard state.isInFlight else { return }
        if let checkpointURL {
            do {
                let (updated, _) = try ClaudeRefreshCheckpointFile.transact(at: checkpointURL) { stored in
                    guard stored.isInFlight else { return false }
                    advance(&stored, error: error, at: now)
                    return true
                }
                state = updated
            } catch {
                // The durable in-flight marker remains, blocking a restart after an uncertain finish.
                state.isPaused = true
                state.isInFlight = false
            }
        } else {
            advance(&state, error: error, at: now)
        }
    }

    private func advance(_ value: inout ClaudeRefreshCheckpoint, error: Error?, at now: Date) {
        value.isInFlight = false
        guard value.lastAttemptAt.map({ now >= $0 }) ?? false else {
            value.isPaused = true
            value.nextEligibleAt = nil
            return
        }
        guard let error else {
            value.transientFailures = 0
            value.lastSuccessAt = now
            value.nextEligibleAt = now.addingTimeInterval(300)
            return
        }
        if error is CancellationError {
            if stopOnFailure { value.isPaused = true; value.nextEligibleAt = nil; return }
            value.nextEligibleAt = now.addingTimeInterval(300)
            return
        }
        if stopOnFailure { value.isPaused = true; value.nextEligibleAt = nil; return }
        switch error as? ClaudeUsageRunnerError {
        case .authenticationRequired, .permissionDenied, .rateLimited, .unavailable,
             .incompatibleSDK, .sdkFailure, .unexpectedModelActivity:
            value.isPaused = true
            value.nextEligibleAt = nil
        default:
            value.transientFailures += 1
            guard value.transientFailures < Self.maximumTransientFailures else {
                value.isPaused = true
                value.nextEligibleAt = nil
                return
            }
            let minutes = 5 * (1 << (value.transientFailures - 1))
            value.nextEligibleAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        }
    }
}

/// No account data, SDK response, token, or error text is stored here.
private struct ClaudeRefreshCheckpoint: Codable, Equatable {
    var schemaVersion = 1
    var attempts = 0
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var nextEligibleAt: Date?
    var transientFailures = 0
    var isPaused = false
    var isInFlight = false

    var isValid: Bool {
        schemaVersion == 1 && attempts >= 0 && transientFailures >= 0 &&
            (!isInFlight || lastAttemptAt != nil) &&
            (lastSuccessAt == nil || lastAttemptAt != nil)
    }
}

/// A separate flock file serializes read-modify-write across app processes. An interrupted
/// in-flight checkpoint remains in-flight and fails closed on every later launch.
private enum ClaudeRefreshCheckpointFile {
    enum Failure: Error { case unavailable, invalid }

    static func transact(at url: URL,
                         _ change: (inout ClaudeRefreshCheckpoint) -> Bool) throws
        -> (ClaudeRefreshCheckpoint, Bool) {
        guard url.isFileURL, url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw Failure.unavailable
        }
        let lockPath = url.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Failure.unavailable }
        defer { flock(descriptor, LOCK_UN) }

        var current = ClaudeRefreshCheckpoint()
        if FileManager.default.fileExists(atPath: url.path) {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= 4096 else { throw Failure.invalid }
            let data = try Data(contentsOf: url)
            guard let decoded = try? JSONDecoder().decode(ClaudeRefreshCheckpoint.self, from: data),
                  decoded.isValid else { throw Failure.invalid }
            current = decoded
        }
        var updated = current
        let accepted = change(&updated)
        if updated != current {
            guard updated.isValid else { throw Failure.invalid }
            let data = try JSONEncoder().encode(updated)
            guard data.count <= 4096 else { throw Failure.invalid }
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else { throw Failure.unavailable }
        }
        return (updated, accepted)
    }
}
