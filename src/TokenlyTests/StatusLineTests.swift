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
                     terminateAfter: TimeInterval? = nil, program: String? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program ?? executable)
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

    // MARK: Connection record v2 (previous) and restore

    /// A fake Tokenly 0.1.0 Python bridge inside the temporary home; returns the exact 0.1.0 command.
    private func legacyCommand(_ source: StatusLineSource) throws -> String {
        let dir = home.appendingPathComponent("Apps/Tokenly.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(source == .claude ? "ClaudeStatusLineBridge.py" : "AGYStatusLineBridge.py")
        try Data("print('')\n".utf8).write(to: file)
        return "/usr/bin/python3 '\(file.path)'"
    }
    private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
    private func record(_ source: StatusLineSource) -> [String: Any]? { json(paths.connectionRecord(source)) }
    private func disconnectPlan(_ source: StatusLineSource) throws -> StatusLineConnector.Plan {
        try StatusLineConnector.planDisconnect(source: source, paths: paths)
    }
    private func installedNative(_ source: StatusLineSource) -> [String: Any] {
        var value: [String: Any] = ["type": "command", "command": StatusLineConnector.tokenlyCommand(executable: executable, source: source)]
        if source == .agy { value["stack_with_default"] = true }
        return value
    }
    /// A version 1 record exactly as Tokenly 0.1.0 (2) wrote it after connecting from a Python bridge.
    private func writeV1Record(_ source: StatusLineSource, connectedAt: Date) throws {
        try PrivateFile.ensureFolder(paths.dataFolder); try PrivateFile.ensureFolder(paths.connectionFolder)
        let value: [String: Any] = ["version": 1, "source": source.rawValue, "settingsPath": paths.settingsFile(source).path,
                                    "connectedAt": StatusLineReceiver.timestamp(connectedAt), "installed": installedNative(source),
                                    "original": NSNull()]
        try PrivateFile.writeAtomically(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                                        to: paths.connectionRecord(source))
    }
    @discardableResult
    private func writeBackup(_ source: StatusLineSource, _ content: String, at date: Date, suffix: String = "a1b2c3") throws -> URL {
        try PrivateFile.ensureFolder(paths.dataFolder); try PrivateFile.ensureFolder(paths.backupFolder)
        let url = paths.backupFolder.appendingPathComponent(
            "\(source.rawValue)-settings-\(StatusLineConnector.backupDateFormatter().string(from: date))-\(suffix).json")
        try PrivateFile.writeAtomically(Data(content.utf8), to: url)
        return url
    }
    private var wholeSecond: Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60) }

    func testJSONEqualityIgnoresFormattingButKeepsTypes() throws {
        func parse(_ s: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(s.utf8)) }
        XCTAssertTrue(StatusLineConnector.jsonEqual(try parse(#"{"a":1,"b":[true,null,"x"]}"#),
                                                    try parse("{\n  \"b\" : [ true, null, \"x\" ],\n  \"a\" : 1\n}")))
        XCTAssertTrue(StatusLineConnector.jsonEqual(try parse(#"{"n":1}"#), try parse(#"{"n":1.0}"#)))   // one JSON number type
        XCTAssertFalse(StatusLineConnector.jsonEqual(try parse(#"{"s":true}"#), try parse(#"{"s":1}"#)))
        XCTAssertFalse(StatusLineConnector.jsonEqual(try parse(#"{"s":false}"#), try parse(#"{"s":0}"#)))
        XCTAssertFalse(StatusLineConnector.jsonEqual(try parse(#"{"s":"1"}"#), try parse(#"{"s":1}"#)))
        XCTAssertFalse(StatusLineConnector.jsonEqual(try parse(#"{"s":null}"#), try parse(#"{}"#)))
        XCTAssertFalse(StatusLineConnector.jsonEqual(try parse(#"{"a":[1,2]}"#), try parse(#"{"a":[2,1]}"#)))
        XCTAssertFalse(StatusLineConnector.jsonEqual(try parse(#"{"n":1}"#), try parse(#"{"n":1.5}"#)))
    }

    func testClaudePythonToSwiftAndBackRestoresThePythonCommandByteForByte() throws {
        let python = try legacyCommand(.claude)
        let original = "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"\(python)\"\n  },\n  \"theme\": \"dark\",\n  \"enabledPlugins\": {\"x\": true}\n}\n"
        let url = try makeSettings(.claude, original, mode: 0o600)
        let result = try connect(.claude)
        // Not wrapped (Python would write the same file twice), but remembered for disconnect.
        XCTAssertNil(StatusLineConnector.originalCommand(for: .claude, paths: paths))
        let saved = try XCTUnwrap(record(.claude))
        XCTAssertEqual(saved["version"] as? Int, 2)
        XCTAssertTrue(saved["original"] is NSNull)
        let previous = try XCTUnwrap(saved["previous"] as? [String: Any])
        XCTAssertEqual(previous["state"] as? String, "legacyPython")
        XCTAssertEqual((previous["value"] as? [String: Any])?["command"] as? String, python)
        XCTAssertEqual(saved["backupFile"] as? String, result.backup?.path)
        XCTAssertEqual(StatusLineConnector.disconnectDescription(source: .claude, paths: paths), "Tokenly 0.1.0 Python 브리지 명령 복원")
        let plan = try disconnectPlan(.claude)
        XCTAssertTrue(plan.summary.contains { $0.contains("Python 브리지 명령을 복원합니다") }, "\(plan.summary)")
        XCTAssertFalse(plan.summary.contains { $0.contains("없었습니다") })
        _ = try StatusLineConnector.apply(plan, paths: paths)
        XCTAssertEqual(try text(url), original)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.connectionRecord(.claude).path))
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .legacyPython)
    }

    func testAGYPythonToSwiftSurvivesReformatAndRestoresMultilineTextAndOtherChanges() throws {
        let python = try legacyCommand(.agy)
        let statusText = "{\n    \"type\": \"command\",\n    \"command\": \"\(python)\",\n    \"stack_with_default\": true,\n    \"padding\": 1\n  }"
        let original = "{\n  \"permissions\": {\"allow\": [\"command(ls)\"]},\n  \"statusLine\": \(statusText),\n  \"trustedWorkspaces\": [\n    \"/a\"\n  ]\n}\n"
        let url = try makeSettings(.agy, original, mode: 0o600)
        _ = try connect(.agy)
        let installed = try XCTUnwrap(json(url)?["statusLine"] as? [String: Any])
        XCTAssertEqual(installed["stack_with_default"] as? Bool, true)
        XCTAssertEqual(installed["padding"] as? Int, 1)                           // options of the replaced line are kept
        XCTAssertTrue(StatusLineConnector.isTokenlyNative(installed["command"] as? String ?? "", source: .agy))
        // AGY rewrites the file: other key order, pretty printing, and a workspace the user trusted meanwhile.
        let command = installed["command"] as! String
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let reformatted = "{\n  \"permissions\": {\n    \"allow\": [\n      \"command(ls)\"\n    ]\n  },\n  \"statusLine\": {\n    \"padding\": 1,\n    \"stack_with_default\": true,\n    \"command\": \"\(escaped)\",\n    \"type\": \"command\"\n  },\n  \"trustedWorkspaces\": [\n    \"/a\",\n    \"/b\"\n  ]\n}\n"
        try Data(reformatted.utf8).write(to: url)
        XCTAssertEqual(try StatusLineConnector.state(source: .agy, paths: paths), .connected)
        XCTAssertTrue(try StatusLineConnector.planConnect(source: .agy, paths: paths, executable: executable).noChange)
        _ = try StatusLineConnector.apply(try disconnectPlan(.agy), paths: paths)
        let restored = try text(url)
        XCTAssertTrue(restored.contains("\"statusLine\": " + statusText), restored)   // the exact original text
        XCTAssertEqual(json(url)?["trustedWorkspaces"] as? [String], ["/a", "/b"])  // the later change is kept
        XCTAssertEqual(mode(url), 0o600)
    }

    func testNoStatusLineAndUserCommandAreRecordedAndRestored() throws {
        let url = try makeSettings(.claude, "{\n  \"theme\": \"dark\"\n}\n")
        _ = try connect(.claude)
        XCTAssertEqual((record(.claude)?["previous"] as? [String: Any])?["state"] as? String, "absent")
        XCTAssertTrue(try disconnectPlan(.claude).summary.contains { $0.contains("없었습니다 → statusLine을 제거") })
        _ = try StatusLineConnector.apply(try disconnectPlan(.claude), paths: paths)
        XCTAssertEqual(try text(url), "{\n  \"theme\": \"dark\"\n}\n")

        let user = #"{"statusLine": {"type":"command", "command":"echo mine", "padding": 2}}"#
        _ = try makeSettings(.claude, user)
        _ = try connect(.claude)
        let previous = try XCTUnwrap(record(.claude)?["previous"] as? [String: Any])
        XCTAssertEqual(previous["state"] as? String, "userCommand")
        XCTAssertEqual(previous["text"] as? String, #"{"type":"command", "command":"echo mine", "padding": 2}"#)
        XCTAssertEqual(StatusLineConnector.originalCommand(for: .claude, paths: paths), "echo mine")
        XCTAssertEqual(StatusLineConnector.disconnectDescription(source: .claude, paths: paths), "연결 전 statusLine 복원")
        _ = try StatusLineConnector.apply(try disconnectPlan(.claude), paths: paths)
        XCTAssertEqual(try text(paths.settingsFile(.claude)), user)
    }

    func testReconnectKeepsTheFirstPrevious() throws {
        let python = try legacyCommand(.claude)
        let original = #"{"statusLine":{"type":"command","command":"\#(python)"}}"#
        let url = try makeSettings(.claude, original)
        _ = try connect(.claude)
        let first = try XCTUnwrap(record(.claude))
        XCTAssertTrue(try StatusLineConnector.planConnect(source: .claude, paths: paths, executable: executable).noChange)
        // The user tweaks an option of the Tokenly line; connecting again re-aligns it but keeps the first previous.
        var tweaked = try XCTUnwrap(json(url)?["statusLine"] as? [String: Any]); tweaked["padding"] = 3
        try JSONSerialization.data(withJSONObject: ["statusLine": tweaked]).write(to: url)
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .modifiedAfterConnect)
        _ = try connect(.claude)
        let second = try XCTUnwrap(record(.claude))
        XCTAssertTrue(StatusLineConnector.jsonEqual(second["previous"] as Any, first["previous"] as Any))
        XCTAssertEqual(second["connectedAt"] as? String, first["connectedAt"] as? String)
        XCTAssertEqual(second["backupFile"] as? String, first["backupFile"] as? String)
        XCTAssertNotNil(second["updatedAt"])
        _ = try StatusLineConnector.apply(try disconnectPlan(.claude), paths: paths)
        XCTAssertEqual(try text(url), original)
    }

    func testChangedConnectedLineIsNeverOverwritten() throws {
        let python = try legacyCommand(.agy)
        let url = try makeSettings(.agy, #"{"statusLine":{"type":"command","command":"\#(python)","stack_with_default":true}}"#)
        _ = try connect(.agy)
        var line = try XCTUnwrap(json(url)?["statusLine"] as? [String: Any])
        line["stack_with_default"] = 1                                           // looks equal to `true` to NSObject.isEqual
        let edited = try JSONSerialization.data(withJSONObject: ["statusLine": line])
        try edited.write(to: url)
        XCTAssertEqual(try StatusLineConnector.state(source: .agy, paths: paths), .modifiedAfterConnect)
        XCTAssertThrowsError(try disconnectPlan(.agy))
        XCTAssertEqual(try Data(contentsOf: url), edited)
    }

    func testPythonRestoreIsRefusedWhenTheBridgeScriptIsGone() throws {
        let python = try legacyCommand(.claude)
        let url = try makeSettings(.claude, #"{"statusLine":{"type":"command","command":"\#(python)"}}"#)
        _ = try connect(.claude)
        let connected = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: home.appendingPathComponent("Apps/Tokenly.app/Contents/Resources/ClaudeStatusLineBridge.py"))
        XCTAssertThrowsError(try disconnectPlan(.claude)) { XCTAssertTrue("\($0)".contains("Python 브리지 파일이 없어")) }
        XCTAssertTrue(StatusLineConnector.disconnectDescription(source: .claude, paths: paths).hasPrefix("해제 불가"))
        XCTAssertEqual(try Data(contentsOf: url), connected)
    }

    func testVersion1RecordIsResolvedFromItsConnectBackup() throws {
        let python = try legacyCommand(.claude)
        let before = "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"\(python)\"\n  },\n  \"theme\": \"dark\"\n}\n"
        let at = wholeSecond
        let backup = try writeBackup(.claude, before, at: at.addingTimeInterval(0.7))
        let connected = String(data: try JSONMemberEditor.setting(member: "statusLine", to: installedNative(.claude), in: Data(before.utf8)), encoding: .utf8)!
        let url = try makeSettings(.claude, connected, mode: 0o600)
        try writeV1Record(.claude, connectedAt: at)
        let recordBytes = try Data(contentsOf: paths.connectionRecord(.claude))
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .connected)
        XCTAssertEqual(StatusLineConnector.disconnectDescription(source: .claude, paths: paths),
                       "Tokenly 0.1.0 Python 브리지 명령 복원 (연결 때 만든 백업에서 확인)")
        let plan = try disconnectPlan(.claude)
        XCTAssertTrue(plan.summary.contains { $0.contains("Python 브리지 명령을 복원합니다") })
        XCTAssertTrue(plan.summary.contains { $0.contains("연결할 때 만든 백업") && $0.contains(backup.lastPathComponent) })
        XCTAssertEqual(try Data(contentsOf: paths.connectionRecord(.claude)), recordBytes)   // planning never rewrites v1 records
        _ = try StatusLineConnector.apply(plan, paths: paths)
        XCTAssertEqual(try text(url), before)
        XCTAssertEqual(mode(url), 0o600)

        // A v1 record whose backup had no status line: disconnecting removes it.
        let empty = "{\n  \"theme\": \"dark\"\n}\n"
        try FileManager.default.removeItem(at: paths.backupFolder)
        let later = at.addingTimeInterval(3600)
        try writeBackup(.claude, empty, at: later.addingTimeInterval(0.2))
        _ = try makeSettings(.claude, String(data: try JSONMemberEditor.setting(member: "statusLine", to: installedNative(.claude), in: Data(empty.utf8)), encoding: .utf8)!)
        try writeV1Record(.claude, connectedAt: later)
        XCTAssertEqual(StatusLineConnector.disconnectDescription(source: .claude, paths: paths), "statusLine 제거 (연결 전 없음) (연결 때 만든 백업에서 확인)")
        _ = try StatusLineConnector.apply(try disconnectPlan(.claude), paths: paths)
        XCTAssertEqual(try text(paths.settingsFile(.claude)), empty)
    }

    func testVersion1RecordWithMissingAmbiguousOrInconsistentBackupIsRefused() throws {
        let python = try legacyCommand(.claude)
        let agyPython = try legacyCommand(.agy)
        let legacy = #"{"statusLine":{"type":"command","command":"\#(python)"}}"#
        let at = wholeSecond
        let connected = String(data: try JSONMemberEditor.setting(member: "statusLine", to: installedNative(.claude), in: Data(legacy.utf8)), encoding: .utf8)!
        let url = try makeSettings(.claude, connected)
        try writeV1Record(.claude, connectedAt: at)
        func assertRefused(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try disconnectPlan(.claude), label, file: file, line: line) {
                XCTAssertTrue("\($0)".contains("확인할 수 없어"), "\(label): \($0)", file: file, line: line)
            }
            XCTAssertTrue(StatusLineConnector.disconnectDescription(source: .claude, paths: paths).hasPrefix("해제 불가"), label, file: file, line: line)
            XCTAssertEqual(try? text(url), connected, label, file: file, line: line)          // never removed or changed
        }
        func reset() { try? FileManager.default.removeItem(at: paths.backupFolder) }

        assertRefused("no backup folder")
        try writeBackup(.claude, legacy, at: at.addingTimeInterval(-5)); assertRefused("backup before connect"); reset()
        try writeBackup(.claude, legacy, at: at.addingTimeInterval(StatusLineConnector.legacyBackupWindow + 1)); assertRefused("backup too late"); reset()
        try writeBackup(.agy, legacy, at: at.addingTimeInterval(0.5)); assertRefused("backup of the other source"); reset()
        try writeBackup(.claude, legacy, at: at.addingTimeInterval(0.5), suffix: "aaaaaa")
        try writeBackup(.claude, legacy, at: at.addingTimeInterval(2), suffix: "bbbbbb"); assertRefused("two candidates"); reset()
        try writeBackup(.claude, #"{"statusLine":{"type":"command","command":"echo user"}}"#, at: at.addingTimeInterval(0.5)); assertRefused("user command in backup"); reset()
        try writeBackup(.claude, #"{"statusLine":{"type":"command","command":"\#(agyPython)"}}"#, at: at.addingTimeInterval(0.5)); assertRefused("AGY bridge in Claude backup"); reset()
        try writeBackup(.claude, #"{"statusLine":{"type":"command","command":"python3 \#(python)"}}"#, at: at.addingTimeInterval(0.5)); assertRefused("not the 0.1.0 command form"); reset()
        try writeBackup(.claude, "{ not json", at: at.addingTimeInterval(0.5)); assertRefused("invalid JSON"); reset()
        try writeBackup(.claude, "", at: at.addingTimeInterval(0.5)); assertRefused("empty backup"); reset()
        try writeBackup(.claude, connected, at: at.addingTimeInterval(0.5)); assertRefused("backup equals the connected state"); reset()
        // A symlinked candidate pointing outside the backup folder.
        let outside = home.appendingPathComponent("outside.json"); try Data(legacy.utf8).write(to: outside)
        try PrivateFile.ensureFolder(paths.dataFolder); try PrivateFile.ensureFolder(paths.backupFolder)
        let link = paths.backupFolder.appendingPathComponent("claude-settings-\(StatusLineConnector.backupDateFormatter().string(from: at.addingTimeInterval(0.5)))-cccccc.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside); assertRefused("symlinked backup"); reset()
        // A record for another settings path.
        try writeBackup(.claude, legacy, at: at.addingTimeInterval(0.5))
        var other = try XCTUnwrap(record(.claude)); other["settingsPath"] = "/tmp/elsewhere/settings.json"
        try PrivateFile.writeAtomically(try JSONSerialization.data(withJSONObject: other), to: paths.connectionRecord(.claude))
        assertRefused("settings path differs")
    }

    func testUnrecordedTokenlyCommandRoundTripRestoresItExactly() throws {
        let old = StatusLineConnector.tokenlyCommand(executable: "/Old Apps/Tokenly.app/Contents/MacOS/Tokenly", source: .claude)
        let escaped = old.replacingOccurrences(of: "\"", with: "\\\"")
        let original = "{\n  \"statusLine\": { \"type\": \"command\", \"command\": \"\(escaped)\", \"padding\": 0 },\n  \"theme\": \"dark\"\n}\n"
        let url = try makeSettings(.claude, original)
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .tokenlyUnrecorded)
        _ = try connect(.claude)
        XCTAssertNil(StatusLineConnector.originalCommand(for: .claude, paths: paths))   // never wraps Tokenly itself
        let previous = try XCTUnwrap(record(.claude)?["previous"] as? [String: Any])
        XCTAssertEqual(previous["state"] as? String, "tokenlyUnrecorded")
        let installed = try XCTUnwrap(json(url)?["statusLine"] as? [String: Any])
        XCTAssertEqual(installed["command"] as? String, StatusLineConnector.tokenlyCommand(executable: executable, source: .claude))
        XCTAssertEqual(installed["padding"] as? Int, 0)
        XCTAssertEqual(StatusLineConnector.disconnectDescription(source: .claude, paths: paths), "연결 전 Tokenly statusLine 복원")
        XCTAssertTrue(try disconnectPlan(.claude).summary.contains { $0.contains("연결 기록 없음)을 복원합니다") })
        _ = try StatusLineConnector.apply(try disconnectPlan(.claude), paths: paths)
        XCTAssertEqual(try text(url), original)
    }

    func testSettingsChangedDuringDisconnectAbortsAndKeepsTheRecord() throws {
        let python = try legacyCommand(.claude)
        let url = try makeSettings(.claude, #"{"statusLine":{"type":"command","command":"\#(python)"}}"#)
        _ = try connect(.claude)
        let recordBytes = try Data(contentsOf: paths.connectionRecord(.claude))
        let plan = try disconnectPlan(.claude)
        let edited = Data(#"{"statusLine":{"type":"command","command":"echo changed meanwhile"}}"#.utf8)
        XCTAssertThrowsError(try StatusLineConnector.apply(plan, paths: paths) { try? edited.write(to: url) })
        XCTAssertEqual(try Data(contentsOf: url), edited)                         // the concurrent edit wins
        XCTAssertEqual(try Data(contentsOf: paths.connectionRecord(.claude)), recordBytes)   // record kept
    }

    func testDamagedOrContradictoryV2PreviousIsRefused() throws {
        let python = try legacyCommand(.claude)
        let url = try makeSettings(.claude, #"{"statusLine":{"type":"command","command":"\#(python)"}}"#)
        _ = try connect(.claude)
        let connected = try Data(contentsOf: url)
        let good = try XCTUnwrap(record(.claude))
        func write(previous: Any) throws {
            var r = good; r["previous"] = previous
            try PrivateFile.writeAtomically(try JSONSerialization.data(withJSONObject: r), to: paths.connectionRecord(.claude))
        }
        let native: [String: Any] = ["type": "command", "command": StatusLineConnector.tokenlyCommand(executable: executable, source: .claude)]
        let legacyValue: [String: Any] = ["type": "command", "command": python]
        let cases: [(String, Any)] = [
            ("not an object", "legacyPython"),
            ("unknown state", ["state": "somethingElse", "value": legacyValue, "text": NSNull()]),
            ("missing value key", ["state": "legacyPython", "text": NSNull()]),
            ("python state without value", ["state": "legacyPython", "value": NSNull(), "text": NSNull()]),
            ("absent state with a value", ["state": "absent", "value": legacyValue, "text": NSNull()]),
            ("user state holding a Tokenly command", ["state": "userCommand", "value": native, "text": NSNull()]),
            ("value is not an object", ["state": "userCommand", "value": "echo hi", "text": NSNull()]),
        ]
        for (label, previous) in cases {
            try write(previous: previous)
            XCTAssertThrowsError(try disconnectPlan(.claude), label)
            XCTAssertTrue(StatusLineConnector.disconnectDescription(source: .claude, paths: paths).hasPrefix("해제 불가"), label)
            XCTAssertEqual(try Data(contentsOf: url), connected, label)
        }
        // A text that does not match the value is ignored: the value itself is restored, never the text.
        try write(previous: ["state": "legacyPython", "value": legacyValue, "text": #"{"type":"command","command":"echo injected"}"#])
        _ = try StatusLineConnector.apply(try disconnectPlan(.claude), paths: paths)
        XCTAssertTrue(StatusLineConnector.jsonEqual(json(url)?["statusLine"] as Any, legacyValue))
        XCTAssertFalse(try text(url).contains("injected"))
    }

    func testVersion1BackupFolderThatIsASymlinkIsRefused() throws {
        let python = try legacyCommand(.claude)
        let legacy = #"{"statusLine":{"type":"command","command":"\#(python)"}}"#
        let at = wholeSecond
        let connected = String(data: try JSONMemberEditor.setting(member: "statusLine", to: installedNative(.claude), in: Data(legacy.utf8)), encoding: .utf8)!
        let url = try makeSettings(.claude, connected)
        try writeV1Record(.claude, connectedAt: at)
        // A valid-looking backup, but reached through a symlinked backups folder.
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: elsewhere.appendingPathComponent(
            "claude-settings-\(StatusLineConnector.backupDateFormatter().string(from: at.addingTimeInterval(0.5)))-a1b2c3.json"))
        try? FileManager.default.removeItem(at: paths.backupFolder)
        try FileManager.default.createSymbolicLink(at: paths.backupFolder, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try disconnectPlan(.claude)) { XCTAssertTrue("\($0)".contains("일반 폴더가 아닙니다"), "\($0)") }
        XCTAssertEqual(try text(url), connected)
    }

    /// Runs the executable under a pseudo-terminal (`script`) so the y/N confirmation is asked. The answer is
    /// typed after a pause and the input stays open a moment longer, so the prompt reads it before `script`
    /// forwards end-of-file.
    private func runInteractive(_ arguments: [String], answer: String) throws -> Run {
        let shell = #"(sleep 1.5; printf '%s' "$TOKENLY_TEST_ANSWER"; sleep 1.5) | /usr/bin/script -q /dev/null "$@""#
        return try run(["-c", shell, "sh", executable] + arguments,
                       extraEnvironment: ["TOKENLY_ALLOW_ANY_LOCATION": "1", "TOKENLY_TEST_ANSWER": answer],
                       terminateAfter: 20, program: "/bin/sh")
    }

    func testInteractiveConfirmationNoKeepsEverythingAndYesApplies() throws {
        let python = try legacyCommand(.claude)
        let original = #"{"statusLine":{"type":"command","command":"\#(python)"}}"#
        let url = try makeSettings(.claude, original)
        let declined = try runInteractive(["--connect", "claude"], answer: "n\n")
        XCTAssertTrue(declined.stdout.contains("계속할까요? [y/N]"), declined.stdout)
        XCTAssertTrue(declined.stdout.contains("취소했습니다"), declined.stdout)
        XCTAssertEqual(try text(url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.connectionRecord(.claude).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backupFolder.path))
        let accepted = try runInteractive(["--connect", "claude"], answer: "y\n")
        XCTAssertTrue(accepted.stdout.contains("완료."), accepted.stdout)
        XCTAssertEqual(try StatusLineConnector.state(source: .claude, paths: paths), .connected)
        let connected = try Data(contentsOf: url)
        let declinedDisconnect = try runInteractive(["--disconnect", "claude"], answer: "\n")      // Enter = No
        XCTAssertTrue(declinedDisconnect.stdout.contains("취소했습니다"), declinedDisconnect.stdout)
        XCTAssertEqual(try Data(contentsOf: url), connected)
        let disconnected = try runInteractive(["--disconnect", "claude"], answer: "yes\n")
        XCTAssertTrue(disconnected.stdout.contains("Python 브리지 명령을 복원합니다"), disconnected.stdout)
        XCTAssertEqual(try text(url), original)
    }

    func testStatusAndDisconnectDryRunExplainTheRestore() throws {
        let python = try legacyCommand(.claude)
        let original = #"{"statusLine":{"type":"command","command":"\#(python)"}}"#
        let url = try makeSettings(.claude, original)
        let env = ["TOKENLY_ALLOW_ANY_LOCATION": "1"]
        XCTAssertEqual(try run(["--connect", "claude", "--yes"], extraEnvironment: env).status, 0)
        let connected = try Data(contentsOf: url)
        let status = try run(["--status"])
        XCTAssertTrue(status.stdout.contains("상태: 연결됨"), status.stdout)
        XCTAssertTrue(status.stdout.contains("연결 해제 시: Tokenly 0.1.0 Python 브리지 명령 복원"), status.stdout)
        XCTAssertFalse(status.stdout.contains("python3"), status.stdout)                  // --status never prints commands
        let dry = try run(["--disconnect", "claude", "--dry-run"])
        XCTAssertEqual(dry.status, 0, dry.stderr)
        XCTAssertTrue(dry.stdout.contains("연결 전 Tokenly 0.1.0 Python 브리지 명령을 복원합니다"), dry.stdout)
        XCTAssertFalse(dry.stdout.contains("없었습니다"), dry.stdout)
        XCTAssertEqual(try Data(contentsOf: url), connected)
        XCTAssertEqual(try run(["--disconnect", "claude", "--yes"]).status, 0)
        XCTAssertEqual(try text(url), original)
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
