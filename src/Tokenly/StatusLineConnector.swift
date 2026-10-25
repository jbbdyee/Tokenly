import Darwin
import Foundation

/// Connects Tokenly to Claude Code / AGY status lines and undoes it. Only ever runs from an explicit
/// command the user typed (`Tokenly --connect …`), after a preview and confirmation.
///
/// Safety rules: refuse symlinks, non-regular files and invalid JSON; back up the original bytes (0600);
/// keep the user's previous `statusLine` object in a 0600 connection record; edit only the `statusLine`
/// member in place (other text untouched) and verify that every other value is unchanged; abort if the
/// file changed between reading and writing; restore automatically only what Tokenly itself installed.
enum StatusLineConnector {
    enum State: Equatable {
        case notConfigured                 // no statusLine
        case connected                     // Tokenly command recorded by this connector
        case tokenlyUnrecorded             // a native Tokenly command without a connection record
        case legacyPython                  // the 0.1.0 Python bridge command
        case otherCommand                  // the user's own status line
        case modifiedAfterConnect          // Tokenly record exists but the user changed the status line
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    struct Plan {
        let source: StatusLineSource
        let settingsURL: URL
        let fileExisted: Bool
        let originalBytes: Data
        let originalMode: mode_t
        let newBytes: Data
        let summary: [String]                 // human-readable preview lines
        let record: [String: Any]?            // connection record to write (nil: remove)
        let noChange: Bool
    }

    // MARK: Commands

    static func tokenlyCommand(executable: String, source: StatusLineSource) -> String {
        shellQuote(executable) + " --statusline " + source.rawValue
    }

    /// POSIX single-quote quoting: safe for any path, including spaces, quotes and `$`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isTokenlyNative(_ command: String) -> Bool {
        command.range(of: #"Tokenly[^\s'"]*'?\s+--statusline\s+(claude|agy)\b"#, options: .regularExpression) != nil
    }

    static func isLegacyPython(_ command: String) -> Bool {
        command.contains("ClaudeStatusLineBridge.py") || command.contains("AGYStatusLineBridge.py")
    }

    /// The user's original command recorded at connect time (nil when there was none).
    static func originalCommand(for source: StatusLineSource, paths: TokenlyPaths) -> String? {
        guard let record = readRecord(source, paths: paths),
              let original = record["original"] as? [String: Any],
              let command = original["command"] as? String, !command.isEmpty,
              !isTokenlyNative(command), !isLegacyPython(command) else { return nil }
        return command
    }

    // MARK: Status

    static func state(source: StatusLineSource, paths: TokenlyPaths) throws -> State {
        let settings = try readSettings(paths.settingsFile(source))
        return classify(settings.object?["statusLine"], record: readRecord(source, paths: paths))
    }

    static func classify(_ statusLine: Any?, record: [String: Any]?) -> State {
        guard let statusLine else { return .notConfigured }
        let command = (statusLine as? [String: Any])?["command"] as? String ?? ""
        if let installed = record?["installed"] {
            if jsonEqual(installed, statusLine) { return .connected }
            if isTokenlyNative(command) { return .modifiedAfterConnect }
        }
        if isTokenlyNative(command) { return .tokenlyUnrecorded }
        if isLegacyPython(command) { return .legacyPython }
        return record != nil ? .modifiedAfterConnect : .otherCommand
    }

    // MARK: Planning

    static func planConnect(source: StatusLineSource, paths: TokenlyPaths, executable: String,
                            now: Date = Date()) throws -> Plan {
        let url = paths.settingsFile(source)
        let settings = try readSettings(url)
        if !settings.exists {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw Failure("\(source.displayName) 설정 폴더가 없습니다(\(tilde(url.deletingLastPathComponent().path))). CLI를 설치·실행한 뒤 다시 시도하세요.")
            }
        }
        let object = settings.object ?? [:]
        let current = object["statusLine"]
        if current != nil, !(current is [String: Any]) {
            throw Failure("기존 statusLine이 객체가 아닙니다. 변경하지 않았습니다.")
        }
        let record = readRecord(source, paths: paths)
        let state = classify(current, record: record)
        let command = tokenlyCommand(executable: executable, source: source)

