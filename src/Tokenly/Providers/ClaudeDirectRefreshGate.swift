import Darwin
import Foundation

/// Rate limit reported by the helper. `retryAfter` is the server's Retry-After in seconds when the
/// helper could read one; it never carries response text.
struct ClaudeRateLimitError: Error, Equatable {
    let retryAfter: TimeInterval?
}

/// Non-sensitive failure class kept in the checkpoint. Raw values are stored, so keep them stable.
enum ClaudeRefreshErrorKind: String, Equatable {
    case network, timeout, transport, sdkFailure, unavailable, unsafeOutput, inProgress
    case interrupted, unknown, cancelled
    case authentication, permission, rateLimited, incompatibleSDK, unexpectedModelActivity
    case clockChanged, legacyPause

    init(_ error: Error) {
        if error is CancellationError { self = .cancelled; return }
        if error is ClaudeRateLimitError { self = .rateLimited; return }
        switch error as? ClaudeUsageRunnerError {
        case .network: self = .network
        case .timeout: self = .timeout
        case .transport: self = .transport
        case .sdkFailure: self = .sdkFailure
        case .unavailable: self = .unavailable
        case .unsafeOutput: self = .unsafeOutput
        case .inProgress: self = .inProgress
        case .authenticationRequired: self = .authentication
        case .permissionDenied: self = .permission
        case .rateLimited: self = .rateLimited
        case .incompatibleSDK: self = .incompatibleSDK
        case .unexpectedModelActivity: self = .unexpectedModelActivity
        case nil: self = .unknown
        }
    }
}

/// Why automatic SDK refresh stopped. Only `unexpectedModelActivity` refuses a manual retry.
enum ClaudeRefreshPauseReason: String, Equatable {
    case authenticationRequired, permissionDenied, incompatibleSDK, unexpectedModelActivity
    case repeatedFailures, clockChanged, checkpointUnavailable
}

struct ClaudeDirectRefreshStatus: Equatable {
    enum Phase: Equatable {
        case ready
        case inFlight
        /// Backoff or cooldown after a transient failure; resumes automatically.
        case retryWaiting(until: Date)
        case rateLimited(until: Date)
        case paused(ClaudeRefreshPauseReason)
    }
    var phase: Phase
    var lastSuccessAt: Date?
    var lastErrorKind: ClaudeRefreshErrorKind?

    /// The direct SDK route is not delivering fresh data and the popover should say so.
    var isInterrupted: Bool {
        switch phase {
        case .ready, .inFlight: return false
        case .retryWaiting, .rateLimited, .paused: return true
        }
    }
}

enum ClaudeManualRetryDecision: Equatable {
    enum Refusal: Equatable {
        case inFlight, tooSoon(until: Date), rateLimited(until: Date), safetyStop, limitedTrial
        case checkpointUnavailable
    }
    /// The next fetch may start an SDK request now.
    case allowed
    /// Automatic refresh is healthy; the regular interval still applies.
    case notNeeded
    case refused(Refusal)
}

