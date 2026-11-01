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

    func testTransientFailuresBackOffThenPauseWithoutInfiniteRetry() async {
        let gate = ClaudeDirectRefreshGate()
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        for minutes in [5, 10] {
            let gateValue5 = await gate.begin(at: time)
            XCTAssertTrue(gateValue5)
            await gate.finish(error: ClaudeUsageRunnerError.timeout, at: time)
            let gateValue6 = await gate.begin(at: time.addingTimeInterval(TimeInterval(minutes * 60 - 1)))
            XCTAssertFalse(gateValue6)
            time = time.addingTimeInterval(TimeInterval(minutes * 60))
        }
        let gateValue7 = await gate.begin(at: time)
        XCTAssertTrue(gateValue7)
        await gate.finish(error: ClaudeUsageRunnerError.transport, at: time)
        let paused = await gate.isPaused
        XCTAssertTrue(paused)
        let denied = await gate.begin(at: time.addingTimeInterval(86_400))
        XCTAssertFalse(denied)
        let next = await gate.nextEligibleAt
        XCTAssertNil(next)
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

    func testAuthAndUnavailablePauseAutomaticAttempts() async {
        for error in [ClaudeUsageRunnerError.authenticationRequired, .permissionDenied,
                      .unavailable, .incompatibleSDK, .sdkFailure] {
            let gate = ClaudeDirectRefreshGate()
            let time = Date(timeIntervalSince1970: 1_800_000_000)
            let gateValue9 = await gate.begin(at: time)
            XCTAssertTrue(gateValue9)
            await gate.finish(error: error, at: time)
            let gateValue10 = await gate.isPaused
            XCTAssertTrue(gateValue10)
            let gateValue11 = await gate.begin(at: time.addingTimeInterval(86_400))
            XCTAssertFalse(gateValue11)
        }
    }

    func testRateLimitPausesAndCancellationWaitsBeforeRetry() async {
        let gate = ClaudeDirectRefreshGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gateValue12 = await gate.begin(at: start)
        XCTAssertTrue(gateValue12)
        await gate.finish(error: ClaudeUsageRunnerError.rateLimited, at: start)
        let gateValue13 = await gate.begin(at: start.addingTimeInterval(86_400))
        XCTAssertFalse(gateValue13)
        let cancelGate = ClaudeDirectRefreshGate()
        let gateValue14 = await cancelGate.begin(at: start)
        XCTAssertTrue(gateValue14)
        await cancelGate.finish(error: CancellationError(), at: start)
        let gateValue15 = await cancelGate.begin(at: start.addingTimeInterval(299))
        XCTAssertFalse(gateValue15)
        let gateValue16 = await cancelGate.begin(at: start.addingTimeInterval(300))
        XCTAssertTrue(gateValue16)
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
        let restarted = ClaudeDirectRefreshGate(checkpointURL: file)
        await assertBegin(restarted, at: thirdAt.addingTimeInterval(86_400), expected: false)
        let restartPaused = await restarted.isPaused
        XCTAssertTrue(restartPaused)

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

    func testCheckpointCancellationAndUnclassifiedSDKErrorRemainConservative() async throws {
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
        await assertBegin(next, at: due.addingTimeInterval(86_400), expected: false)
        let nextPaused = await next.isPaused
        XCTAssertTrue(nextPaused)
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
    }
#endif
}