        var original: [String: Any]?
        var notes: [String] = []
        switch state {
        case .notConfigured:
            notes.append("현재 statusLine 없음 → Tokenly 명령을 추가합니다.")
        case .otherCommand:
            original = current as? [String: Any]
            notes.append("기존 statusLine을 보존하고, Tokenly가 먼저 한도를 저장한 뒤 기존 명령을 같은 입력으로 실행해 출력을 그대로 표시합니다.")
            if let c = original?["command"] as? String { notes.append("보존할 기존 명령: \(c)") }
        case .legacyPython:
            notes.append("Tokenly 0.1.0 Python 브리지 명령을 네이티브 명령으로 바꿉니다(Python 불필요).")
        case .connected:
            original = record?["original"] as? [String: Any]
        case .tokenlyUnrecorded:
            notes.append("연결 기록 없는 Tokenly 명령입니다. 이전 기존 명령은 알 수 없어 보존하지 않습니다(백업 폴더 확인).")
        case .modifiedAfterConnect:
            let currentCommand = (current as? [String: Any])?["command"] as? String ?? ""
            if isTokenlyNative(currentCommand) {
                original = record?["original"] as? [String: Any]       // user tweaked options only
                notes.append("연결 후 바뀐 Tokenly statusLine을 다시 맞춥니다(기존 명령 기록은 유지).")
            } else {
                original = current as? [String: Any]                   // user put their own command back
                notes.append("연결 후 사용자가 바꾼 statusLine을 새 기존 명령으로 보존합니다.")
            }
        }
        // Never wrap a command that would call Tokenly again.
        if let c = original?["command"] as? String, isTokenlyNative(c) || isLegacyPython(c) { original = nil }

        var installed: [String: Any] = [:]
        if let original { for (k, v) in original where k != "command" && k != "type" { installed[k] = v } }
        if source == .agy, installed["stack_with_default"] == nil { installed["stack_with_default"] = true }
        installed["type"] = "command"
        installed["command"] = command

        if let current, jsonEqual(current, installed), state == .connected {
            return Plan(source: source, settingsURL: url, fileExisted: settings.exists, originalBytes: settings.bytes,
                        originalMode: settings.mode, newBytes: settings.bytes, summary: ["이미 연결되어 있습니다. 변경할 내용이 없습니다."],
                        record: record, noChange: true)
        }
        let newBytes = try JSONMemberEditor.setting(member: "statusLine", to: installed, in: settings.bytes)
        try verify(newBytes, equals: object, replacing: "statusLine", with: installed)

        var newRecord: [String: Any] = [
            "version": 1, "source": source.rawValue, "settingsPath": url.path,
            "connectedAt": StatusLineReceiver.timestamp(now),
            "installed": installed, "original": original ?? NSNull()
        ]
        // Keep the exact original text too, so disconnecting restores the user's formatting byte for byte.
        if let original, let text = (original as AnyObject).isEqual(current) ? JSONMemberEditor.valueText(of: "statusLine", in: settings.bytes) : nil {
            newRecord["originalText"] = text
        } else if let text = record?["originalText"] as? String, state == .connected || state == .modifiedAfterConnect, original != nil,
                  jsonEqual(original as Any, record?["original"] as Any) {
            newRecord["originalText"] = text
        }
        var summary = ["대상: \(tilde(url.path))" + (settings.exists ? "" : " (새로 만듦, 권한 0600)")]
        summary += notes
        summary.append("새 statusLine: \(compactJSON(installed))")
        summary.append("statusLine 외의 설정 값은 바꾸지 않습니다. 변경 전 원본을 백업합니다.")
        return Plan(source: source, settingsURL: url, fileExisted: settings.exists, originalBytes: settings.bytes,
                    originalMode: settings.mode, newBytes: newBytes, summary: summary, record: newRecord, noChange: false)
    }