/// The interval is supplied by the route; neither 60 nor 300 seconds is an Anthropic published minimum.
/// A non-sensitive checkpoint preserves eligibility and failure state across launches.
///
/// Recovery policy (unlimited routes only; limited account trials keep their stop-on-failure budget):
/// transient failures back off 5 then 10 minutes; the third in a row starts a 30-minute cooldown, and the
/// third cooldown pauses until a manual retry. Rate limits wait for Retry-After (60 s–6 h) or 30 minutes
/// doubling to 6 hours, and resume automatically. Authentication, permission and SDK-shape failures pause
/// until a manual retry; unexpected model activity pauses and refuses manual retry.
actor ClaudeDirectRefreshGate {
    static let maximumTransientFailures = 3
    static let transientBackoff: [TimeInterval] = [5 * 60, 10 * 60]
    static let cooldown: TimeInterval = 30 * 60
    static let maximumCooldowns = 3
    static let defaultRateLimitWait: TimeInterval = 30 * 60
    static let maximumRateLimitWait: TimeInterval = 6 * 3600
    static let minimumRateLimitWait: TimeInterval = 60
    /// A helper is killed after 30 s; an in-flight marker this old belongs to an interrupted process.
    static let staleInFlight: TimeInterval = 10 * 60
    static let manualRetrySpacing: TimeInterval = 60

    private let maxAttempts: Int?
    private let stopOnFailure: Bool
    private let pauseOnUnknownError: Bool
    private let successInterval: TimeInterval
    private let reservationDirectory: URL?
    private let checkpointURL: URL?
    private var state = ClaudeRefreshCheckpoint()

    var nextEligibleAt: Date? { state.nextEligibleAt }
    var automaticNextEligibleAt: Date? {
        state.isPaused || state.isInFlight ? nil : state.nextEligibleAt
    }
    var isPaused: Bool { state.isPaused }
    var isInFlight: Bool { state.isInFlight }

    init(maxAttempts: Int? = nil, stopOnFailure: Bool = false, pauseOnUnknownError: Bool = false,
         successInterval: TimeInterval = 300,
         reservationDirectory: URL? = nil, checkpointURL: URL? = nil) {
        self.maxAttempts = maxAttempts
        self.stopOnFailure = stopOnFailure
        self.pauseOnUnknownError = pauseOnUnknownError
        self.successInterval = max(60, successInterval)
        self.reservationDirectory = reservationDirectory
        self.checkpointURL = checkpointURL
    }

    /// Limited account trials never resume automatically or manually.
    private var isLimitedTrial: Bool { maxAttempts != nil || stopOnFailure || reservationDirectory != nil }

    func begin(at now: Date) -> Bool {
        if let checkpointURL {
            do {
                let (updated, accepted) = try ClaudeRefreshCheckpointFile.transact(at: checkpointURL) { stored in
                    // Limited account trials must not resume a partly consumed budget in a new app process.
                    if reservationDirectory != nil && state.attempts == 0 && stored.attempts > 0 {
                        return false
                    }
                    recover(&stored, at: now)
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
                state.pause(.checkpointUnavailable)
                return false
            }
        }
        recover(&state, at: now)
        guard eligible(state, at: now), reserveAttempt(number: state.attempts + 1) else { return false }
        state.attempts += 1
        state.lastAttemptAt = now
        state.isInFlight = true
        return true
    }

    /// Reloads the checkpoint (applying the same recovery as `begin`) and describes it for the popover.
    func status(at now: Date) -> ClaudeDirectRefreshStatus {
        if let checkpointURL {
            if let result = try? ClaudeRefreshCheckpointFile.transact(at: checkpointURL, { stored in
                recover(&stored, at: now)
                return true
            }) {
                state = result.0
            } else {
                state.pause(.checkpointUnavailable)
            }
        } else {
            recover(&state, at: now)
        }
        return describe(state, at: now)
    }

    /// Clears a transient wait or a pause that a person can resolve (login, permission, update,
    /// repeated failures) so the next fetch may run. Safety stops, active rate limits, a request in
    /// flight and retries within a minute of the last attempt are refused.
    func prepareManualRetry(at now: Date) -> ClaudeManualRetryDecision {
        guard !isLimitedTrial else { return .refused(.limitedTrial) }
        if let checkpointURL {
            var decision = ClaudeManualRetryDecision.refused(.checkpointUnavailable)
            guard let result = try? ClaudeRefreshCheckpointFile.transact(at: checkpointURL, { stored in
                recover(&stored, at: now)
                decision = manualRetry(&stored, at: now)
                return true
            }) else { return .refused(.checkpointUnavailable) }
            state = result.0
            return decision
        }
        recover(&state, at: now)
        return manualRetry(&state, at: now)
    }

    private func manualRetry(_ value: inout ClaudeRefreshCheckpoint, at now: Date) -> ClaudeManualRetryDecision {
        if value.isInFlight { return .refused(.inFlight) }
        if value.isPaused && value.pause == .unexpectedModelActivity { return .refused(.safetyStop) }
        if value.errorKind == .rateLimited, let until = value.nextEligibleAt, until > now {
            return .refused(.rateLimited(until: until))
        }
        let interrupted = value.isPaused || value.errorKind != nil
        guard interrupted else {
            return (value.nextEligibleAt.map { now >= $0 } ?? true) ? .allowed : .notNeeded
        }
        if let last = value.lastAttemptAt, now < last.addingTimeInterval(Self.manualRetrySpacing) {
            return .refused(.tooSoon(until: last.addingTimeInterval(Self.manualRetrySpacing)))
        }
        if value.isPaused {
            // A manual retry gets one more bounded round: the next transient streak pauses again.
            value.isPaused = false
            value.pause = nil
            value.transientFailures = 0
            value.cooldownCycles = Self.maximumCooldowns - 1
        }
        value.nextEligibleAt = now
        return .allowed
    }

    private func eligible(_ value: ClaudeRefreshCheckpoint, at now: Date) -> Bool {
        !value.isPaused && !value.isInFlight &&
            (maxAttempts.map { value.attempts < $0 } ?? true) &&
            (value.lastAttemptAt.map { now >= $0 } ?? true) &&
            (value.nextEligibleAt.map { now >= $0 } ?? true)
    }

    /// Repairs states that v0.4.0 could never leave. Limited trials keep their fail-closed behavior.
    private func recover(_ value: inout ClaudeRefreshCheckpoint, at now: Date) {
        guard !isLimitedTrial else { return }
        if value.isPaused && value.pause == nil {
            // A v0.4.0 pause has no recorded cause. Allow one automatic attempt after a cooldown; another
            // transient failure pauses again with a recorded reason, and a safety failure stops for good.
            value.isPaused = false
            value.errorKind = .legacyPause
            value.transientFailures = Self.maximumTransientFailures - 1
            value.cooldownCycles = Self.maximumCooldowns - 1
            value.nextEligibleAt = (value.lastAttemptAt ?? now).addingTimeInterval(Self.cooldown)
        }
        if value.isInFlight, let started = value.lastAttemptAt,
           now >= started.addingTimeInterval(Self.staleInFlight) {
            value.isInFlight = false
            advance(&value, kind: .interrupted, error: nil, at: now)
        }
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
                    finish(&stored, error: error, at: now)
                    return true
                }
                state = updated
            } catch {
                // The durable in-flight marker remains, blocking a restart after an uncertain finish.
                state.pause(.checkpointUnavailable)
                state.isInFlight = false
            }
        } else {
            finish(&state, error: error, at: now)
        }
    }

    private func finish(_ value: inout ClaudeRefreshCheckpoint, error: Error?, at now: Date) {
        value.isInFlight = false
        guard value.lastAttemptAt.map({ now >= $0 }) ?? false else {
            value.errorKind = .clockChanged
            value.pause(.clockChanged)
            return
        }
        guard let error else {
            value.transientFailures = 0
            value.cooldownCycles = nil
            value.rateLimitHits = nil
            value.errorKind = nil
            value.lastErrorAt = nil
            value.lastSuccessAt = now
            value.nextEligibleAt = now.addingTimeInterval(successInterval)
            return
        }
        advance(&value, kind: ClaudeRefreshErrorKind(error), error: error, at: now)
    }

    private func advance(_ value: inout ClaudeRefreshCheckpoint, kind: ClaudeRefreshErrorKind,
                         error: Error?, at now: Date) {
        value.errorKind = kind
        value.lastErrorAt = now
        if kind == .cancelled {
            if stopOnFailure { value.pause(nil); return }
            value.nextEligibleAt = now.addingTimeInterval(300)
            return
        }
        if stopOnFailure { value.pause(nil); return }
        if isLimitedTrial {
            // Limited trials keep the v0.4.0 conservative policy: pause on any classified failure.
            if [.network, .timeout, .transport, .inProgress, .unsafeOutput].contains(kind) {
                value.transientFailures += 1
                guard value.transientFailures < Self.maximumTransientFailures else { value.pause(nil); return }
                value.nextEligibleAt = now.addingTimeInterval(Self.transientBackoff[value.transientFailures - 1])
            } else {
                value.pause(nil)
            }
            return
        }
        switch kind {
        case .authentication: value.pause(.authenticationRequired)
        case .permission: value.pause(.permissionDenied)
        case .incompatibleSDK: value.pause(.incompatibleSDK)
        case .unexpectedModelActivity: value.pause(.unexpectedModelActivity)
        case .rateLimited:
            let hits = (value.rateLimitHits ?? 0) + 1
            value.rateLimitHits = hits
            let wait: TimeInterval
            if let retryAfter = (error as? ClaudeRateLimitError)?.retryAfter, retryAfter.isFinite {
                wait = min(max(retryAfter, Self.minimumRateLimitWait), Self.maximumRateLimitWait)
            } else {
                wait = min(Self.defaultRateLimitWait * pow(2, Double(min(hits - 1, 8))),
                           Self.maximumRateLimitWait)
            }
            value.nextEligibleAt = now.addingTimeInterval(max(wait, successInterval))
        default:
            value.transientFailures += 1
            if pauseOnUnknownError && kind == .unknown {
                // An unclassified failure skips the short backoff and goes straight to a cooldown.
                value.transientFailures = Self.maximumTransientFailures
            }
            if value.transientFailures < Self.maximumTransientFailures {
                value.nextEligibleAt = now.addingTimeInterval(Self.transientBackoff[value.transientFailures - 1])
                return
            }
            value.transientFailures = 0
            let cooldowns = (value.cooldownCycles ?? 0) + 1
            value.cooldownCycles = cooldowns
            if cooldowns >= Self.maximumCooldowns {
                value.pause(.repeatedFailures)
            } else {
                value.nextEligibleAt = now.addingTimeInterval(Self.cooldown)
            }
        }
    }

    private func describe(_ value: ClaudeRefreshCheckpoint, at now: Date) -> ClaudeDirectRefreshStatus {
        let phase: ClaudeDirectRefreshStatus.Phase
        if value.isPaused {
            phase = .paused(value.pause ?? .repeatedFailures)
        } else if value.isInFlight {
            phase = .inFlight
        } else if let until = value.nextEligibleAt, until > now, value.errorKind == .rateLimited {
            phase = .rateLimited(until: until)
        } else if let until = value.nextEligibleAt, until > now, let kind = value.errorKind, kind != .cancelled {
            phase = .retryWaiting(until: until)
        } else {
            phase = .ready
        }
        return ClaudeDirectRefreshStatus(phase: phase, lastSuccessAt: value.lastSuccessAt,
                                         lastErrorKind: value.errorKind)
    }
}

