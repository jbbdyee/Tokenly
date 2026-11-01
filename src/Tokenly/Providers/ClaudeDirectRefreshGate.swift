import Darwin
import Foundation

/// A conservative gate for the development app. The five-minute interval is an initial
/// experiment policy, not an Anthropic published minimum or a production polling contract.
actor ClaudeDirectRefreshGate {
    private let maxAttempts: Int?
    private let stopOnFailure: Bool
    private let reservationDirectory: URL?
    private var attempts = 0
    private(set) var nextEligibleAt: Date?
    private(set) var isPaused = false
    private(set) var isInFlight = false
    private var transientFailures = 0

    init(maxAttempts: Int? = nil, stopOnFailure: Bool = false,
         reservationDirectory: URL? = nil) {
        self.maxAttempts = maxAttempts
        self.stopOnFailure = stopOnFailure
        self.reservationDirectory = reservationDirectory
    }

    func begin(at now: Date) -> Bool {
        guard !isPaused, !isInFlight,
              maxAttempts.map({ attempts < $0 }) ?? true,
              nextEligibleAt.map({ now >= $0 }) ?? true else { return false }
        if let reservationDirectory {
            guard reserveAttempt(in: reservationDirectory) else { return false }
        }
        attempts += 1
        isInFlight = true
        return true
    }

    /// O_EXCL reserves this gate's next attempt. A restarted app always begins with slot 1;
    /// an existing slot therefore fails closed instead of continuing an uncertain earlier run.
    /// A reservation counts even if process spawn fails.
    private func reserveAttempt(in directory: URL) -> Bool {
        guard let maxAttempts, attempts < maxAttempts else { return false }
        let path = directory.appendingPathComponent("attempt-\(attempts + 1).reserved").path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    func finish(error: Error?, at now: Date) {
        guard isInFlight else { return }
        isInFlight = false
        guard let error else {
            transientFailures = 0
            nextEligibleAt = now.addingTimeInterval(300)
            return
        }
        if error is CancellationError {
            if stopOnFailure { isPaused = true; nextEligibleAt = nil; return }
            nextEligibleAt = now.addingTimeInterval(300)
            return
        }
        if stopOnFailure { isPaused = true; nextEligibleAt = nil; return }
        switch error as? ClaudeUsageRunnerError {
        case .authenticationRequired, .permissionDenied, .unavailable, .incompatibleSDK,
             .sdkFailure, .unexpectedModelActivity:
            isPaused = true
            nextEligibleAt = nil
        case .rateLimited:
            // Retry-After is not exposed by the current helper. Stop instead of guessing.
            isPaused = true
            nextEligibleAt = nil
        default:
            transientFailures += 1
            let minutes = min(5 * (1 << min(transientFailures - 1, 4)), 60)
            nextEligibleAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        }
    }
}
