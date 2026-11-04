import XCTest
@testable import Tokenly

final class ClaudeOptionalUsageTests: XCTestCase {
    private actor SequenceRunner: ClaudeUsageRunning {
        var answers: [Result<Data, ClaudeUsageRunnerError>]
        private(set) var calls = 0
        init(_ answers: [Result<Data, ClaudeUsageRunnerError>]) { self.answers = answers }
        func getUsage() async throws -> Data {
            calls += 1
            guard !answers.isEmpty else { throw ClaudeUsageRunnerError.transport }
            return try answers.removeFirst().get()
        }
    }

    private struct CancelRunner: ClaudeUsageRunning {
        func getUsage() async throws -> Data { throw CancellationError() }
    }

    private struct MockStatusLine: ExternalUsageProvider {
        let id: ExternalProviderID = .claude
        let result: Result<ExternalUsageSnapshot, ExternalProviderError>
        func fetch() async throws -> ExternalUsageSnapshot { try result.get() }
    }

    private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
    private func assertBegin(_ gate: ClaudeDirectRefreshGate, at date: Date,
                             expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await gate.begin(at: date)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private let directJSON = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":20,"resets_at":null},"seven_day":{"utilization":40,"resets_at":null}}}"#.utf8)
    private let partialJSON = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":25,"resets_at":null}}}"#.utf8)

    private func status(_ date: Date, five: Double = 90, seven: Double = 80) -> ExternalUsageSnapshot {
        ExternalUsageSnapshot(metrics: .quotas([
            QuotaMetric(name: "5시간 한도", remainingPercent: five, resetsAt: nil),
            QuotaMetric(name: "7일 한도", remainingPercent: seven, resetsAt: nil),
        ]), fetchedAt: date)
    }

    func testDefaultRouteNeverInvokesDirectRunner() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.success(directJSON)])
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .success(status(clock.date))),
            now: { clock.date })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.source, .statusLine)
        XCTAssertEqual(snapshot.fetchedAt, clock.date)
        let calls = await runner.calls
        XCTAssertEqual(calls, 0)
    }

    func testExplicitRouteUsesDirectAndKeepsSourceTime() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.success(directJSON)])
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .success(status(clock.date.addingTimeInterval(-10)))),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner, now: { clock.date }),
                                       maxAge: 60), now: { clock.date })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.source, .directCLI)
        XCTAssertEqual(snapshot.fetchedAt, clock.date)
        XCTAssertEqual(snapshot.sourceTimes[.directCLI], clock.date)
        XCTAssertEqual(snapshot.sourceTimes[.statusLine], nil)
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("expected quotas") }
        XCTAssertEqual(quotas.map(\.remainingPercent), [80, 60])
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testTwoMockSuccessesAdvanceStoreReceiptOnlyWhenDue() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.success(directJSON), .success(directJSON)])
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .failure(.setupRequired)),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner,
                now: { clock.date }), maxAge: 900), now: { clock.date })
        let name = "tokenly.claude.receipt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ExternalProviderStore(displaySettings: ProviderDisplaySettings(defaults: defaults),
                                          now: { clock.date }, providers: [.claude: provider])
        let firstTask = try XCTUnwrap(store.refresh(.claude))
        await firstTask.value
        guard case .success(let first) = store.state(for: .claude) else {
            return XCTFail("first direct snapshot missing")
        }
        XCTAssertEqual(first.sourceTimes[.directCLI], clock.date)
        clock.date = clock.date.addingTimeInterval(299)
        let earlyTask = try XCTUnwrap(store.refresh(.claude))
        await earlyTask.value
        guard case .success(let early) = store.state(for: .claude) else {
            return XCTFail("cached direct snapshot missing")
        }
        XCTAssertEqual(early.sourceTimes[.directCLI], first.fetchedAt)
        let earlyCalls = await runner.calls
        XCTAssertEqual(earlyCalls, 1)
        clock.date = clock.date.addingTimeInterval(1)
        let secondTask = try XCTUnwrap(store.refresh(.claude))
        await secondTask.value
        guard case .success(let second) = store.state(for: .claude) else {
            return XCTFail("second direct snapshot missing")
        }
        XCTAssertEqual(second.sourceTimes[.directCLI], clock.date)
        XCTAssertGreaterThan(second.fetchedAt, first.fetchedAt)
        let finalCalls = await runner.calls
        XCTAssertEqual(finalCalls, 2)
    }

    func testDirectFailureFallsBackToStatusLine() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.failure(.transport)])
        let feed = status(clock.date.addingTimeInterval(-5))
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .success(feed)),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner), maxAge: 60),
            now: { clock.date })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.source, .statusLine)
        XCTAssertEqual(snapshot.fetchedAt, feed.fetchedAt)
        XCTAssertEqual(snapshot.sourceTimes[.statusLine], feed.fetchedAt)
    }

    func testPreviousDirectSuccessSurvivesFailureWithoutNewTimestamp() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.success(directJSON), .failure(.timeout)])
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .failure(.setupRequired)),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner, now: { clock.date }),
                                       maxAge: 600), now: { clock.date })
        let first = try await provider.fetch()
        clock.date = clock.date.addingTimeInterval(300)
        let second = try await provider.fetch()
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(second.sourceTimes[.directCLI], first.fetchedAt)
        clock.date = clock.date.addingTimeInterval(301)
        do { _ = try await provider.fetch(); XCTFail("old direct data must be stale") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .claudeStaleData) }
    }

    func testPartialDirectUsesStatusLineForOtherWindowAndConservativeTime() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.success(partialJSON)])
        let feed = status(clock.date.addingTimeInterval(-10), five: 99, seven: 70)
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .success(feed)),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner, now: { clock.date }),
                                       maxAge: 60), now: { clock.date })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.source, .statusLine)
        XCTAssertEqual(snapshot.fetchedAt, feed.fetchedAt)
        XCTAssertEqual(snapshot.sourceTimes[.directCLI], clock.date)
        XCTAssertEqual(snapshot.sourceTimes[.statusLine], feed.fetchedAt)
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("expected quotas") }
        XCTAssertEqual(quotas.map(\.remainingPercent), [75, 70])
    }

    func testAutomaticGateWaitsFiveMinutesAndPreventsDuplicateStart() async {
        let gate = ClaudeDirectRefreshGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gateValue1 = await gate.begin(at: start)
        XCTAssertTrue(gateValue1)
        let gateValue2 = await gate.begin(at: start)
        XCTAssertFalse(gateValue2)
        await gate.finish(error: nil, at: start)
        let gateValue3 = await gate.begin(at: start.addingTimeInterval(299))
        XCTAssertFalse(gateValue3)
        let gateValue4 = await gate.begin(at: start.addingTimeInterval(300))
        XCTAssertTrue(gateValue4)
    }

    func testTransientFailuresBackOffThenCoolDownThenPauseWithoutInfiniteRetry() async {
        let gate = ClaudeDirectRefreshGate()
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        for cycle in 1...3 {
            for minutes in [5, 10] {
                await assertBegin(gate, at: time, expected: true)
                await gate.finish(error: ClaudeUsageRunnerError.timeout, at: time)
                await assertBegin(gate, at: time.addingTimeInterval(TimeInterval(minutes * 60 - 1)), expected: false)
                time = time.addingTimeInterval(TimeInterval(minutes * 60))
            }
            await assertBegin(gate, at: time, expected: true)
            await gate.finish(error: ClaudeUsageRunnerError.transport, at: time)
            guard cycle < 3 else { break }
            let waiting = await gate.status(at: time)
            XCTAssertEqual(waiting.phase, .retryWaiting(until: time.addingTimeInterval(1800)))
            await assertBegin(gate, at: time.addingTimeInterval(1799), expected: false)
            time = time.addingTimeInterval(1800)
        }
        let paused = await gate.isPaused
        XCTAssertTrue(paused)
        await assertBegin(gate, at: time.addingTimeInterval(86_400), expected: false)
        let next = await gate.nextEligibleAt
        XCTAssertNil(next)
        let status = await gate.status(at: time.addingTimeInterval(86_400))
        XCTAssertEqual(status.phase, .paused(.repeatedFailures))
        XCTAssertEqual(status.lastErrorKind, .transport)
    }

    func testSuccessResetsTransientFailureCount() async {
        let gate = ClaudeDirectRefreshGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = await gate.begin(at: start)
        XCTAssertTrue(first)
        await gate.finish(error: ClaudeUsageRunnerError.timeout, at: start)
        let second = start.addingTimeInterval(300)
        let secondAttempt = await gate.begin(at: second)
        XCTAssertTrue(secondAttempt)
        await gate.finish(error: nil, at: second)
        let third = second.addingTimeInterval(300)
        let thirdAttempt = await gate.begin(at: third)
        XCTAssertTrue(thirdAttempt)
        await gate.finish(error: ClaudeUsageRunnerError.timeout, at: third)
        let gateValue8 = await gate.nextEligibleAt
        XCTAssertEqual(gateValue8, third.addingTimeInterval(300))
    }

    func testNetworkRecoveryAndPopoverBurstsCannotBypassGate() async {
        let gate = ClaudeDirectRefreshGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = await gate.begin(at: start)
        XCTAssertTrue(first)
        for offset in [0.0, 1, 30, 60] {
            let duplicate = await gate.begin(at: start.addingTimeInterval(offset))
            XCTAssertFalse(duplicate)
        }
        await gate.finish(error: ClaudeUsageRunnerError.transport, at: start)
        for offset in [0.0, 1, 60, 299] {
            let early = await gate.begin(at: start.addingTimeInterval(offset))
            XCTAssertFalse(early)
        }
        let recovered = await gate.begin(at: start.addingTimeInterval(300))
        XCTAssertTrue(recovered)
    }

    func testAccountFailuresPauseButTransientSDKFailuresRetry() async {
        let paused: [(ClaudeUsageRunnerError, ClaudeRefreshPauseReason)] = [
            (.authenticationRequired, .authenticationRequired), (.permissionDenied, .permissionDenied),
            (.incompatibleSDK, .incompatibleSDK), (.unexpectedModelActivity, .unexpectedModelActivity)]
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        for (error, reason) in paused {
            let gate = ClaudeDirectRefreshGate()
            await assertBegin(gate, at: time, expected: true)
            await gate.finish(error: error, at: time)
            let status = await gate.status(at: time.addingTimeInterval(86_400))
            XCTAssertEqual(status.phase, .paused(reason))
            await assertBegin(gate, at: time.addingTimeInterval(86_400), expected: false)
        }
        for error in [ClaudeUsageRunnerError.network, .unavailable, .sdkFailure, .unsafeOutput] {
            let gate = ClaudeDirectRefreshGate()
            await assertBegin(gate, at: time, expected: true)
            await gate.finish(error: error, at: time)
            let isPaused = await gate.isPaused
            XCTAssertFalse(isPaused)
            await assertBegin(gate, at: time.addingTimeInterval(299), expected: false)
            await assertBegin(gate, at: time.addingTimeInterval(300), expected: true)
        }
    }

    func testRateLimitWaitsForRetryAfterThenResumesAndCancellationWaits() async {
        let gate = ClaudeDirectRefreshGate(successInterval: 60)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await assertBegin(gate, at: start, expected: true)
        await gate.finish(error: ClaudeUsageRunnerError.rateLimited, at: start)
        let limited = await gate.status(at: start)
        XCTAssertEqual(limited.phase, .rateLimited(until: start.addingTimeInterval(1800)))
        await assertBegin(gate, at: start.addingTimeInterval(1799), expected: false)
        let second = start.addingTimeInterval(1800)
        await assertBegin(gate, at: second, expected: true)
        await gate.finish(error: ClaudeUsageRunnerError.rateLimited, at: second)
        await assertBegin(gate, at: second.addingTimeInterval(3599), expected: false)
        let third = second.addingTimeInterval(3600)
        await assertBegin(gate, at: third, expected: true)
        await gate.finish(error: ClaudeRateLimitError(retryAfter: 120), at: third)
        await assertBegin(gate, at: third.addingTimeInterval(119), expected: false)
        let fourth = third.addingTimeInterval(120)
        await assertBegin(gate, at: fourth, expected: true)
        await gate.finish(error: ClaudeRateLimitError(retryAfter: 10), at: fourth)
        await assertBegin(gate, at: fourth.addingTimeInterval(59), expected: false)
        let fifth = fourth.addingTimeInterval(60)
        await assertBegin(gate, at: fifth, expected: true)
        await gate.finish(error: ClaudeRateLimitError(retryAfter: 1_000_000), at: fifth)
        await assertBegin(gate, at: fifth.addingTimeInterval(6 * 3600 - 1), expected: false)
        await assertBegin(gate, at: fifth.addingTimeInterval(6 * 3600), expected: true)
        await gate.finish(error: nil, at: fifth.addingTimeInterval(6 * 3600))
        let isPaused = await gate.isPaused
        XCTAssertFalse(isPaused)

        let cancelGate = ClaudeDirectRefreshGate()
        await assertBegin(cancelGate, at: start, expected: true)
        await cancelGate.finish(error: CancellationError(), at: start)
        await assertBegin(cancelGate, at: start.addingTimeInterval(299), expected: false)
        await assertBegin(cancelGate, at: start.addingTimeInterval(300), expected: true)
    }

    func testWakeEligibilityDoesNotBypassMinimumInterval() async {
        let gate = ClaudeDirectRefreshGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = await gate.begin(at: start)
        XCTAssertTrue(initial)
        await gate.finish(error: nil, at: start)
        let earlyWake = await gate.begin(at: start.addingTimeInterval(120))
        XCTAssertFalse(earlyWake)
        let lateWake = await gate.begin(at: start.addingTimeInterval(7200))
        XCTAssertTrue(lateWake)
    }

    func testOneShotGateNeverRetriesAfterSuccessOrFailure() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let outcomes: [Error?] = [nil, ClaudeUsageRunnerError.timeout]
        for failure in outcomes {
            let gate = ClaudeDirectRefreshGate(maxAttempts: 1)
            let first = await gate.begin(at: start)
            XCTAssertTrue(first)
            await gate.finish(error: failure, at: start)
            let later = await gate.begin(at: start.addingTimeInterval(86_400))
            XCTAssertFalse(later)
        }
    }

    func testTwoAttemptGateAllowsOnlySecondSuccessAfterFiveMinutes() async {
        let gate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = await gate.begin(at: start)
        XCTAssertTrue(first)
        let overlap = await gate.begin(at: start)
        XCTAssertFalse(overlap)
        await gate.finish(error: nil, at: start)
        let early = await gate.begin(at: start.addingTimeInterval(299))
        XCTAssertFalse(early)
        let second = await gate.begin(at: start.addingTimeInterval(300))
        XCTAssertTrue(second)
        await gate.finish(error: nil, at: start.addingTimeInterval(300))
        let third = await gate.begin(at: start.addingTimeInterval(86_400))
        XCTAssertFalse(third)
    }

    func testIsolatedSixtySecondTrialCannotRunEarlyOrAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-sixty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(gate, at: start, expected: true)
        await assertBegin(gate, at: start.addingTimeInterval(30), expected: false)
        let completed = start.addingTimeInterval(8)
        await gate.finish(error: nil, at: completed)
        await assertBegin(gate, at: completed.addingTimeInterval(59), expected: false)
        let restarted = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(restarted, at: completed.addingTimeInterval(3_600), expected: false)
        await assertBegin(gate, at: completed.addingTimeInterval(60), expected: true)
        await gate.finish(error: nil, at: completed.addingTimeInterval(65))
        await assertBegin(gate, at: completed.addingTimeInterval(86_400), expected: false)
        let reopened = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(reopened, at: completed.addingTimeInterval(86_400), expected: false)
        let reservations = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".reserved") }
        XCTAssertEqual(reservations.count, 2)
    }

    func testTwoAttemptGateStopsAfterEveryFailureClass() async {
        let failures: [Error] = [ClaudeUsageRunnerError.timeout,
                                 ClaudeUsageRunnerError.authenticationRequired,
                                 ClaudeUsageRunnerError.permissionDenied,
                                 ClaudeUsageRunnerError.rateLimited,
                                 ClaudeUsageRunnerError.sdkFailure,
                                 ClaudeUsageRunnerError.unavailable,
                                 ClaudeUsageRunnerError.incompatibleSDK,
                                 ClaudeUsageRunnerError.transport,
                                 ClaudeUsageRunnerError.unexpectedModelActivity,
                                 ExternalProviderError.noData, CancellationError()]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for failure in failures {
            let gate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true)
            let first = await gate.begin(at: start)
            XCTAssertTrue(first)
            await gate.finish(error: failure, at: start)
            let paused = await gate.isPaused
            XCTAssertTrue(paused)
            let next = await gate.begin(at: start.addingTimeInterval(86_400))
            XCTAssertFalse(next)
        }
    }

    func testTwoAttemptReservationsSurviveNewGateInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-reservations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
                                           reservationDirectory: directory)
        let first = await gate.begin(at: start)
        XCTAssertTrue(first)
        await gate.finish(error: nil, at: start)
        let restartedGate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
                                                    reservationDirectory: directory)
        let restartDenied = await restartedGate.begin(at: start.addingTimeInterval(300))
        XCTAssertFalse(restartDenied)
        let second = await gate.begin(at: start.addingTimeInterval(300))
        XCTAssertTrue(second)
        await gate.finish(error: nil, at: start.addingTimeInterval(300))
        let third = await gate.begin(at: start.addingTimeInterval(86_400))
        XCTAssertFalse(third)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        let missing = ClaudeDirectRefreshGate(maxAttempts: 2, reservationDirectory:
            directory.appendingPathComponent("missing"))
        let missingDenied = await missing.begin(at: start)
        XCTAssertFalse(missingDenied)
    }

    func testRestartAfterFailedFirstAttemptCannotUseSecondSlot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-failed-reservation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstGate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
                                                reservationDirectory: directory)
        let started = await firstGate.begin(at: start)
        XCTAssertTrue(started)
        await firstGate.finish(error: ClaudeUsageRunnerError.timeout, at: start)
        let restartedGate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
                                                    reservationDirectory: directory)
        let retry = await restartedGate.begin(at: start.addingTimeInterval(86_400))
        XCTAssertFalse(retry)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testCheckpointKeepsSuccessDeadlineAcrossRestartAndWakeBurst() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(first, at: start, expected: true)
        await first.finish(error: nil, at: start.addingTimeInterval(2))

        let restarted = ClaudeDirectRefreshGate(checkpointURL: file)
        for offset in [3.0, 60, 299, 301] {
            await assertBegin(restarted, at: start.addingTimeInterval(offset), expected: false)
        }
        let due = start.addingTimeInterval(302)
        await assertBegin(restarted, at: due, expected: true)
        let concurrent = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(concurrent, at: due, expected: false)
        await restarted.finish(error: nil, at: due)
        await assertBegin(concurrent, at: due, expected: false)
        let wakeAt = due.addingTimeInterval(7_200)
        let afterWake = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(afterWake, at: wakeAt, expected: true)
        for _ in 0..<3 {
            let duplicate = ClaudeDirectRefreshGate(checkpointURL: file)
            await assertBegin(duplicate, at: wakeAt, expected: false)
        }
        await afterWake.finish(error: nil, at: wakeAt)
        let data = try Data(contentsOf: file)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["attempts"] as? Int, 3)
        XCTAssertNotNil(fields["lastAttemptAt"])
        XCTAssertNotNil(fields["lastSuccessAt"])
        XCTAssertNotNil(fields["nextEligibleAt"])
        XCTAssertNil(fields["rate_limits"])
    }

    func testSixtySecondCheckpointBlocksEarlyRestartAndWakeBurst() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-sixty-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(first, at: start, expected: true)
        await first.finish(error: nil, at: start)
        let restarted = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(59), expected: false)
        await assertBegin(restarted, at: start.addingTimeInterval(60), expected: true)
        let overlapping = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(overlapping, at: start.addingTimeInterval(60), expected: false)
        await restarted.finish(error: nil, at: start.addingTimeInterval(60))
        await assertBegin(overlapping, at: start.addingTimeInterval(119), expected: false)
        let afterWake = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(afterWake, at: start.addingTimeInterval(3_600), expected: true)
        for _ in 0..<3 {
            let duplicate = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
            await assertBegin(duplicate, at: start.addingTimeInterval(3_600), expected: false)
        }
        await afterWake.finish(error: nil, at: start.addingTimeInterval(3_600))
    }

    func testSixtySecondTransientBackoffAndRateLimitResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-sixty-failures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(first, at: start, expected: true)
        await first.finish(error: ClaudeUsageRunnerError.timeout, at: start)
        let second = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(second, at: start.addingTimeInterval(60), expected: false)
        await assertBegin(second, at: start.addingTimeInterval(299), expected: false)
        await assertBegin(second, at: start.addingTimeInterval(300), expected: true)
        await second.finish(error: nil, at: start.addingTimeInterval(300))
        let recovered = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(recovered, at: start.addingTimeInterval(359), expected: false)
        await assertBegin(recovered, at: start.addingTimeInterval(360), expected: true)
        await recovered.finish(error: ClaudeUsageRunnerError.rateLimited, at: start.addingTimeInterval(360))
        let waiting = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(waiting, at: start.addingTimeInterval(360 + 1799), expected: false)
        let isPaused = await waiting.isPaused
        XCTAssertFalse(isPaused)
        await assertBegin(waiting, at: start.addingTimeInterval(360 + 1800), expected: true)
    }

    func testCheckpointPersistsFiniteFailuresAndSuccessReset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-failure-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(first, at: start, expected: true)
        await first.finish(error: ClaudeUsageRunnerError.timeout, at: start)
        let second = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(second, at: start.addingTimeInterval(299), expected: false)
        let secondAt = start.addingTimeInterval(300)
        await assertBegin(second, at: secondAt, expected: true)
        await second.finish(error: ClaudeUsageRunnerError.transport, at: secondAt)
        let third = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(third, at: secondAt.addingTimeInterval(599), expected: false)
        let thirdAt = secondAt.addingTimeInterval(600)
        await assertBegin(third, at: thirdAt, expected: true)
        await third.finish(error: ExternalProviderError.noData, at: thirdAt)
        // The third consecutive failure starts a persisted cooldown instead of a permanent pause.
        let restarted = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(restarted, at: thirdAt.addingTimeInterval(1799), expected: false)
        let restartPaused = await restarted.isPaused
        XCTAssertFalse(restartPaused)
        await assertBegin(restarted, at: thirdAt.addingTimeInterval(1800), expected: true)

        let resetFile = directory.appendingPathComponent("reset.json")
        let reset = ClaudeDirectRefreshGate(checkpointURL: resetFile)
        await assertBegin(reset, at: start, expected: true)
        await reset.finish(error: ClaudeUsageRunnerError.timeout, at: start)
        let recovered = ClaudeDirectRefreshGate(checkpointURL: resetFile)
        await assertBegin(recovered, at: secondAt, expected: true)
        await recovered.finish(error: nil, at: secondAt)
        let next = ClaudeDirectRefreshGate(checkpointURL: resetFile)
        let nextAt = secondAt.addingTimeInterval(300)
        await assertBegin(next, at: nextAt, expected: true)
        await next.finish(error: ClaudeUsageRunnerError.timeout, at: nextAt)
        let nextEligible = await next.nextEligibleAt
        XCTAssertEqual(nextEligible, nextAt.addingTimeInterval(300))
    }

    func testCheckpointFailsClosedAfterInterruptedOrCorruptAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-uncertain-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let interrupted = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(interrupted, at: start, expected: true)
        let restarted = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(86_400), expected: false)
        try Data("invalid".utf8).write(to: file, options: .atomic)
        let corrupt = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(corrupt, at: start.addingTimeInterval(86_400), expected: false)
        let missing = ClaudeDirectRefreshGate(checkpointURL: directory.appendingPathComponent("absent/refresh.json"))
        await assertBegin(missing, at: start, expected: false)
    }

    func testCheckpointCancellationWaitsAndUnclassifiedSDKErrorBacksOff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-cancel-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(gate, at: start, expected: true)
        await gate.finish(error: CancellationError(), at: start)
        let restarted = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(299), expected: false)
        let due = start.addingTimeInterval(300)
        await assertBegin(restarted, at: due, expected: true)
        await restarted.finish(error: ClaudeUsageRunnerError.sdkFailure, at: due)
        let next = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(next, at: due.addingTimeInterval(299), expected: false)
        let nextPaused = await next.isPaused
        XCTAssertFalse(nextPaused)
        await assertBegin(next, at: due.addingTimeInterval(300), expected: true)
    }

    func testTwoAttemptCheckpointAndReservationsSurviveRestartWithoutThirdSlot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-limited-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            reservationDirectory: directory, checkpointURL: file)
        await assertBegin(gate, at: start, expected: true)
        await gate.finish(error: nil, at: start.addingTimeInterval(2))
        let restarted = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            reservationDirectory: directory, checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(602), expected: false)
        await assertBegin(gate, at: start.addingTimeInterval(301), expected: false)
        let secondAt = start.addingTimeInterval(302)
        await assertBegin(gate, at: secondAt, expected: true)
        await gate.finish(error: nil, at: secondAt)
        await assertBegin(gate, at: secondAt.addingTimeInterval(86_400), expected: false)
        let anotherRestart = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            reservationDirectory: directory, checkpointURL: file)
        await assertBegin(anotherRestart, at: secondAt.addingTimeInterval(86_400), expected: false)
        let reservations = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".reserved") }
        XCTAssertEqual(reservations.count, 2)
    }

    func testRestartedProviderUsesStatusLineUntilCheckpointIsDue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-provider-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("refresh.json")
        let clock = Clock()
        let runner = SequenceRunner([.success(directJSON), .success(partialJSON)])
        func makeProvider() -> ClaudeOptionalUsageProvider {
            ClaudeOptionalUsageProvider(
                statusLine: MockStatusLine(result: .success(status(clock.date))),
                route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner,
                                                                               now: { clock.date }),
                                           maxAge: 900),
                now: { clock.date }, gate: ClaudeDirectRefreshGate(checkpointURL: file))
        }
        let first = try await makeProvider().fetch()
        XCTAssertEqual(first.source, .directCLI)
        clock.date = clock.date.addingTimeInterval(120)
        let reopened = try await makeProvider().fetch()
        XCTAssertEqual(reopened.source, .statusLine)
        let callsBeforeDue = await runner.calls
        XCTAssertEqual(callsBeforeDue, 1)
        clock.date = clock.date.addingTimeInterval(180)
        let due = try await makeProvider().fetch()
        XCTAssertNotNil(due.sourceTimes[.directCLI])
        let callsAfterDue = await runner.calls
        XCTAssertEqual(callsAfterDue, 2)
    }

    func testTwoAttemptProviderPreservesStatusLineAfterFirstFailure() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.failure(.timeout), .success(directJSON)])
        let feed = status(clock.date.addingTimeInterval(-5))
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .success(feed)),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner), maxAge: 900),
            now: { clock.date }, gate: ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true))
        let first = try await provider.fetch()
        XCTAssertEqual(first.source, .statusLine)
        clock.date = clock.date.addingTimeInterval(300)
        let second = try await provider.fetch()
        XCTAssertEqual(second, first)
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancelledDirectRequestPropagatesCancellation() async {
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .failure(.setupRequired)),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: CancelRunner()),
                                       maxAge: 900))
        do { _ = try await provider.fetch(); XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testExternalStoreKeepsClaudeDataAfterMockProcessFailure() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.success(directJSON), .failure(.timeout)])
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .success(status(clock.date.addingTimeInterval(-5)))),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner,
                                                                           now: { clock.date }),
                                       maxAge: 900), now: { clock.date })
        let name = "tokenly.claude.integration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        let store = ExternalProviderStore(displaySettings: settings, now: { clock.date },
                                          providers: [.claude: provider])
        let firstTask = try XCTUnwrap(store.refresh(.claude))
        await firstTask.value
        guard case .success(let first) = store.state(for: .claude) else {
            return XCTFail("first mock result should be available")
        }
        XCTAssertEqual(first.source, .directCLI)
        clock.date = clock.date.addingTimeInterval(300)
        let secondTask = try XCTUnwrap(store.refresh(.claude))
        await secondTask.value
        guard case .success(let second) = store.state(for: .claude) else {
            return XCTFail("previous direct result should survive process failure")
        }
        XCTAssertEqual(second.sourceTimes[.directCLI], first.fetchedAt)
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
    }

    func testProductConfigurationRequiresBundledRuntimeAndClaudeCLI() throws {
        XCTAssertEqual(ClaudeProductConfiguration.successInterval, 60)
        let root = URL(fileURLWithPath: "/private/tmp/tokenly-claude-product-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Tokenly.app")
        let resources = bundle.appendingPathComponent("Contents/Resources/ClaudeUsageSDK")
        let sdk = resources.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let node = macOS.appendingPathComponent("TokenlyClaudeNode")
        let cli = root.appendingPathComponent("claude")
        let helper = resources.appendingPathComponent("claude-usage-helper.mjs")
        for executable in [node, cli] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try Data("// mock helper\n".utf8).write(to: helper)
        let manifest = sdk.appendingPathComponent("package.json")
        try Data(#"{"version":"0.3.169"}"#.utf8).write(to: manifest)
        XCTAssertNil(ClaudeProductConfiguration.makeProvider(bundleURL: bundle,
            candidates: [root.appendingPathComponent("missing")], supportDirectory: support))
        let configured = ClaudeProductConfiguration.makeProvider(bundleURL: bundle,
            candidates: [cli], supportDirectory: support, checkpointNamespace: "io.github.tokenly.candidate")
        XCTAssertEqual(configured?.usesDirectSDK, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support
            .appendingPathComponent("io.github.tokenly.candidate/Claude Direct Refresh").path))
        try Data(#"{"version":"0.0.0"}"#.utf8).write(to: manifest)
        XCTAssertNil(ClaudeProductConfiguration.makeProvider(bundleURL: bundle,
            candidates: [cli], supportDirectory: support, checkpointNamespace: "io.github.tokenly.candidate"))
    }

    func testProductFactoryMockSubprocessParsesAndWaitsSixtySeconds() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/tokenly-claude-product-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Tokenly.app")
        let resources = bundle.appendingPathComponent("Contents/Resources/ClaudeUsageSDK")
        let sdk = resources.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let calls = root.appendingPathComponent("calls.txt")
        let node = macOS.appendingPathComponent("TokenlyClaudeNode")
        let script = "#!/bin/sh\necho call >> '\(calls.path)'\nprintf '%s\\n' '\(String(data: directJSON, encoding: .utf8)!)'\n"
        try Data(script.utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let cli = root.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try Data("// mock helper\n".utf8).write(to: resources.appendingPathComponent("claude-usage-helper.mjs"))
        try Data(#"{"version":"0.3.169"}"#.utf8).write(to: sdk.appendingPathComponent("package.json"))
        let clock = Clock()
        let provider = try XCTUnwrap(ClaudeProductConfiguration.makeProvider(bundleURL: bundle,
            candidates: [cli], statusLine: MockStatusLine(result: .failure(.noData)), now: { clock.date },
            supportDirectory: root.appendingPathComponent("support"), checkpointNamespace: "mock.product"))
        let first = try await provider.fetch()
        XCTAssertEqual(first.source, .directCLI)
        guard case .quotas(let quotas) = first.metrics else { return XCTFail("missing Mock quotas") }
        XCTAssertEqual(quotas.map(\.remainingPercent), [80, 60])
        clock.date = clock.date.addingTimeInterval(59)
        _ = try await provider.fetch()
        XCTAssertEqual(try String(contentsOf: calls).split(separator: "\n").count, 1)
        clock.date = clock.date.addingTimeInterval(1)
        let second = try await provider.fetch()
        XCTAssertEqual(second.sourceTimes[.directCLI], clock.date)
        XCTAssertEqual(try String(contentsOf: calls).split(separator: "\n").count, 2)
    }

    func testProductGateWaitsSixtySecondsAcrossRestartAndBoundsUnknownErrors() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/tokenly-claude-product-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("checkpoint.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ClaudeDirectRefreshGate(pauseOnUnknownError: true, successInterval: 60,
                                            checkpointURL: file)
        await assertBegin(first, at: start, expected: true)
        await first.finish(error: nil, at: start)
        let restarted = ClaudeDirectRefreshGate(pauseOnUnknownError: true, successInterval: 60,
                                                checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(59), expected: false)
        var time = start.addingTimeInterval(60)
        for cycle in 1...3 {
            await assertBegin(restarted, at: time, expected: true)
            await restarted.finish(error: NSError(domain: "unknown", code: 1), at: time)
            guard cycle < 3 else { break }
            // An unclassified error skips the short backoff and waits a full cooldown.
            await assertBegin(restarted, at: time.addingTimeInterval(1799), expected: false)
            time = time.addingTimeInterval(1800)
        }
        let final = ClaudeDirectRefreshGate(pauseOnUnknownError: true, successInterval: 60,
                                            checkpointURL: file)
        await assertBegin(final, at: time.addingTimeInterval(86_400), expected: false)
        let status = await final.status(at: time.addingTimeInterval(86_400))
        XCTAssertEqual(status.phase, .paused(.repeatedFailures))
        XCTAssertEqual(status.lastErrorKind, .unknown)
    }

#if TOKENLY_CLAUDE_DEV
    @MainActor
    func testSecondAttemptSchedulesOnlyAfterDirectSuccess() {
        let direct = ExternalUsageSnapshot(metrics: .quotas([]), fetchedAt: Date(),
                                           source: .directCLI, sourceTimes: [.directCLI: Date()])
        XCTAssertTrue(ExternalProviderStore.shouldScheduleSecondClaudeAttempt(.success(direct)))
        let feed = status(Date())
        XCTAssertFalse(ExternalProviderStore.shouldScheduleSecondClaudeAttempt(.success(feed)))
        XCTAssertFalse(ExternalProviderStore.shouldScheduleSecondClaudeAttempt(
            .failure(.connection, previous: direct)))
    }

    @MainActor
    func testDevelopmentDefaultsShowOnlyClaudeWithoutWritingProductionDomain() {
        let name = "tokenly.claude.mock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ProviderDisplaySettings(defaults: defaults,
                                               defaultCodexVisible: false,
                                               defaultClaudeVisible: true)
        XCTAssertFalse(settings.showsCodex)
        XCTAssertFalse(settings.showsAGY)
        XCTAssertTrue(settings.showsClaude)
    }

    func testDevelopmentMockRequiresSafeProcessAndFeedPaths() {
        let unsafe = ClaudeDevelopmentConfiguration.makeProvider(environment: [
            "TOKENLY_CLAUDE_DEV_ENABLE": "1", "TOKENLY_CLAUDE_DEV_MOCK": "1",
            "TOKENLY_CLAUDE_DEV_NODE": "/opt/homebrew/bin/node",
            "TOKENLY_CLAUDE_DEV_HELPER": "/private/tmp/tokenly-claude-dev-mock-1/helper.sh",
            "TOKENLY_CLAUDE_DEV_CLI": "/opt/homebrew/bin/claude",
            "TOKENLY_CLAUDE_DEV_STATUSLINE": "/private/tmp/tokenly-claude-dev-mock-1/feed.json",
        ])
        if case .statusLineOnly = unsafe.route {} else { XCTFail("unsafe mock paths must be disabled") }
        let safe = ClaudeDevelopmentConfiguration.makeProvider(environment: [
            "TOKENLY_CLAUDE_DEV_ENABLE": "1", "TOKENLY_CLAUDE_DEV_MOCK": "1",
            "TOKENLY_CLAUDE_DEV_NODE": "/bin/sh",
            "TOKENLY_CLAUDE_DEV_HELPER": "/private/tmp/tokenly-claude-dev-mock-1/helper.sh",
            "TOKENLY_CLAUDE_DEV_CLI": "/usr/bin/true",
            "TOKENLY_CLAUDE_DEV_STATUSLINE": "/private/tmp/tokenly-claude-dev-mock-1/feed.json",
        ])
        if case .experimentalDirect = safe.route {} else { XCTFail("safe mock route should connect") }
        let wrongFixtureRoot = ClaudeDevelopmentConfiguration.makeProvider(environment: [
            "TOKENLY_CLAUDE_DEV_ENABLE": "1", "TOKENLY_CLAUDE_DEV_MOCK": "1",
            "TOKENLY_CLAUDE_DEV_NODE": "/bin/sh",
            "TOKENLY_CLAUDE_DEV_HELPER": "/private/tmp/tokenly-claude-ui-mock-1/helper.sh",
            "TOKENLY_CLAUDE_DEV_CLI": "/usr/bin/true",
            "TOKENLY_CLAUDE_DEV_STATUSLINE": "/private/tmp/tokenly-claude-ui-mock-1/feed.json",
        ])
        if case .statusLineOnly = wrongFixtureRoot.route {} else {
            XCTFail("mock helper outside the approved prefix must not run")
        }
    }

    @MainActor
    func testPortableDevelopmentIntervalDefaultsAndRequiresExplicitRealOptIn() {
        let domain = "tokenly.claude.interval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        XCTAssertEqual(settings.claudeRefreshSeconds, 300)
        settings.claudeRefreshSeconds = 60
        XCTAssertEqual(ProviderDisplaySettings(defaults: defaults).claudeRefreshSeconds, 60)
        let id = ClaudeDevelopmentConfiguration.portableBundleID
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 60, bundleID: id,
            environment: [:]), 300)
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 60, bundleID: id,
            environment: ["TOKENLY_CLAUDE_DEV_MOCK": "1"]), 60)
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 60, bundleID: id,
            environment: ["TOKENLY_CLAUDE_DEV_ALLOW_60": "1"]), 60)
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 60,
            bundleID: "io.github.jbbdyee.tokenly", environment: ["TOKENLY_CLAUDE_DEV_ALLOW_60": "1"]), 300)
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 300, bundleID: id,
            environment: ["TOKENLY_CLAUDE_DEV_ALLOW_60": "1"]), 300)
        let mockID = ClaudeDevelopmentConfiguration.mockSixtyBundleID
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 300, bundleID: mockID,
            environment: ["TOKENLY_CLAUDE_DEV_MOCK": "1", "TOKENLY_CLAUDE_DEV_MOCK_SIXTY": "1"]), 60)
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 300, bundleID: mockID,
            environment: ["TOKENLY_CLAUDE_DEV_MOCK_SIXTY": "1"]), 300)
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 300, bundleID: id,
            environment: ["TOKENLY_CLAUDE_DEV_MOCK": "1", "TOKENLY_CLAUDE_DEV_MOCK_SIXTY": "1"]), 300)
        let realThreeID = ClaudeDevelopmentConfiguration.realThreeBundleID
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 300, bundleID: realThreeID,
            environment: ["TOKENLY_CLAUDE_DEV_REAL_THREE": "1"]), 60)
        XCTAssertEqual(ClaudeDevelopmentConfiguration.refreshInterval(selected: 300, bundleID: realThreeID,
            environment: [:]), 300)
        XCTAssertFalse(ClaudeDevelopmentConfiguration.bundledRouteAllowed(environment: [
            "TOKENLY_CLAUDE_DEV_BUNDLED_ENABLE": "1", "TOKENLY_CLAUDE_DEV_MOCK": "1"], bundleID: id))
        XCTAssertTrue(ClaudeDevelopmentConfiguration.bundledRouteAllowed(environment: [
            "TOKENLY_CLAUDE_DEV_BUNDLED_ENABLE": "1"], bundleID: id))
        XCTAssertEqual(ExternalProviderStore(displaySettings: settings, automaticTickInterval: 60)
            .automaticTickInterval, 60)
    }

    func testMockSixtyTwoAttemptBudgetSurvivesRestartAndBlocksThirdCall() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-mock-sixty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("checkpoint.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(first, at: start, expected: true)
        await first.finish(error: nil, at: start)
        await assertBegin(first, at: start.addingTimeInterval(59), expected: false)
        await assertBegin(first, at: start.addingTimeInterval(60), expected: true)
        await first.finish(error: nil, at: start.addingTimeInterval(60))
        await assertBegin(first, at: start.addingTimeInterval(120), expected: false)
        let restarted = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(3_600), expected: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("attempt-1.reserved").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("attempt-2.reserved").path))
    }

    func testRealThreeTrialRequiresSixtySecondsAndBlocksFourthAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-real-three-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("checkpoint.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(maxAttempts: 3, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(gate, at: start, expected: true)
        await gate.finish(error: nil, at: start)
        await assertBegin(gate, at: start.addingTimeInterval(59), expected: false)
        await assertBegin(gate, at: start.addingTimeInterval(60), expected: true)
        await gate.finish(error: nil, at: start.addingTimeInterval(60))
        await assertBegin(gate, at: start.addingTimeInterval(119), expected: false)
        await assertBegin(gate, at: start.addingTimeInterval(120), expected: true)
        await gate.finish(error: nil, at: start.addingTimeInterval(120))
        await assertBegin(gate, at: start.addingTimeInterval(180), expected: false)
        let restarted = ClaudeDirectRefreshGate(maxAttempts: 3, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(86_400), expected: false)
        for attempt in 1...3 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory
                .appendingPathComponent("attempt-\(attempt).reserved").path))
        }
    }

    func testRealThreeTrialStopsAfterFirstFailureAndCannotRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-real-three-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("checkpoint.json")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(maxAttempts: 3, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(gate, at: start, expected: true)
        await gate.finish(error: ClaudeUsageRunnerError.timeout, at: start)
        let restarted = ClaudeDirectRefreshGate(maxAttempts: 3, stopOnFailure: true,
            successInterval: 60, reservationDirectory: directory, checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(86_400), expected: false)
    }

    func testMockUIFixtureMatchesSDKContractAndStatusLineFallback() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("experiments/claude-usage-refresh/fixtures/mock-ui-success.json")
        let data = try Data(contentsOf: fixture)
        let parsed = try ClaudeDirectUsageParser.parse(data, receivedAt: Date())
        XCTAssertEqual(parsed.windows[.fiveHour]?.quota.remainingPercent, 80)
        XCTAssertEqual(parsed.windows[.sevenDay]?.quota.remainingPercent, 65)

        let root = URL(fileURLWithPath: "/private/tmp/tokenly-claude-dev-mock-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = root.appendingPathComponent("response.json")
        try data.write(to: response)
        let helper = root.appendingPathComponent("helper.sh")
        let feed = root.appendingPathComponent("feed.json")
        let captured = ISO8601DateFormatter().string(from: Date())
        try Data(#"{"captured_at":"\#(captured)","rate_limits":{"five_hour":{"used_percentage":27},"seven_day":{"used_percentage":42}}}"#.utf8)
            .write(to: feed)
        func provider() -> ClaudeOptionalUsageProvider {
            ClaudeDevelopmentConfiguration.makeProvider(environment: [
                "TOKENLY_CLAUDE_DEV_ENABLE": "1", "TOKENLY_CLAUDE_DEV_MOCK": "1",
                "TOKENLY_CLAUDE_DEV_NODE": "/bin/sh", "TOKENLY_CLAUDE_DEV_HELPER": helper.path,
                "TOKENLY_CLAUDE_DEV_CLI": "/usr/bin/true", "TOKENLY_CLAUDE_DEV_STATUSLINE": feed.path,
            ])
        }
        try Data("#!/bin/sh\ncat \(response.path)\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let direct = try await provider().fetch()
        XCTAssertEqual(direct.source, .directCLI)
        XCTAssertNotNil(direct.sourceTimes[.directCLI])
        guard case .quotas(let directQuotas) = direct.metrics else { return XCTFail("missing direct quotas") }
        XCTAssertEqual(directQuotas.map(\.remainingPercent), [80, 65])

        try Data("#!/bin/sh\nexit 22\n".utf8).write(to: helper)
        let fallback = try await provider().fetch()
        XCTAssertEqual(fallback.source, .statusLine)
        XCTAssertNil(fallback.sourceTimes[.directCLI])
        guard case .quotas(let fallbackQuotas) = fallback.metrics else { return XCTFail("missing fallback quotas") }
        XCTAssertEqual(fallbackQuotas.map(\.remainingPercent), [73, 58])
    }
#endif
}

// MARK: - v0.4.1 recovery policy

extension ClaudeOptionalUsageTests {
    private func temporaryCheckpoint(_ label: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("refresh.json"))
    }

    func testNetworkFailureRecoversAutomaticallyAndKeepsSixtySecondCadence() async throws {
        let (directory, file) = try temporaryCheckpoint("network-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(pauseOnUnknownError: true, successInterval: 60, checkpointURL: file)
        await assertBegin(gate, at: start, expected: true)
        await gate.finish(error: ClaudeUsageRunnerError.network, at: start)
        let waiting = await gate.status(at: start)
        XCTAssertEqual(waiting.phase, .retryWaiting(until: start.addingTimeInterval(300)))
        XCTAssertTrue(waiting.isInterrupted)
        let retry = start.addingTimeInterval(300)
        await assertBegin(gate, at: retry, expected: true)
        await gate.finish(error: nil, at: retry)
        let healthy = await gate.status(at: retry)
        XCTAssertEqual(healthy.phase, .ready)
        XCTAssertNil(healthy.lastErrorKind)
        XCTAssertEqual(healthy.lastSuccessAt, retry)
        await assertBegin(gate, at: retry.addingTimeInterval(59), expected: false)
        await assertBegin(gate, at: retry.addingTimeInterval(60), expected: true)
    }

    func testCooldownResumesAutomaticallyAndSuccessClearsCounters() async throws {
        let (directory, file) = try temporaryCheckpoint("cooldown")
        defer { try? FileManager.default.removeItem(at: directory) }
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        for minutes in [5, 10, 30] {
            await assertBegin(gate, at: time, expected: true)
            await gate.finish(error: ClaudeUsageRunnerError.network, at: time)
            time = time.addingTimeInterval(TimeInterval(minutes * 60))
        }
        let restarted = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: file)
        await assertBegin(restarted, at: time, expected: true)
        await restarted.finish(error: nil, at: time)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(fields["transientFailures"] as? Int, 0)
        XCTAssertNil(fields["cooldownCycles"])
        XCTAssertNil(fields["lastErrorKind"])
        XCTAssertEqual(fields["isPaused"] as? Bool, false)
    }

    func testV040PausedCheckpointResumesOnceThenRecordsReason() async throws {
        let (directory, file) = try temporaryCheckpoint("legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Shape written by v0.4.0 after an unrecorded failure; Date values use the reference-date encoding.
        let lastAttempt = Date(timeIntervalSinceReferenceDate: 815_442_023.764263)
        try Data(#"{"transientFailures":0,"isPaused":true,"lastSuccessAt":815436476.38997,"isInFlight":false,"attempts":946,"schemaVersion":1,"lastAttemptAt":815442023.764263}"#.utf8)
            .write(to: file)
        let gate = ClaudeDirectRefreshGate(pauseOnUnknownError: true, successInterval: 60, checkpointURL: file)
        let status = await gate.status(at: lastAttempt.addingTimeInterval(60))
        XCTAssertEqual(status.phase, .retryWaiting(until: lastAttempt.addingTimeInterval(1800)))
        XCTAssertEqual(status.lastErrorKind, .legacyPause)
        await assertBegin(gate, at: lastAttempt.addingTimeInterval(1799), expected: false)
        let resumed = lastAttempt.addingTimeInterval(1800)
        await assertBegin(gate, at: resumed, expected: true)
        await gate.finish(error: ClaudeUsageRunnerError.network, at: resumed)
        // Only one automatic attempt: a further transient failure pauses with a recorded reason.
        let after = await gate.status(at: resumed.addingTimeInterval(86_400))
        XCTAssertEqual(after.phase, .paused(.repeatedFailures))
        XCTAssertEqual(after.lastErrorKind, .network)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(fields["attempts"] as? Int, 947)
        XCTAssertEqual(fields["pauseReason"] as? String, "repeatedFailures")
        let allowed: Set<String> = ["schemaVersion", "attempts", "lastAttemptAt", "lastSuccessAt", "nextEligibleAt",
            "transientFailures", "isPaused", "isInFlight", "lastErrorKind", "lastErrorAt", "pauseReason",
            "cooldownCycles", "rateLimitHits"]
        XCTAssertTrue(Set(fields.keys).isSubset(of: allowed))

        // A long-past v0.4.0 pause is due immediately; a safety failure then stops for good.
        let (oldDirectory, oldFile) = try temporaryCheckpoint("legacy-old")
        defer { try? FileManager.default.removeItem(at: oldDirectory) }
        try Data(#"{"transientFailures":0,"isPaused":true,"isInFlight":false,"attempts":3,"schemaVersion":1,"lastAttemptAt":815442023.764263}"#.utf8)
            .write(to: oldFile)
        let old = ClaudeDirectRefreshGate(successInterval: 60, checkpointURL: oldFile)
        let later = lastAttempt.addingTimeInterval(86_400)
        await assertBegin(old, at: later, expected: true)
        await old.finish(error: ClaudeUsageRunnerError.unexpectedModelActivity, at: later)
        let stopped = await old.status(at: later.addingTimeInterval(86_400))
        XCTAssertEqual(stopped.phase, .paused(.unexpectedModelActivity))
        let manual = await old.prepareManualRetry(at: later.addingTimeInterval(86_400))
        XCTAssertEqual(manual, .refused(.safetyStop))
    }

    func testStaleInFlightCheckpointRecoversAsInterruptedFailure() async throws {
        let (directory, file) = try temporaryCheckpoint("stale-inflight")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let interrupted = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(interrupted, at: start, expected: true)
        let restarted = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(restarted, at: start.addingTimeInterval(599), expected: false)
        let recoveredAt = start.addingTimeInterval(600)
        let status = await restarted.status(at: recoveredAt)
        XCTAssertEqual(status.phase, .retryWaiting(until: recoveredAt.addingTimeInterval(300)))
        XCTAssertEqual(status.lastErrorKind, .interrupted)
        await assertBegin(restarted, at: recoveredAt.addingTimeInterval(300), expected: true)
    }

    func testManualRetryAllowsRecoverableStopsAndRefusesUnsafeOnes() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Transient wait: refused within a minute of the attempt, then allowed immediately.
        let transient = ClaudeDirectRefreshGate(successInterval: 60)
        await assertBegin(transient, at: start, expected: true)
        let inFlight = await transient.prepareManualRetry(at: start)
        XCTAssertEqual(inFlight, .refused(.inFlight))
        await transient.finish(error: ClaudeUsageRunnerError.network, at: start)
        let tooSoon = await transient.prepareManualRetry(at: start.addingTimeInterval(30))
        XCTAssertEqual(tooSoon, .refused(.tooSoon(until: start.addingTimeInterval(60))))
        let allowed = await transient.prepareManualRetry(at: start.addingTimeInterval(60))
        XCTAssertEqual(allowed, .allowed)
        await assertBegin(transient, at: start.addingTimeInterval(60), expected: true)
        await assertBegin(transient, at: start.addingTimeInterval(60), expected: false)
        await transient.finish(error: nil, at: start.addingTimeInterval(61))
        let healthy = await transient.prepareManualRetry(at: start.addingTimeInterval(90))
        XCTAssertEqual(healthy, .notNeeded)
        await assertBegin(transient, at: start.addingTimeInterval(90), expected: false)

        // Authentication: no automatic retry, a manual retry after login is allowed and re-pauses on failure.
        let auth = ClaudeDirectRefreshGate(successInterval: 60)
        await assertBegin(auth, at: start, expected: true)
        await auth.finish(error: ClaudeUsageRunnerError.authenticationRequired, at: start)
        await assertBegin(auth, at: start.addingTimeInterval(86_400), expected: false)
        let authRetry = await auth.prepareManualRetry(at: start.addingTimeInterval(120))
        XCTAssertEqual(authRetry, .allowed)
        await assertBegin(auth, at: start.addingTimeInterval(120), expected: true)
        await auth.finish(error: ClaudeUsageRunnerError.authenticationRequired, at: start.addingTimeInterval(121))
        let authAgain = await auth.status(at: start.addingTimeInterval(200))
        XCTAssertEqual(authAgain.phase, .paused(.authenticationRequired))

        // Repeated failures: a manual retry grants one bounded round, then pauses again.
        let repeated = ClaudeDirectRefreshGate(successInterval: 60)
        var time = start
        while !(await repeated.isPaused) {
            await assertBegin(repeated, at: time, expected: true)
            await repeated.finish(error: ClaudeUsageRunnerError.network, at: time)
            time = await repeated.nextEligibleAt ?? time
        }
        let resume = await repeated.prepareManualRetry(at: time.addingTimeInterval(60))
        XCTAssertEqual(resume, .allowed)
        time = time.addingTimeInterval(60)
        for _ in 0..<3 {
            await assertBegin(repeated, at: time, expected: true)
            await repeated.finish(error: ClaudeUsageRunnerError.timeout, at: time)
            time = await repeated.nextEligibleAt ?? time
        }
        let pausedAgain = await repeated.status(at: time)
        XCTAssertEqual(pausedAgain.phase, .paused(.repeatedFailures))

        // Rate limit and safety stops are not lifted by a manual refresh.
        let limited = ClaudeDirectRefreshGate(successInterval: 60)
        await assertBegin(limited, at: start, expected: true)
        await limited.finish(error: ClaudeRateLimitError(retryAfter: 900), at: start)
        let limitedRetry = await limited.prepareManualRetry(at: start.addingTimeInterval(120))
        XCTAssertEqual(limitedRetry, .refused(.rateLimited(until: start.addingTimeInterval(900))))
        await assertBegin(limited, at: start.addingTimeInterval(120), expected: false)
        let safety = ClaudeDirectRefreshGate(successInterval: 60)
        await assertBegin(safety, at: start, expected: true)
        await safety.finish(error: ClaudeUsageRunnerError.unexpectedModelActivity, at: start)
        let safetyRetry = await safety.prepareManualRetry(at: start.addingTimeInterval(3600))
        XCTAssertEqual(safetyRetry, .refused(.safetyStop))
        await assertBegin(safety, at: start.addingTimeInterval(3600), expected: false)

        // Limited account trials never resume.
        let trial = ClaudeDirectRefreshGate(maxAttempts: 2, stopOnFailure: true)
        let trialRetry = await trial.prepareManualRetry(at: start)
        XCTAssertEqual(trialRetry, .refused(.limitedTrial))
    }

    @MainActor
    func testWakeSchedulesOneDelayedRefreshAndSleepCancelsIt() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.success(directJSON), .success(directJSON)])
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .failure(.noData)),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner, now: { clock.date }),
                                       maxAge: 900),
            now: { clock.date }, gate: ClaudeDirectRefreshGate(successInterval: 60))
        let name = "tokenly.claude.wake.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        settings.showsClaude = true
        let store = ExternalProviderStore(displaySettings: settings, now: { clock.date },
                                          claudeWakeDelay: 0.05, providers: [.claude: provider])
        // Sleep cancels a wake refresh that has not started (dark wake followed by sleep).
        store.handleSystemDidWake()
        store.handleSystemWillSleep()
        try await Task.sleep(nanoseconds: 300_000_000)
        var calls = await runner.calls
        XCTAssertEqual(calls, 0)
        // Repeated wake notifications collapse into one delayed refresh.
        store.handleSystemDidWake()
        store.handleSystemDidWake()
        store.handleSystemDidWake()
        try await Task.sleep(nanoseconds: 500_000_000)
        calls = await runner.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.claudeDirectStatus?.phase, .ready)
        XCTAssertFalse(store.isSystemAsleep)
        store.handleSystemWillSleep()
    }

    @MainActor
    func testManualRefreshLiftsTransientWaitThroughStore() async throws {
        let clock = Clock()
        let runner = SequenceRunner([.failure(.network), .success(directJSON)])
        let provider = ClaudeOptionalUsageProvider(
            statusLine: MockStatusLine(result: .success(status(clock.date))),
            route: .experimentalDirect(provider: ClaudeDirectUsageProvider(runner: runner, now: { clock.date }),
                                       maxAge: 900),
            now: { clock.date }, gate: ClaudeDirectRefreshGate(successInterval: 60))
        let name = "tokenly.claude.manual.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        settings.showsClaude = true
        let store = ExternalProviderStore(displaySettings: settings, now: { clock.date },
                                          providers: [.claude: provider])
        let first = try XCTUnwrap(store.refresh(.claude))
        await first.value
        guard case .retryWaiting = store.claudeDirectStatus?.phase else {
            return XCTFail("network failure should wait for a retry")
        }
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(store.state(for: .claude), direct: store.claudeDirectStatus),
                       "직접 조회 재시도 대기")
        clock.date = clock.date.addingTimeInterval(60)
        store.refreshSelected(force: true)
        for _ in 0..<50 where store.claudeDirectStatus?.phase != .ready {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let calls = await runner.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.claudeManualRetry, .allowed)
        XCTAssertEqual(store.claudeDirectStatus?.phase, .ready)
        store.handleSystemWillSleep()
    }

    func testPopoverShowsDirectStopEvenWithStatusLineData() {
        let received = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = ExternalLoadState.success(status(received))
        let lastSuccess = received.addingTimeInterval(-3600)
        func direct(_ phase: ClaudeDirectRefreshStatus.Phase) -> ClaudeDirectRefreshStatus {
            ClaudeDirectRefreshStatus(phase: phase, lastSuccessAt: lastSuccess, lastErrorKind: .network)
        }
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: nil), "상태줄 데이터")
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: direct(.ready)), "상태줄 데이터")
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: direct(.paused(.authenticationRequired))),
                       "직접 조회 중지 · 로그인 필요")
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: direct(.paused(.permissionDenied))),
                       "직접 조회 중지 · 권한 확인 필요")
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: direct(.paused(.unexpectedModelActivity))),
                       "직접 조회 안전 정지")
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: direct(.paused(.repeatedFailures))),
                       "직접 조회 중지")
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: direct(.rateLimited(until: received))),
                       "요청 제한 · 직접 조회 대기")
        XCTAssertEqual(UsagePopoverCopy.claudeStatus(feed, direct: direct(.retryWaiting(until: received))),
                       "직접 조회 재시도 대기")

        XCTAssertNil(UsagePopoverCopy.claudeDirectDetail(direct(.ready)))
        let waiting = try? XCTUnwrap(UsagePopoverCopy.claudeDirectDetail(direct(.retryWaiting(until: received))))
        XCTAssertTrue(waiting?.contains(CompactDateTime.string(for: received)) == true)
        XCTAssertTrue(waiting?.contains("마지막 정상 직접 조회 \(CompactDateTime.string(for: lastSuccess))") == true)
        let safety = UsagePopoverCopy.claudeDirectDetail(direct(.paused(.unexpectedModelActivity))) ?? ""
        XCTAssertTrue(safety.contains("새로고침으로는 다시 시작하지 않습니다"))
        let auth = UsagePopoverCopy.claudeDirectDetail(direct(.paused(.authenticationRequired))) ?? ""
        XCTAssertTrue(auth.contains("로그인"))
        let never = ClaudeDirectRefreshStatus(phase: .paused(.repeatedFailures), lastSuccessAt: nil, lastErrorKind: nil)
        XCTAssertTrue(UsagePopoverCopy.claudeDirectDetail(never)?.contains("정상 직접 조회 기록 없음") == true)
        let refused = UsagePopoverCopy.claudeDirectDetail(direct(.retryWaiting(until: received)),
            manual: .refused(.tooSoon(until: received)))
        XCTAssertTrue(refused?.contains("다시 시도는") == true)
        // AGY wording is unchanged.
        XCTAssertEqual(UsagePopoverCopy.agyStatus(feed), "갱신 지연")
    }
}
