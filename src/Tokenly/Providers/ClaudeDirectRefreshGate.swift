import Foundation

/// A conservative gate for the development app. The five-minute interval is an initial
/// experiment policy, not an Anthropic published minimum or a production polling contract.
actor ClaudeDirectRefreshGate {
    private(set) var nextEligibleAt: Date?
    private(set) var isPaused = false
    private(set) var isInFlight = false
    private var transientFailures = 0

    func begin(at now: Date) -> Bool {
        guard !isPaused, !isInFlight,
              nextEligibleAt.map({ now >= $0 }) ?? true else { return false }
        isInFlight = true
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
            nextEligibleAt = now.addingTimeInterval(300)
            return
        }
        switch error as? ClaudeUsageRunnerError {
        case .authenticationRequired, .permissionDenied, .unavailable, .incompatibleSDK, .sdkFailure:
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