/// No account data, SDK response, token, or error text is stored here. Fields added in v0.4.1 are
/// optional strings/numbers so v0.4.0 checkpoints decode unchanged and v0.4.0 ignores them.
private struct ClaudeRefreshCheckpoint: Codable, Equatable {
    var schemaVersion = 1
    var attempts = 0
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var nextEligibleAt: Date?
    var transientFailures = 0
    var isPaused = false
    var isInFlight = false
    var lastErrorKind: String?
    var lastErrorAt: Date?
    var pauseReason: String?
    var cooldownCycles: Int?
    var rateLimitHits: Int?

    var errorKind: ClaudeRefreshErrorKind? {
        get { lastErrorKind.flatMap(ClaudeRefreshErrorKind.init(rawValue:)) }
        set { lastErrorKind = newValue?.rawValue }
    }
    var pause: ClaudeRefreshPauseReason? {
        get { pauseReason.flatMap(ClaudeRefreshPauseReason.init(rawValue:)) }
        set { pauseReason = newValue?.rawValue }
    }
    /// `nil` keeps the v0.4.0 meaning (limited trials): stopped without a resumable reason.
    mutating func pause(_ reason: ClaudeRefreshPauseReason?) {
        isPaused = true
        pause = reason
        nextEligibleAt = nil
    }

    var isValid: Bool {
        schemaVersion == 1 && attempts >= 0 && transientFailures >= 0 &&
            (cooldownCycles ?? 0) >= 0 && (rateLimitHits ?? 0) >= 0 &&
            (!isInFlight || lastAttemptAt != nil) &&
            (lastSuccessAt == nil || lastAttemptAt != nil)
    }
}

/// A separate flock file serializes read-modify-write across app processes. An interrupted
/// in-flight checkpoint stays blocked until it is older than `staleInFlight`.
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
