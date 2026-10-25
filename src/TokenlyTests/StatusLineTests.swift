import Darwin
import XCTest
@testable import Tokenly

/// Native status-line bridge, wrapper and connector. Every test uses a fresh temporary home and fake
/// settings; the real ~/.claude, ~/.gemini and ~/Library/Application Support/Tokenly are never touched.
final class StatusLineTests: XCTestCase {
    private var home: URL!
    private var paths: TokenlyPaths!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tokenly-statusline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = TokenlyPaths(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Helpers

    private var executable: String { Bundle.main.executableURL!.path }
    private let claudeSample = #"{"model":{"display_name":"x"},"session_id":"secret-session","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600},"spend_limit":{"used_percentage":5}}}"#
    private let agySample = #"{"quota":{"probe_a":{"remaining_fraction":0.75,"reset_time":"2026-10-24T10:00:00Z"},"bad":{"remaining_fraction":2},"flag":{"remaining_fraction":true}}}"#

    struct Run { let status: Int32; let stdout: String; let stderr: String; let seconds: Double }

    /// Runs the app executable with a minimal environment (no XCTest injection variables).
    @discardableResult
    private func run(_ arguments: [String], stdin: String = "", extraEnvironment: [String: String] = [:],
                     terminateAfter: TimeInterval? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TOKENLY_HOME": home.path, "LANG": "en_US.UTF-8"]
        environment.merge(extraEnvironment) { $1 }
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        if let terminateAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + terminateAfter) { process.terminate() }
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                   stderr: String(decoding: err, as: UTF8.self), seconds: Date().timeIntervalSince(start))
    }

    private func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
    private func json(_ url: URL) -> [String: Any]? {
        FileManager.default.contents(atPath: url.path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private func makeSettings(_ source: StatusLineSource, _ text: String?, mode: mode_t = 0o644) throws -> URL {
        let url = paths.settingsFile(source)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text {
            try Data(text.utf8).write(to: url)
            chmod(url.path, mode)
        }
        return url
    }
    private func connect(_ source: StatusLineSource, executable: String? = nil) throws -> StatusLineConnector.Result {
        let plan = try StatusLineConnector.planConnect(source: source, paths: paths, executable: executable ?? self.executable)
        return try StatusLineConnector.apply(plan, paths: paths)
    }
    private func noOrphan(_ marker: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", marker]
        p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
        return p.terminationStatus != 0
    }

    // MARK: Receiving

    func testClaudeRecordKeepsOnlyDocumentedWindowsWithExactNumbers() throws {
        let data = try XCTUnwrap(StatusLineReceiver.record(for: .claude, input: Data(claudeSample.utf8)))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"used_percentage\":41.2"), text)          // no 41.200000000000003
        XCTAssertFalse(text.contains("spend_limit") || text.contains("model") || text.contains("secret-session"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["captured_at"] as? String)
        // Readable by the app's existing parser (future resets so the windows are current).
        let current = claudeSample.replacingOccurrences(of: "1738425600", with: "4102444800")
            .replacingOccurrences(of: "1738857600", with: "4102531200")
        let stored = try XCTUnwrap(StatusLineReceiver.record(for: .claude, input: Data(current.utf8)))
        let snapshot = try ClaudeQuotaParser.parse(stored, now: Date())
        guard case .quotas(let quotas) = snapshot.metrics else { return XCTFail("expected quotas") }
        XCTAssertEqual(quotas.map(\.remainingPercent), [76.5, 58.8])
    }

    func testClaudeRangeTypesAndResetValidation() throws {
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":true},"seven_day":{"used_percentage":101}}}"#
        let object = try XCTUnwrap(StatusLineReceiver.record(for: .claude, input: Data(input.utf8))).jsonObject()
        XCTAssertEqual((object["rate_limits"] as? [String: Any])?.count, 0)       // recorded, but no windows
        let reset = #"{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":-5}}}"#
        let five = try XCTUnwrap(StatusLineReceiver.record(for: .claude, input: Data(reset.utf8))).jsonObject()["rate_limits"] as? [String: [String: Any]]
        XCTAssertTrue(five?["five_hour"]?["resets_at"] is NSNull)
    }

    func testAGYRecordKeepsValidBucketsOnlyAndSkipsEmpty() throws {
        let data = try XCTUnwrap(StatusLineReceiver.record(for: .agy, input: Data(agySample.utf8)))
        let quota = try data.jsonObject()["quota"] as? [String: Any]
        XCTAssertEqual(Set(quota?.keys ?? [:].keys), ["probe_a"])
        XCTAssertNil(StatusLineReceiver.record(for: .agy, input: Data(#"{"quota":{"x":{"remaining_fraction":-1}}}"#.utf8)))
        _ = try AGYQuotaParser.parse(data, now: Date())                        // readable by the app
    }

    func testInvalidInputsProduceNoRecord() {
        for input in ["not json", "[1,2]", "", "\"text\"", #"{"a":NaN}"#] {
            XCTAssertNil(StatusLineReceiver.record(for: .claude, input: Data(input.utf8)), input)
        }
    }

    func testInputLimitIsTwoMegabytes() throws {
        func read(_ count: Int) -> Data? {
            var fds: [Int32] = [0, 0]; pipe(&fds)
            let writer = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
            DispatchQueue.global().async { writer.write(Data(repeating: 0x20, count: count)); try? writer.close() }
            return StatusLineReceiver.readInput(from: FileHandle(fileDescriptor: fds[0], closeOnDealloc: true))
        }
        XCTAssertEqual(read(2_000_000)?.count, 2_000_000)
        XCTAssertNil(read(2_000_001))
    }

    // MARK: Bridge process

    func testBridgeProcessStoresPrivatelyAndPrintsOneEmptyLine() throws {
        let result = try run(["--statusline", "claude"], stdin: claudeSample)
        XCTAssertEqual(result.status, 0); XCTAssertEqual(result.stdout, "\n")
        let file = paths.quotaFile(.claude)
        XCTAssertEqual(mode(file), 0o600); XCTAssertEqual(mode(paths.dataFolder), 0o700)
        XCTAssertNotNil(json(file)?["rate_limits"])
        XCTAssertTrue(result.seconds < 2, "bridge took \(result.seconds)s")
    }

    func testBadInputKeepsPreviousFileAndExitsZero() throws {
        try run(["--statusline", "claude"], stdin: claudeSample)
        let before = try Data(contentsOf: paths.quotaFile(.claude))
        for input in ["not json", "", String(repeating: " ", count: 2_000_100)] {
            let result = try run(["--statusline", "claude"], stdin: input)
            XCTAssertEqual(result.status, 0); XCTAssertEqual(result.stdout, "\n")
        }
        XCTAssertEqual(try Data(contentsOf: paths.quotaFile(.claude)), before)
        XCTAssertEqual(try run(["--statusline", "nope"]).status, 64)
    }

    func testConcurrentBridgeWritesStayValidAndLeaveNoTempFiles() throws {
        let group = DispatchGroup()
        for i in 0..<24 {
            group.enter()
            DispatchQueue.global().async {
                _ = try? self.run(["--statusline", i.isMultiple(of: 2) ? "claude" : "agy"], stdin: i.isMultiple(of: 2) ? self.claudeSample : self.agySample)
                group.leave()
            }
        }
        group.wait()
        XCTAssertNotNil(json(paths.quotaFile(.claude))); XCTAssertNotNil(json(paths.quotaFile(.agy)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.dataFolder.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: Wrapping the original status line

    private func connectWithOriginal(_ command: String) throws {
        let original = ["type": "command", "command": command] as [String: Any]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["statusLine": original]), as: UTF8.self)
        _ = try makeSettings(.claude, text)
        _ = try connect(.claude)
    }

    func testWrapperStoresFirstThenPassesStdinStdoutAndExitStatus() throws {
        try connectWithOriginal(#"cat >/dev/null; printf 'line1\nline2 %s\n' "$(printf '%s' ok)"; exit 3"#)
        let result = try run(["--statusline", "claude"], stdin: claudeSample)
        XCTAssertEqual(result.stdout, "line1\nline2 ok\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertNotNil(json(paths.quotaFile(.claude))?["rate_limits"], "quota stored even though the original failed")
        let echo = try run(["--statusline", "claude"], stdin: "abc", extraEnvironment: [:])
        XCTAssertEqual(echo.status, 3)                                            // same command, stdin not JSON
    }

    func testWrapperForwardsExactStdinAndSpecialCharacters() throws {
        try connectWithOriginal(#"printf '%s|' "a b" 'c"d' '$HOME' "$(cat)""#)
        let result = try run(["--statusline", "claude"], stdin: claudeSample)
        XCTAssertEqual(result.stdout, "a b|c\"d|$HOME|\(claudeSample)|")
        XCTAssertEqual(result.status, 0)
    }

    func testWrapperFailureOutputIsPreserved() throws {
        try connectWithOriginal("echo partial; echo oops >&2; exit 1")
        let result = try run(["--statusline", "claude"], stdin: claudeSample)
        XCTAssertEqual(result.stdout, "partial\n"); XCTAssertEqual(result.status, 1)
    }

    func testWrapperTimeoutKillsProcessGroup() throws {
        let marker = "sleep 30.\(Int.random(in: 1000...9999))"
        try connectWithOriginal("\(marker); echo late")
        let result = try run(["--statusline", "claude"], stdin: claudeSample, extraEnvironment: ["TOKENLY_STATUSLINE_TIMEOUT": "0.5"])
        XCTAssertEqual(result.status, ChildCommand.timedOutStatus)
        XCTAssertFalse(result.stdout.contains("late"))
        XCTAssertTrue(result.seconds < 3, "\(result.seconds)s")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(noOrphan(marker))
    }

    func testCancellationKillsChildAndGrandchildren() throws {
        let marker = "sleep 31.\(Int.random(in: 1000...9999))"
        try connectWithOriginal("sh -c '\(marker)'; echo late")
        let result = try run(["--statusline", "claude"], stdin: claudeSample, terminateAfter: 0.6)
        XCTAssertEqual(result.status, 128 + SIGTERM)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(noOrphan(marker))
        XCTAssertNotNil(json(paths.quotaFile(.claude)), "quota stored before the original ran")
    }

    func testRecursionIsStopped() throws {
        // 1. A Tokenly command is never kept as the "original".
        _ = try makeSettings(.claude, #"{"statusLine":{"type":"command","command":"'/x/Tokenly.app/Contents/MacOS/Tokenly' --statusline claude"}}"#)
        _ = try connect(.claude)
        XCTAssertNil(StatusLineConnector.originalCommand(for: .claude, paths: paths))
        // 2. A hidden re-entry through a script stops at the environment guard.
        let hook = home.appendingPathComponent("hook.sh")
        try Data("#!/bin/sh\necho hook-ran\n\(StatusLineConnector.shellQuote(executable)) --statusline claude\n".utf8).write(to: hook)
        chmod(hook.path, 0o755)
        try FileManager.default.removeItem(at: paths.connectionRecord(.claude))
        try FileManager.default.removeItem(at: paths.settingsFile(.claude))
        try connectWithOriginal(StatusLineConnector.shellQuote(hook.path))
        let result = try run(["--statusline", "claude"], stdin: claudeSample)
        XCTAssertEqual(result.stdout, "hook-ran\n\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.seconds < 3)
        // 3. The guard itself: nothing stored, nothing run.
        try FileManager.default.removeItem(at: paths.quotaFile(.claude))
        let guarded = try run(["--statusline", "claude"], stdin: claudeSample, extraEnvironment: [StatusLineBridge.activeEnvironmentKey: "1"])
        XCTAssertEqual(guarded.stdout, "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.quotaFile(.claude).path))
    }

    // MARK: Connect / disconnect

    func testConnectCreatesMissingSettingsFileWith0600() throws {
        let url = try makeSettings(.claude, nil)
        let result = try connect(.claude)
        XCTAssertNil(result.backup)
        XCTAssertEqual(mode(url), 0o600)
        let statusLine = try XCTUnwrap(json(url)?["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertTrue(StatusLineConnector.isTokenlyNative(statusLine["command"] as? String ?? ""))
        XCTAssertEqual(mode(paths.connectionRecord(.claude)), 0o600)
        XCTAssertEqual(mode(paths.connectionFolder), 0o700)
    }

    func testConnectRefusesWhenCLIFolderIsMissing() {
        XCTAssertThrowsError(try StatusLineConnector.planConnect(source: .agy, paths: paths, executable: executable))
    }

    func testConnectWrapsExistingAndKeepsEveryOtherByte() throws {
        let original = """
        {
            "model": "opus",
            "permissions": { "allow": ["Bash(git *)"], "deny": [] },
            "statusLine": {"type": "command", "command": "~/bin/status.sh --name 'a b' \\"q\\"", "padding": 2},
            "env": {"NOTE": "한글 ✓"}
        }

        """
        let url = try makeSettings(.claude, original, mode: 0o644)
        let result = try connect(.claude)
        let after = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        // Text outside the statusLine value is untouched.
        let prefix = original.components(separatedBy: "\"statusLine\": ")[0]
        let suffix = original.components(separatedBy: "\"padding\": 2}")[1]
        XCTAssertTrue(after.hasPrefix(prefix + "\"statusLine\": "), after)
        XCTAssertTrue(after.hasSuffix(suffix), after)
        XCTAssertEqual(mode(url), 0o644)                                          // permissions preserved
        let statusLine = try XCTUnwrap(json(url)?["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertTrue(StatusLineConnector.isTokenlyNative(statusLine["command"] as? String ?? ""))
        // Backup is byte-identical and private; the original object is recorded in full.
        let backup = try XCTUnwrap(result.backup)
        XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8)); XCTAssertEqual(mode(backup), 0o600)
        XCTAssertEqual(mode(paths.backupFolder), 0o700)
        let recorded = try XCTUnwrap(json(paths.connectionRecord(.claude))?["original"] as? [String: Any])
        XCTAssertEqual(recorded["command"] as? String, #"~/bin/status.sh --name 'a b' "q""#)
        XCTAssertEqual(recorded["padding"] as? Int, 2)
        XCTAssertEqual(StatusLineConnector.originalCommand(for: .claude, paths: paths), #"~/bin/status.sh --name 'a b' "q""#)
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .connected)
    }

    func testDisconnectRestoresTheOriginalObjectExactly() throws {
        let original = #"{"a":1,"statusLine":{"type":"command","command":"echo hi","padding":1},"b":[2,3]}"#
        let url = try makeSettings(.claude, original)
        _ = try connect(.claude)
        let result = try StatusLineConnector.apply(try StatusLineConnector.planDisconnect(source: .claude, paths: paths), paths: paths)
        XCTAssertNotNil(result.backup)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), original)   // byte-identical, formatting kept
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.connectionRecord(.claude).path))
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .otherCommand)
    }

    func testDisconnectRestoresOriginalFormattingByteForByte() throws {
        let original = "{\n  \"model\": \"opus\",\n  \"statusLine\": { \"type\" : \"command\",\n    \"command\": \"echo \\\"my status\\\"\", \"padding\": 1 }\n}\n"
        let url = try makeSettings(.claude, original)
        _ = try connect(.claude)
        XCTAssertNotEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), original)
        _ = try StatusLineConnector.apply(try StatusLineConnector.planDisconnect(source: .claude, paths: paths), paths: paths)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), original)
    }

    func testDisconnectRemovesStatusLineWhenThereWasNoneBefore() throws {
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        let url = try makeSettings(.claude, original)
        _ = try connect(.claude)
        _ = try StatusLineConnector.apply(try StatusLineConnector.planDisconnect(source: .claude, paths: paths), paths: paths)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), original)   // byte-identical again
    }

    func testDisconnectRefusesAfterUserChangedTheStatusLine() throws {
        let url = try makeSettings(.claude, #"{"statusLine":{"type":"command","command":"echo old"}}"#)
        _ = try connect(.claude)
        let userEdit = #"{"statusLine":{"type":"command","command":"echo mine-now"}}"#
        try Data(userEdit.utf8).write(to: url)
        XCTAssertThrowsError(try StatusLineConnector.planDisconnect(source: .claude, paths: paths))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), userEdit)
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .modifiedAfterConnect)
        // An unrelated user status line (never connected) is never touched either.
        try FileManager.default.removeItem(at: paths.connectionRecord(.claude))
        XCTAssertThrowsError(try StatusLineConnector.planDisconnect(source: .claude, paths: paths))
    }

    func testInvalidJSONSymlinkAndDuplicateKeysAreRefused() throws {
        let url = try makeSettings(.claude, "{ not json")
        XCTAssertThrowsError(try StatusLineConnector.planConnect(source: .claude, paths: paths, executable: executable))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "{ not json")
        try FileManager.default.removeItem(at: url)
        let target = home.appendingPathComponent("real-settings.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try StatusLineConnector.planConnect(source: .claude, paths: paths, executable: executable))
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        try FileManager.default.removeItem(at: url)
        _ = try makeSettings(.claude, #"{"statusLine":{"type":"command","command":"a"},"statusLine":{"type":"command","command":"b"}}"#)
        XCTAssertThrowsError(try StatusLineConnector.planConnect(source: .claude, paths: paths, executable: executable))
    }

    func testConcurrentEditBetweenReadAndWriteAborts() throws {
        let url = try makeSettings(.claude, #"{"x":1}"#)
        let plan = try StatusLineConnector.planConnect(source: .claude, paths: paths, executable: executable)
        XCTAssertThrowsError(try StatusLineConnector.apply(plan, paths: paths) {
            try? Data(#"{"x":2}"#.utf8).write(to: url)
        })
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), #"{"x":2}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.connectionRecord(.claude).path), "record rolled back")
    }

    func testCommandQuotingWithSpacesQuotesAndDollar() throws {
        let weird = "/tmp/My Apps/To'k$en ly/Tokenly.app/Contents/MacOS/Tokenly"
        let command = StatusLineConnector.tokenlyCommand(executable: weird, source: .claude)
        XCTAssertTrue(StatusLineConnector.isTokenlyNative(command))
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf '%s\\n' " + StatusLineConnector.shellQuote(weird)]
        let out = Pipe(); p.standardOutput = out; try p.run(); p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), weird + "\n")
        _ = try makeSettings(.claude, "{}")
        _ = try connect(.claude, executable: weird)
        XCTAssertEqual((json(paths.settingsFile(.claude))?["statusLine"] as? [String: Any])?["command"] as? String, command)
    }

    func testLegacyPythonCommandIsUpgradedAndRemovable() throws {
        let legacy = #"{"statusLine":{"type":"command","command":"/usr/bin/python3 '/Applications/Tokenly.app/Contents/Resources/ClaudeStatusLineBridge.py'"}}"#
        let url = try makeSettings(.claude, legacy)
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .legacyPython)
        _ = try connect(.claude)
        XCTAssertNil(StatusLineConnector.originalCommand(for: .claude, paths: paths))
        XCTAssertTrue(StatusLineConnector.isTokenlyNative((json(url)?["statusLine"] as? [String: Any])?["command"] as? String ?? ""))
        try Data(legacy.utf8).write(to: url)
        try FileManager.default.removeItem(at: paths.connectionRecord(.claude))
        _ = try StatusLineConnector.apply(try StatusLineConnector.planDisconnect(source: .claude, paths: paths), paths: paths)
        XCTAssertNil(json(url)?["statusLine"])
    }

    func testAGYKeepsStackWithDefaultAndOriginalOptions() throws {
        let url = try makeSettings(.agy, #"{"theme":"x","statusLine":{"type":"command","command":"echo agy","stack_with_default":false}}"#, mode: 0o600)
        _ = try connect(.agy)
        let statusLine = try XCTUnwrap(json(url)?["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["stack_with_default"] as? Bool, false)          // the user's choice is kept
        XCTAssertEqual(StatusLineConnector.originalCommand(for: .agy, paths: paths), "echo agy")
        XCTAssertEqual(mode(url), 0o600)
        let fresh = try makeSettings(.agy, #"{"theme":"x"}"#)
        try FileManager.default.removeItem(at: paths.connectionRecord(.agy))
        _ = try connect(.agy)
        XCTAssertEqual((json(fresh)?["statusLine"] as? [String: Any])?["stack_with_default"] as? Bool, true)
    }

    func testAlreadyConnectedIsANoOp() throws {
        _ = try makeSettings(.claude, "{}")
        _ = try connect(.claude)
        let plan = try StatusLineConnector.planConnect(source: .claude, paths: paths, executable: executable)
        XCTAssertTrue(plan.noChange)
    }

    func testEmptyObjectAndEmptyFileGetAStatusLine() throws {
        for text in ["{}", "  {  }  ", ""] {
            let url = try makeSettings(.claude, text)
            try? FileManager.default.removeItem(at: paths.connectionRecord(.claude))
            _ = try connect(.claude)
            XCTAssertNotNil(json(url)?["statusLine"], text)
        }
    }

    // MARK: CLI

    func testDryRunAndMissingConfirmationChangeNothing() throws {
        let original = #"{"statusLine":{"type":"command","command":"echo mine"}}"#
        let url = try makeSettings(.claude, original)
        let env = ["TOKENLY_ALLOW_ANY_LOCATION": "1"]
        let dry = try run(["--connect", "claude", "--dry-run"], extraEnvironment: env)
        XCTAssertEqual(dry.status, 0); XCTAssertTrue(dry.stdout.contains("미리보기"))
        let noConfirm = try run(["--connect", "claude"], extraEnvironment: env)
        XCTAssertEqual(noConfirm.status, 4)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backupFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.connectionRecord(.claude).path))
    }

    func testConnectFromUnstableLocationIsRefused() throws {
        _ = try makeSettings(.claude, "{}")
        let result = try run(["--connect", "claude", "--yes"])
        XCTAssertEqual(result.status, 2)                                          // Debug build is not in /Applications
        XCTAssertEqual(String(decoding: try Data(contentsOf: paths.settingsFile(.claude)), as: UTF8.self), "{}")
    }

    func testCLIConnectAndDisconnectRoundTrip() throws {
        let original = #"{"statusLine":{"type":"command","command":"echo mine"}}"#
        let url = try makeSettings(.claude, original)
        let env = ["TOKENLY_ALLOW_ANY_LOCATION": "1"]
        XCTAssertEqual(try run(["--connect", "claude", "--yes"], extraEnvironment: env).status, 0)
        XCTAssertEqual(try run(["--statusline", "claude"], stdin: claudeSample).stdout, "mine\n")
        let disconnected = try run(["--disconnect", "claude", "--yes"])
        XCTAssertEqual(disconnected.status, 0, disconnected.stderr)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), original)
    }

    func testStatusDoesNotPrintOtherCommands() throws {
        _ = try makeSettings(.claude, #"{"statusLine":{"type":"command","command":"echo TOKEN=SECRET123"}}"#)
        let result = try run(["--status"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("다른 statusLine 사용 중"))
        XCTAssertFalse(result.stdout.contains("SECRET123"))
    }

    func testUnknownArgumentsStartTheAppNormally() {
        XCTAssertNil(BridgeCommand.runIfRequested(arguments: ["Tokenly"]))
        XCTAssertNil(BridgeCommand.runIfRequested(arguments: ["Tokenly", "-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(BridgeCommand.runIfRequested(arguments: ["Tokenly", "-ApplePersistenceIgnoreState", "YES"]))
    }
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}