    static func planDisconnect(source: StatusLineSource, paths: TokenlyPaths) throws -> Plan {
        let url = paths.settingsFile(source)
        let settings = try readSettings(url)
        let object = settings.object ?? [:]
        let current = object["statusLine"]
        let record = readRecord(source, paths: paths)
        let state = classify(current, record: record)
        func unchanged(_ message: String) -> Plan {
            Plan(source: source, settingsURL: url, fileExisted: settings.exists, originalBytes: settings.bytes,
                 originalMode: settings.mode, newBytes: settings.bytes, summary: [message], record: nil, noChange: true)
        }
        switch state {
        case .notConfigured:
            return unchanged("statusLine이 없습니다. 변경할 내용이 없습니다.")
        case .otherCommand:
            throw Failure("현재 statusLine은 Tokenly 명령이 아닙니다. 사용자 설정이므로 변경하지 않았습니다.")
        case .modifiedAfterConnect:
            throw Failure("연결 후 statusLine이 바뀌었습니다. 사용자가 변경한 설정을 덮어쓰지 않기 위해 중단했습니다. 필요하면 백업(\(tilde(paths.backupFolder.path)))을 확인하세요.")
        case .connected, .legacyPython, .tokenlyUnrecorded:
            let original = state == .connected ? record?["original"] as? [String: Any] : nil
            let newBytes: Data
            var expected = object
            if let original {
                let rawText = state == .connected ? record?["originalText"] as? String : nil
                newBytes = try JSONMemberEditor.setting(member: "statusLine", to: original, in: settings.bytes, rawValue: rawText)
                expected["statusLine"] = original
            } else {
                newBytes = try JSONMemberEditor.removing(member: "statusLine", from: settings.bytes)
                expected.removeValue(forKey: "statusLine")
            }
            try verify(newBytes, equals: expected)
            var summary = ["대상: \(tilde(url.path))"]
            switch (state, original) {
            case (.connected, .some): summary.append("연결 전 statusLine을 복원합니다: \(compactJSON(original!))")
            case (.connected, .none): summary.append("연결 전에는 statusLine이 없었습니다 → statusLine을 제거합니다.")
            case (.legacyPython, _): summary.append("Tokenly 0.1.0 Python 브리지 statusLine을 제거합니다.")
            default: summary.append("연결 기록 없는 Tokenly statusLine을 제거합니다(이전 명령은 백업 폴더에서 확인).")
            }
            summary.append("statusLine 외의 설정 값은 바꾸지 않습니다. 변경 전 원본을 백업합니다.")
            return Plan(source: source, settingsURL: url, fileExisted: true, originalBytes: settings.bytes,
                        originalMode: settings.mode, newBytes: newBytes, summary: summary, record: nil, noChange: false)
        }
    }

    // MARK: Applying

    struct Result { let backup: URL?; let messages: [String] }

    /// Writes the plan. `beforeCommit` runs right before the settings file is replaced (tests use it to
    /// simulate a concurrent edit).
    static func apply(_ plan: Plan, paths: TokenlyPaths, now: Date = Date(),
                      beforeCommit: () -> Void = {}) throws -> Result {
        guard !plan.noChange else { return Result(backup: nil, messages: plan.summary) }
        try PrivateFile.ensureFolder(paths.dataFolder)
        try PrivateFile.ensureFolder(paths.backupFolder)
        try PrivateFile.ensureFolder(paths.connectionFolder)

        // 1. Back up the original bytes and verify the copy.
        var backup: URL?
        if plan.fileExisted {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let suffix = UUID().uuidString.prefix(6).lowercased()
            let url = paths.backupFolder.appendingPathComponent("\(plan.source.rawValue)-settings-\(f.string(from: now))-\(suffix).json")
            guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure("백업 파일 이름이 이미 있습니다. 잠시 후 다시 시도하세요.") }
            try PrivateFile.writeAtomically(plan.originalBytes, to: url)
            guard (try? Data(contentsOf: url)) == plan.originalBytes else { throw Failure("백업 검증에 실패했습니다. 설정은 변경하지 않았습니다.") }
            backup = url
        }

        // 2. Connection record first, so the bridge never sees a Tokenly status line without it.
        let recordURL = paths.connectionRecord(plan.source)
        let previousRecord = try? Data(contentsOf: recordURL)
        if let record = plan.record {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            try PrivateFile.writeAtomically(data, to: recordURL)
        }
        func rollbackRecord() {
            if let previousRecord { try? PrivateFile.writeAtomically(previousRecord, to: recordURL) }
            else if plan.record != nil { unlink(recordURL.path) }
        }

