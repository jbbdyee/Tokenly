import Foundation
import XCTest
@testable import Tokenly

final class AGYDirectUsageTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_793_400_000)

    private func response(_ buckets: String, status: String = "SUCCESS") -> Data {
        Data("""
        {"status":"\(status)","num_turns":0,
         "usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},
         "command":{"name":"usage","data":{"note":"ignored","models":[
           {"name":"subscription","description":"test","buckets":[\(buckets)]}
         ]}}}
        """.utf8)
    }

    private var weekly: String {
        #"{"id":"gemini-weekly","name":"Weekly","description":"test","window":"7d","remaining_fraction":0.37,"reset_time":"2026-11-01T01:00:00Z"}"#
    }

    func testWeeklyBucketConvertsToStatusLineDisplayModelWithoutInventingFiveHour() throws {
        let snapshot = try AGYDirectUsageParser.parse(response(weekly), fetchedAt: fetchedAt)
        XCTAssertEqual(snapshot.source, .directCLI)
        XCTAssertEqual(snapshot.sourceTimes[.directCLI], fetchedAt)
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("expected quota") }
        XCTAssertEqual(quotas.map(\.name), ["gemini-weekly"])
        XCTAssertEqual(quotas[0].remainingPercent, 37, accuracy: 0.001)
        XCTAssertNotNil(quotas[0].resetsAt)
        XCTAssertEqual(AGYQuotaSummary.text(for: quotas), "gemini-weekly 37%")
    }

    func testBothKnownWeeklyBucketsSelectedAndOtherWindowsIgnored() throws {
        let second = #"{"id":"3p-weekly","name":"Other weekly","window":"7d","remaining_fraction":0.8,"reset_time":"2026-11-02T00:00:00.123Z"}"#
        let hourly = #"{"id":"five-hour","name":"5h","window":"5h","remaining_fraction":0.1,"reset_time":"2026-11-01T00:00:00Z"}"#
        let snapshot = try AGYDirectUsageParser.parse(response([weekly, second, hourly].joined(separator: ",")), fetchedAt: fetchedAt)
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("expected quotas") }
        XCTAssertEqual(quotas.map(\.name), ["3p-weekly", "gemini-weekly"])
        XCTAssertEqual(quotas.map(\.remainingPercent), [80, 37])
        XCTAssertNotNil(quotas[0].resetsAt)
    }

    func testInvalidFractionResetAndMissingRequiredFieldsFail() {
        for bad in [
            weekly.replacingOccurrences(of: "0.37", with: "1.4"),
            weekly.replacingOccurrences(of: "0.37", with: "-0.1"),
            weekly.replacingOccurrences(of: "2026-11-01T01:00:00Z", with: "tomorrow"),
            weekly.replacingOccurrences(of: "\"reset_time\":\"2026-11-01T01:00:00Z\"", with: ""),
            weekly.replacingOccurrences(of: "\"remaining_fraction\":0.37,", with: "")
        ] {
            XCTAssertThrowsError(try AGYDirectUsageParser.parse(response(bad), fetchedAt: fetchedAt))
        }
        XCTAssertThrowsError(try AGYDirectUsageParser.parse(Data("invalid".utf8), fetchedAt: fetchedAt))
        XCTAssertThrowsError(try AGYDirectUsageParser.parse(response(weekly, status: "ERROR"), fetchedAt: fetchedAt))
        let consumed = String(decoding: response(weekly), as: UTF8.self)
            .replacingOccurrences(of: "\"num_turns\":0", with: "\"num_turns\":1")
        XCTAssertThrowsError(try AGYDirectUsageParser.parse(Data(consumed.utf8), fetchedAt: fetchedAt))
    }

    func testUnknownBucketDoesNotBecomeFiveHourOrWeekly() {
        let hourly = #"{"id":"five-hour","name":"5h","window":"5h","remaining_fraction":0.5,"reset_time":"2026-11-01T00:00:00Z"}"#
        XCTAssertThrowsError(try AGYDirectUsageParser.parse(response(hourly), fetchedAt: fetchedAt)) {
            XCTAssertEqual($0 as? ExternalProviderError, .noData)
        }
    }

    func testDirectFailureFallsBackToStatusLineAndRetainsSources() async throws {
        let feed = ExternalUsageSnapshot(metrics: .quotas([QuotaMetric(name: "gemini-weekly", remainingPercent: 42, resetsAt: nil)]),
                                         fetchedAt: fetchedAt.addingTimeInterval(-30))
        let combined = AGYCombinedProvider(direct: StubAGYProvider(result: .failure(.timeout)),
                                           statusLine: StubAGYProvider(result: .success(feed)))
        let result = try await combined.fetch()
        XCTAssertEqual(result.source, .statusLine)
        XCTAssertEqual(result.sourceTimes[.statusLine], feed.fetchedAt)
        XCTAssertEqual(result.metrics, feed.metrics)
    }

    @MainActor
    func testOlderStatusLineFallbackDoesNotOverwriteDirectSuccess() async throws {
        let suite = TestDefaults.suite("AGYDirectOlderFallback")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        let direct = ExternalUsageSnapshot(metrics: .quotas([QuotaMetric(name: "gemini-weekly", remainingPercent: 73, resetsAt: nil)]),
                                           fetchedAt: fetchedAt, source: .directCLI, sourceTimes: [.directCLI: fetchedAt])
        let feed = ExternalUsageSnapshot(metrics: .quotas([QuotaMetric(name: "gemini-weekly", remainingPercent: 49, resetsAt: nil)]),
                                         fetchedAt: fetchedAt.addingTimeInterval(-60), source: .statusLine,
                                         sourceTimes: [.statusLine: fetchedAt.addingTimeInterval(-60)])
        let provider = SequenceAGYProvider(results: [.success(direct), .success(feed)])
        let store = ExternalProviderStore(displaySettings: settings, providers: [.antigravity: provider])
        await store.refresh(.antigravity)?.value
        await store.refresh(.antigravity)?.value
        guard case .failure(.staleData, let previous) = store.state(for: .antigravity),
              case .quotas(let quotas) = previous?.metrics else { return XCTFail("expected last direct result") }
        XCTAssertEqual(quotas[0].remainingPercent, 73)
        XCTAssertEqual(store.agySourceTimes[.directCLI], fetchedAt)
        XCTAssertEqual(store.agySourceTimes[.statusLine], feed.fetchedAt)
    }

    @MainActor
    func testStorePreventsDuplicateAndRetainsLastSuccessOnFailure() async throws {
        let suite = TestDefaults.suite("AGYDirectDuplicate")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        let provider = ControlledAGYProvider()
        let store = ExternalProviderStore(displaySettings: settings, providers: [.antigravity: provider])
        let first = try XCTUnwrap(store.refresh(.antigravity))
        XCTAssertNil(store.refresh(.antigravity))
        await provider.complete(.success(ExternalUsageSnapshot(
            metrics: .quotas([QuotaMetric(name: "gemini-weekly", remainingPercent: 61, resetsAt: nil)]),
            fetchedAt: fetchedAt, source: .directCLI, sourceTimes: [.directCLI: fetchedAt])))
        await first.value
        XCTAssertEqual(store.agySourceTimes[.directCLI], fetchedAt)
        let second = try XCTUnwrap(store.refresh(.antigravity))
        await provider.complete(.failure(.timeout))
        await second.value
        guard case .failure(.timeout, let previous) = store.state(for: .antigravity),
              case .quotas(let quotas) = previous?.metrics else { return XCTFail("expected prior success") }
        XCTAssertEqual(quotas[0].remainingPercent, 61)
        XCTAssertEqual(previous?.fetchedAt, fetchedAt)
        let count = await provider.count
        XCTAssertEqual(count, 2)
    }

    func testCLIUnavailableIsClassifiedWithoutRunningCLI() async {
        let runner = AGYCLICommandRunner(executableURL: URL(fileURLWithPath: "/nonexistent/agy"))
        do { _ = try await runner.run(); XCTFail("expected unavailable") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .cliUnavailable) }
    }

    func testFakeCLIAuthenticationFailureAndTimeoutAreClassified() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("agy-test")
        try "#!/bin/sh\necho 'authentication required' >&2\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do { _ = try await AGYCLICommandRunner(executableURL: executable).run(); XCTFail("expected auth error") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .cliAuthenticationRequired) }
        try "#!/bin/sh\necho 'service unavailable' >&2\nexit 3\n".write(to: executable, atomically: true, encoding: .utf8)
        do { _ = try await AGYCLICommandRunner(executableURL: executable).run(); XCTFail("expected connection error") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .connection) }
        try "#!/bin/sh\nexec sleep 2\n".write(to: executable, atomically: true, encoding: .utf8)
        do { _ = try await AGYCLICommandRunner(executableURL: executable, timeout: 0.1).run(); XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? ExternalProviderError, .timeout) }
    }

    @MainActor
    func testAutomaticAGYAttemptsWaitFiveMinutesEvenAfterFailure() async throws {
        let suite = TestDefaults.suite("AGYDirectTimer")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaults.discard(defaults, suite: suite) }
        let settings = ProviderDisplaySettings(defaults: defaults)
        settings.showsAGY = true
        let clock = AGYTestClock(fetchedAt)
        let provider = CountingFailureAGYProvider()
        let store = ExternalProviderStore(displaySettings: settings, now: { clock.date },
                                          providers: [.antigravity: provider])
        store.refreshSelected()
        for _ in 0..<100 {
            if await provider.count >= 1 { break }
            await Task.yield()
        }
        let firstCount = await provider.count
        XCTAssertEqual(firstCount, 1)
        store.refreshSelected()
        clock.date.addTimeInterval(299)
        store.refreshSelected()
        let waitingCount = await provider.count
        XCTAssertEqual(waitingCount, 1)
        clock.date.addTimeInterval(1)
        store.refreshSelected()
        for _ in 0..<100 {
            if await provider.count >= 2 { break }
            await Task.yield()
        }
        let finalCount = await provider.count
        XCTAssertEqual(finalCount, 2)
    }
}

@MainActor
private final class AGYTestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private actor CountingFailureAGYProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    private(set) var count = 0
    func fetch() async throws -> ExternalUsageSnapshot {
        count += 1
        throw ExternalProviderError.connection
    }
}

private struct StubAGYProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    let result: Result<ExternalUsageSnapshot, ExternalProviderError>
    func fetch() async throws -> ExternalUsageSnapshot { try result.get() }
}

private actor SequenceAGYProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    private var results: [Result<ExternalUsageSnapshot, ExternalProviderError>]
    init(results: [Result<ExternalUsageSnapshot, ExternalProviderError>]) { self.results = results }
    func fetch() async throws -> ExternalUsageSnapshot { try results.removeFirst().get() }
}

private actor ControlledAGYProvider: ExternalUsageProvider {
    let id: ExternalProviderID = .antigravity
    private var continuation: CheckedContinuation<ExternalUsageSnapshot, Error>?
    private(set) var count = 0
    func fetch() async throws -> ExternalUsageSnapshot {
        count += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete(_ result: Result<ExternalUsageSnapshot, ExternalProviderError>) async {
        while continuation == nil { await Task.yield() }
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result.mapError { $0 as Error })
    }
}
