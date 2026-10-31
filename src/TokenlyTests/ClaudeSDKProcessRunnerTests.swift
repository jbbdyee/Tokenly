import Foundation
import XCTest
@testable import Tokenly

final class ClaudeSDKProcessRunnerTests: XCTestCase {
    private struct MockExecutor: ClaudeProcessExecuting {
        let run: () async throws -> Data
        func execute() async throws -> Data { try await run() }
    }

    private func fakeScript(_ body: String) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenly-claude-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("fake-helper.sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        return (folder, script)
    }

    private func executor(_ script: URL, timeout: TimeInterval = 2,
                          maxOutputBytes: Int = 16_384,
                          environment: [String: String] = [:]) -> ClaudeSubprocessExecutor {
        ClaudeSubprocessExecutor(runtimeURL: URL(fileURLWithPath: "/bin/sh"), helperURL: script,
                                 cliURL: URL(fileURLWithPath: "/usr/bin/true"),
                                 timeout: timeout, maxOutputBytes: maxOutputBytes,
                                 environment: environment)
    }

    func testFakeHelperSuccessAndChildEnvironmentSanitization() async throws {
        let (folder, script) = try fakeScript(#"""
        test -z "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC+x}" || exit 41
        test -z "${ANTHROPIC_API_KEY+x}" || exit 42
        test -z "${NODE_OPTIONS+x}" || exit 43
        printf '%s\n' '{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":25,"resets_at":null}}}'
        """#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try await executor(script, environment: [
            "PATH": "/usr/bin:/bin", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "ANTHROPIC_API_KEY": "fake-test-key", "NODE_OPTIONS": "fake-test-option",
        ]).execute()
        let result = try ClaudeDirectUsageParser.parse(data, receivedAt: Date())
        XCTAssertEqual(result.windows[.fiveHour]?.quota.remainingPercent, 75)
    }

    func testNonzeroExitAndMalformedOutputRemainSafe() async throws {
        let (folder, script) = try fakeScript("exit 7")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { _ = try await executor(script).execute(); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .transport) }
        try Data("kill -9 $$\n".utf8).write(to: script)
        do { _ = try await executor(script).execute(); XCTFail("expected signal failure") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .transport) }
        try Data("exit 23\n".utf8).write(to: script)
        do { _ = try await executor(script).execute(); XCTFail("expected SDK shape failure") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .incompatibleSDK) }
        try Data("exit 20\n".utf8).write(to: script)
        do { _ = try await executor(script).execute(); XCTFail("expected missing dependency") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .unavailable) }
        try Data("exit 22\n".utf8).write(to: script)
        do { _ = try await executor(script).execute(); XCTFail("expected unknown SDK error") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .sdkFailure) }
        try Data("exit 21\n".utf8).write(to: script)
        do { _ = try await executor(script).execute(); XCTFail("expected model activity guard") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .unexpectedModelActivity) }
        for (exitCode, expected) in [(24, ClaudeUsageRunnerError.authenticationRequired),
                                     (25, .permissionDenied), (26, .rateLimited)] {
            try Data("exit \(exitCode)\n".utf8).write(to: script)
            do { _ = try await executor(script).execute(); XCTFail("expected classified error") }
            catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, expected) }
        }
        try Data("printf 'bad json\\n'\n".utf8).write(to: script)
        let bad = try await executor(script).execute()
        XCTAssertThrowsError(try ClaudeDirectUsageParser.parse(bad, receivedAt: Date())) {
            XCTAssertEqual($0 as? ExternalProviderError, .invalidResponse)
        }
    }

    func testTimeoutAndOutputLimit() async throws {
        let (folder, script) = try fakeScript("sleep 3")
        defer { try? FileManager.default.removeItem(at: folder) }
        do { _ = try await executor(script, timeout: 0.1).execute(); XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .timeout) }
        try Data("printf '12345678901234567890\\n'\n".utf8).write(to: script)
        do { _ = try await executor(script, maxOutputBytes: 8).execute(); XCTFail("expected output cap") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .unsafeOutput) }
    }

    func testDuplicateRequestAndCancellationWithMockExecutor() async throws {
        let started = expectation(description: "first request started")
        let runner = ClaudeSDKProcessRunner(executor: MockExecutor(run: {
            started.fulfill()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return Data("{}".utf8)
        }))
        let first = Task { try await runner.getUsage() }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await runner.getUsage(); XCTFail("duplicate should fail") }
        catch { XCTAssertEqual(error as? ClaudeUsageRunnerError, .inProgress) }
        first.cancel()
        do { _ = try await first.value; XCTFail("cancelled request should fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellingFakeProcessStopsIt() async throws {
        let (folder, script) = try fakeScript("sleep 3")
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task { try await executor(script, timeout: 5).execute() }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