        // 3. Abort if the settings changed since we read them.
        beforeCommit()
        let latest = try readSettings(plan.settingsURL)
        guard latest.exists == plan.fileExisted, latest.bytes == plan.originalBytes else {
            rollbackRecord()
            throw Failure("확인 중에 설정 파일이 바뀌었습니다. 아무것도 변경하지 않았습니다. 다시 실행하세요.")
        }
        // 4. Atomic replace with the original permissions (0600 for a new file).
        do {
            try PrivateFile.writeAtomically(plan.newBytes, to: plan.settingsURL, mode: plan.fileExisted ? plan.originalMode : 0o600)
        } catch {
            rollbackRecord()
            throw Failure("설정 파일을 쓰지 못했습니다. 원본은 그대로입니다.")
        }
        guard (try? Data(contentsOf: plan.settingsURL)) == plan.newBytes else {
            throw Failure("쓰기 확인에 실패했습니다. 백업으로 복원하세요: " + restoreHint(backup, plan.settingsURL))
        }
        // 5. Disconnect: the record is no longer needed.
        if plan.record == nil { unlink(recordURL.path) }
        var messages = plan.summary
        if let backup { messages.append("백업: \(tilde(backup.path))"); messages.append("되돌리기: " + restoreHint(backup, plan.settingsURL)) }
        return Result(backup: backup, messages: messages)
    }

    static func restoreHint(_ backup: URL?, _ settings: URL) -> String {
        guard let backup else { return "rm \(shellQuote(settings.path))  (Tokenly가 새로 만든 파일)" }
        return "cp -p \(shellQuote(backup.path)) \(shellQuote(settings.path))"
    }

    // MARK: Files

    struct Settings { let exists: Bool; let bytes: Data; let mode: mode_t; let object: [String: Any]? }
    static let maxSettingsBytes = 5_000_000

    static func readSettings(_ url: URL) throws -> Settings {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure("설정 파일 상태를 읽을 수 없습니다: \(tilde(url.path))") }
            return Settings(exists: false, bytes: Data(), mode: 0o600, object: nil)
        }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw Failure("설정 파일이 심볼릭 링크입니다. 안전을 위해 변경하지 않았습니다: \(tilde(url.path))") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure("설정 파일이 일반 파일이 아닙니다: \(tilde(url.path))") }
        guard info.st_size <= maxSettingsBytes else { throw Failure("설정 파일이 너무 큽니다. 변경하지 않았습니다.") }
        guard let bytes = FileManager.default.contents(atPath: url.path) else { throw Failure("설정 파일을 읽을 수 없습니다.") }
        let trimmed = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Settings(exists: true, bytes: bytes, mode: info.st_mode & 0o7777, object: [:]) }
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw Failure("설정 파일이 올바른 JSON 객체가 아닙니다. 변경하지 않았습니다: \(tilde(url.path))")
        }
        return Settings(exists: true, bytes: bytes, mode: info.st_mode & 0o7777, object: object)
    }

    static func readRecord(_ source: StatusLineSource, paths: TokenlyPaths) -> [String: Any]? {
        let url = paths.connectionRecord(source)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = FileManager.default.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["source"] as? String == source.rawValue else { return nil }
        return object
    }

    // MARK: Helpers

    static func verify(_ bytes: Data, equals expected: [String: Any], replacing key: String? = nil, with value: Any? = nil) throws {
        var expected = expected
        if let key { expected[key] = value }
        guard let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              jsonEqual(result, expected) else {
            throw Failure("변경 결과 검증에 실패했습니다(다른 설정 값이 달라질 수 있음). 변경하지 않았습니다.")
        }
    }

    static func jsonEqual(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }

    static func compactJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Edits one member of a top-level JSON object in place, leaving every other byte as it was.
enum JSONMemberEditor {
    struct Member { let key: String; let start: Int; let valueStart: Int; let valueEnd: Int }
    struct ObjectLayout { let open: Int; let close: Int; let members: [Member] }

