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

    private struct MockStatusLine: ExternalUsageProvider {
        let id: ExternalProviderID = .claude
        let result: Result<ExternalUsageSnapshot, ExternalProviderError>
        func fetch() async throws -> ExternalUsageSnapshot { try result.get() }
    }

    private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
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
                                       maxAge: 60), now: { clock.date })
        let first = try await provider.fetch()
        clock.date = clock.date.addingTimeInterval(30)
        let second = try await provider.fetch()
        XCTAssertEqual(second.fetchedAt, first.fetchedAt)
        XCTAssertEqual(second.sourceTimes[.directCLI], first.fetchedAt)
        clock.date = clock.date.addingTimeInterval(31)
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
}
