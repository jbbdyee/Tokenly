import XCTest
@testable import Tokenly

final class ClaudeDirectUsageTests: XCTestCase {
    private struct MockRunner: ClaudeUsageRunning {
        let response: Result<Data, ClaudeUsageRunnerError>
        func getUsage() async throws -> Data { try response.get() }
    }

    private let received = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ json: String) throws -> ClaudeDirectResult {
        try ClaudeDirectUsageParser.parse(Data(json.utf8), receivedAt: received)
    }

    func testBothWindowsConvertUsedToRemainingAndPreserveCompletionTime() throws {
        let result = try parse(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":100,"resets_at":null},"seven_day":{"utilization":42.5,"resets_at":"2026-11-01T12:00:00Z"}}}"#)
        XCTAssertEqual(result.windows[.fiveHour]?.quota.remainingPercent, 0)
        XCTAssertNil(result.windows[.fiveHour]?.quota.resetsAt)
        XCTAssertEqual(result.windows[.sevenDay]?.quota.remainingPercent, 57.5)
        XCTAssertNotNil(result.windows[.sevenDay]?.quota.resetsAt)
        XCTAssertEqual(result.windows[.fiveHour]?.receivedAt, received)
        XCTAssertEqual(result.windows[.sevenDay]?.source, .directCLI)
    }

    func testMissingAndNullWindowsAreIndependent() throws {
        let missing = try parse(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":30,"resets_at":null}}}"#)
        XCTAssertNotNil(missing.windows[.fiveHour])
        XCTAssertNil(missing.windows[.sevenDay])
        let null = try parse(#"{"rate_limits_available":true,"rate_limits":{"five_hour":null,"seven_day":{"utilization":20,"resets_at":null}}}"#)
        XCTAssertNil(null.windows[.fiveHour])
        XCTAssertEqual(null.windows[.sevenDay]?.quota.remainingPercent, 80)
    }

    func testNullContainerIsDataUnavailable() {
        for json in [#"{"rate_limits_available":true,"rate_limits":null}"#,
                     #"{"rate_limits_available":true}"#,
                     #"{"rate_limits_available":true,"rate_limits":{"five_hour":null}}"#] {
            XCTAssertThrowsError(try parse(json)) { XCTAssertEqual($0 as? ExternalProviderError, .noData) }
        }
    }

    func testBadTypesAndOutOfRangeValuesRejectOnlyThatWindow() throws {
        for invalid in ["null", "true", #""25""#, "-1", "101", "{}"] {
            let json = #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":\#(invalid),"resets_at":null},"seven_day":{"utilization":25,"resets_at":null}}}"#
            let result = try parse(json)
            XCTAssertNil(result.windows[.fiveHour], invalid)
            XCTAssertEqual(result.windows[.sevenDay]?.quota.remainingPercent, 75)
        }
        XCTAssertThrowsError(try parse("not json")) { XCTAssertEqual($0 as? ExternalProviderError, .invalidResponse) }
    }

    func testInvalidResetKeepsRemainingWithUnknownTime() throws {
        for reset in ["null", #""tomorrow""#, #""2026-11-01T12:00:00""#] {
            let json = #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":35,"resets_at":\#(reset)}}}"#
            let result = try parse(json)
            XCTAssertEqual(result.windows[.fiveHour]?.quota.remainingPercent, 65)
            XCTAssertNil(result.windows[.fiveHour]?.quota.resetsAt)
        }
    }

    func testMockRunnerAndDisabledDefaultNeverLaunchSDK() async throws {
        let json = #"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":20,"resets_at":null}}}"#
        let provider = ClaudeDirectUsageProvider(runner: MockRunner(response: .success(Data(json.utf8))), now: { self.received })
        let result = try await provider.fetch()
        XCTAssertEqual(result.windows[.fiveHour]?.quota.remainingPercent, 80)
        do { _ = try await ClaudeDirectUsageProvider().fetch(); XCTFail("default runner must be disabled") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .unavailable) }
        for failure in [ClaudeUsageRunnerError.authenticationRequired, .permissionDenied,
                        .rateLimited, .timeout, .incompatibleSDK, .transport] {
            let failing = ClaudeDirectUsageProvider(runner: MockRunner(response: .failure(failure)))
            do { _ = try await failing.fetch(); XCTFail("mock failure expected") }
            catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, failure) }
        }
    }

    func testFailureRetainsLastSuccessAndStatusLineFallbackKeepsItsOwnTime() throws {
        let first = try parse(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":20,"resets_at":null}}}"#)
        var selection = ClaudeUsageSelection()
        selection.accept(first)
        selection.fail(.transport)
        XCTAssertEqual(selection.lastDirectSuccessAt, received)
        XCTAssertEqual(selection.lastDirectError, .transport)

        let statusTime = received.addingTimeInterval(100)
        let status = ExternalUsageSnapshot(metrics: .quotas([
            QuotaMetric(name: "5시간 한도", remainingPercent: 15, resetsAt: nil),
            QuotaMetric(name: "7일 한도", remainingPercent: 60, resetsAt: nil)
        ]), fetchedAt: statusTime)
        let fresh = selection.displayed(statusLine: status, now: statusTime,
                                        directMaxAge: 200)
        XCTAssertEqual(fresh[.fiveHour]?.value.source, .directCLI)
        XCTAssertEqual(fresh[.fiveHour]?.value.receivedAt, received)
        XCTAssertEqual(fresh[.sevenDay]?.value.source, .statusLine)
        XCTAssertEqual(fresh[.sevenDay]?.value.receivedAt, statusTime)

        let fallback = selection.displayed(statusLine: status, now: statusTime.addingTimeInterval(150),
                                           directMaxAge: 200)
        XCTAssertEqual(fallback[.fiveHour]?.value.source, .statusLine)
        XCTAssertEqual(fallback[.fiveHour]?.value.receivedAt, statusTime)
        let stale = selection.displayed(statusLine: status, now: statusTime.addingTimeInterval(1000),
                                        directMaxAge: 200)
        XCTAssertEqual(stale[.fiveHour]?.stale, true)
        XCTAssertEqual(stale[.fiveHour]?.value.receivedAt, statusTime)
    }

    func testPartialSuccessUpdatesOnlyReceivedWindowAndSuccessTime() throws {
        var selection = ClaudeUsageSelection()
        selection.accept(try parse(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":10,"resets_at":null}}}"#))
        let secondAt = received.addingTimeInterval(20)
        let second = try ClaudeDirectUsageParser.parse(Data(#"{"rate_limits_available":true,"rate_limits":{"seven_day":{"utilization":30,"resets_at":null}}}"#.utf8), receivedAt: secondAt)
        selection.accept(second)
        XCTAssertEqual(selection.lastDirectSuccessAt, secondAt)
        XCTAssertEqual(selection.directWindows[.fiveHour]?.receivedAt, received)
        XCTAssertEqual(selection.directWindows[.sevenDay]?.receivedAt, secondAt)
    }
}