    static func setting(member key: String, to value: Any, in bytes: Data, rawValue: String? = nil) throws -> Data {
        let text = Array(bytes)
        var valueText = Array(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
        if let rawValue, let parsed = try? JSONSerialization.jsonObject(with: Data(rawValue.utf8), options: .fragmentsAllowed),
           (parsed as AnyObject).isEqual(value) {
            valueText = Array(rawValue.utf8)       // the user's original formatting
        }
        if text.allSatisfy({ isSpace($0) }) {
            return Data(Array("{\n  \"\(key)\": ".utf8) + valueText + Array("\n}\n".utf8))
        }
        let layout = try parse(text)
        let matches = layout.members.filter { $0.key == key }
        guard matches.count <= 1 else { throw StatusLineConnector.Failure("설정에 \(key) 키가 여러 개 있습니다. 변경하지 않았습니다.") }
        if let m = matches.first {
            return Data(text[..<m.valueStart] + valueText + text[m.valueEnd...])
        }
        let indent = indentation(of: layout, in: text)
        let keyText = Array("\"\(key)\": ".utf8)
        if let last = layout.members.last {
            return Data(text[..<last.valueEnd] + Array(",\n".utf8) + indent + keyText + valueText + text[last.valueEnd...])
        }
        // Empty object: keep what is outside the braces.
        return Data(text[...layout.open] + Array("\n".utf8) + indent + keyText + valueText + Array("\n".utf8) + text[layout.close...])
    }

    /// Exact source text of a top-level member's value (nil if absent or not unique).
    static func valueText(of key: String, in bytes: Data) -> String? {
        let text = Array(bytes)
        guard let layout = try? parse(text) else { return nil }
        let matches = layout.members.filter { $0.key == key }
        guard matches.count == 1, let m = matches.first else { return nil }
        return String(decoding: text[m.valueStart..<m.valueEnd], as: UTF8.self)
    }

    static func removing(member key: String, from bytes: Data) throws -> Data {
        let text = Array(bytes)
        let layout = try parse(text)
        let indices = layout.members.indices.filter { layout.members[$0].key == key }
        guard indices.count == 1, let i = indices.first else {
            if indices.isEmpty { return bytes }
            throw StatusLineConnector.Failure("설정에 \(key) 키가 여러 개 있습니다. 변경하지 않았습니다.")
        }
        let members = layout.members
        if i + 1 < members.count {                       // remove "key": value, …up to the next key
            return Data(text[..<members[i].start] + text[members[i + 1].start...])
        }
        if i > 0 {                                       // last member: drop the comma after the previous value
            return Data(text[..<members[i - 1].valueEnd] + text[members[i].valueEnd...])
        }
        return Data(text[...layout.open] + text[layout.close...])   // only member: leave an empty object
    }

    // Minimal JSON scanner for the top-level object (strings with escapes, nesting, literals).
    static func parse(_ t: [UInt8]) throws -> ObjectLayout {
        var i = 0
        func fail() -> StatusLineConnector.Failure { .init("설정 JSON 구조를 해석할 수 없습니다. 변경하지 않았습니다.") }
        func skip() { while i < t.count, isSpace(t[i]) { i += 1 } }
        func string() throws -> String {
            guard i < t.count, t[i] == 0x22 else { throw fail() }
            let start = i; i += 1
            while i < t.count {
                if t[i] == 0x5C { i += 2; continue }
                if t[i] == 0x22 { i += 1; return (try? JSONSerialization.jsonObject(with: Data(t[start..<i]), options: .fragmentsAllowed) as? String) ?? "" }
                i += 1
            }
            throw fail()
        }
        func value() throws {
            guard i < t.count else { throw fail() }
            switch t[i] {
            case 0x22: _ = try string()
            case 0x7B, 0x5B:
                var depth = 0
                while i < t.count {
                    switch t[i] {
                    case 0x22: _ = try string(); continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1; if depth == 0 { i += 1; return }
                    default: break
                    }
                    i += 1
                }
                throw fail()
            default:
                while i < t.count, !isSpace(t[i]), t[i] != 0x2C, t[i] != 0x7D, t[i] != 0x5D { i += 1 }
            }
        }
        skip()
        guard i < t.count, t[i] == 0x7B else { throw fail() }
        let open = i; i += 1
        var members: [Member] = []
        skip()
        if i < t.count, t[i] == 0x7D { return ObjectLayout(open: open, close: i, members: []) }
        while true {
            skip()
            let start = i
            let key = try string()
            skip(); guard i < t.count, t[i] == 0x3A else { throw fail() }; i += 1; skip()
            let valueStart = i
            try value()
            members.append(Member(key: key, start: start, valueStart: valueStart, valueEnd: i))
            skip()
            guard i < t.count else { throw fail() }
            if t[i] == 0x2C { i += 1; continue }
            if t[i] == 0x7D { return ObjectLayout(open: open, close: i, members: members) }
            throw fail()
        }
    }

    static func indentation(of layout: ObjectLayout, in t: [UInt8]) -> [UInt8] {
        guard let first = layout.members.first else { return Array("  ".utf8) }
        var j = first.start
        while j > 0, t[j - 1] == 0x20 || t[j - 1] == 0x09 { j -= 1 }
        return j > 0 && t[j - 1] == 0x0A ? Array(t[j..<first.start]) : Array("  ".utf8)
    }

    static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
}
