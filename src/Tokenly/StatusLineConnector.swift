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
        var referencesBackup = false          // store the backup taken by `apply` as the record's `backupFile`
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

    // MARK: Previous status line (what disconnecting restores)

    /// The status line as it was right before Tokenly connected. Connection records from version 2 on
    /// store it as `previous`; `original` only means "the user's command the bridge runs and passes through".
    struct Previous {
        enum Kind: String { case absent, legacyPython, userCommand, tokenlyUnrecorded }
        enum Origin: Equatable { case record, legacyRecord, backup(URL) }
        let kind: Kind
        let value: [String: Any]?            // nil only for .absent
        let text: String?                    // exact source text of the value, when known
        let origin: Origin

        var recordValue: [String: Any] {
            ["state": kind.rawValue, "value": value ?? NSNull(), "text": text ?? NSNull()]
        }
    }

    static func previousKind(of statusLine: [String: Any]?) -> Previous.Kind {
        guard let statusLine else { return .absent }
        let command = statusLine["command"] as? String ?? ""
        if isTokenlyNative(command) { return .tokenlyUnrecorded }
        if isLegacyPython(command) { return .legacyPython }
        return .userCommand
    }

    /// A native Tokenly command for this source (`… --statusline claude` for Claude).
    static func isTokenlyNative(_ command: String, source: StatusLineSource) -> Bool {
        command.range(of: #"Tokenly[^\s'"]*'?\s+--statusline\s+"# + source.rawValue + #"(\s|$)"#, options: .regularExpression) != nil
    }

    /// The bridge script of the exact command Tokenly 0.1.0 wrote for this source, or nil.
    static func legacyBridgePath(in command: String, source: StatusLineSource) -> String? {
        let name = source == .claude ? "ClaudeStatusLineBridge" : "AGYStatusLineBridge"
        let pattern = #"^/usr/bin/python3 '([^']+/Contents/Resources/"# + name + #"\.py)'$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[range])
    }

    /// Any `…StatusLineBridge.py` path named in a command (quoted or not), for the restore check.
    static func bridgeScriptPath(in command: String) -> String? {
        for pattern in [#"'([^']*StatusLineBridge\.py)'"#, #"(\S*StatusLineBridge\.py)"#] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
               let range = Range(match.range(at: 1), in: command) { return String(command[range]) }
        }
        return nil
    }

    /// What disconnecting must restore, from the record (v2), the v1 `original`, or — for v1 records
    /// without one — the backup taken at connect time. Throws when this cannot be determined safely.
    static func restoreTarget(record: [String: Any], source: StatusLineSource, paths: TokenlyPaths) throws -> Previous {
        if let stored = record["previous"] {
            guard let stored = stored as? [String: Any], let raw = stored["state"] as? String,
                  let kind = Previous.Kind(rawValue: raw) else {
                throw Failure("연결 기록의 복원 정보를 읽을 수 없습니다. 아무것도 변경하지 않았습니다.")
            }
            let value = stored["value"] as? [String: Any]
            guard (value == nil) == (stored["value"] is NSNull), previousKind(of: value) == kind else {
                throw Failure("연결 기록의 복원 정보가 올바르지 않습니다. 아무것도 변경하지 않았습니다.")
            }
            return Previous(kind: kind, value: value, text: stored["text"] as? String, origin: .record)
        }
        if let original = record["original"] as? [String: Any] {          // v1 with a wrapped user command
            return Previous(kind: previousKind(of: original), value: original, text: record["originalText"] as? String,
                            origin: .legacyRecord)
        }
        return try previousFromBackup(record: record, source: source, paths: paths)
    }

    /// v1 records saved `original: null` for "no status line", the 0.1.0 Python bridge and unrecorded Tokenly
    /// commands alike. The connector's own backup from that connect tells them apart. Every check must
    /// pass and exactly one backup must match; otherwise nothing is guessed.
    static let legacyBackupWindow: TimeInterval = 900

    static func previousFromBackup(record: [String: Any], source: StatusLineSource, paths: TokenlyPaths) throws -> Previous {
        func refuse(_ reason: String) -> Failure {
            Failure("연결 전 statusLine을 확인할 수 없어 중단했습니다. 아무것도 변경하지 않았습니다. 이유: \(reason). "
                    + "이전 형식의 연결 기록이라 복원 정보가 없습니다. 원본은 백업 폴더(\(tilde(paths.backupFolder.path)))에서 확인하세요.")
        }
        guard record["source"] as? String == source.rawValue,
              record["settingsPath"] as? String == paths.settingsFile(source).path else {
            throw refuse("연결 기록의 대상·설정 경로가 현재와 다릅니다")
        }
        guard let connectedText = record["connectedAt"] as? String,
              let connectedAt = ISO8601DateFormatter().date(from: connectedText) else { throw refuse("연결 시각을 읽을 수 없습니다") }
        let folder = paths.backupFolder
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw refuse("백업 폴더가 없거나 일반 폴더가 아닙니다")
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let candidates = names.filter { name in
            guard let date = backupDate(of: name, source: source) else { return false }
            let delta = date.timeIntervalSince(connectedAt)
            return delta >= 0 && delta < legacyBackupWindow
        }
        guard candidates.count == 1, let name = candidates.first else {
            throw refuse(candidates.isEmpty ? "연결 시각에 만든 백업이 없습니다" : "연결 시각에 맞는 백업이 \(candidates.count)개라 하나로 정할 수 없습니다")
        }
        let url = folder.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == folder.resolvingSymlinksInPath().path else {
            throw refuse("백업 파일이 백업 폴더 밖에 있습니다")
        }
        let backup: Settings
        do { backup = try readSettings(url) } catch { throw refuse("백업 파일을 안전하게 읽을 수 없습니다") }
        guard backup.exists, let object = (try? JSONSerialization.jsonObject(with: backup.bytes)) as? [String: Any] else {
            throw refuse("백업 파일이 올바른 JSON 객체가 아닙니다")
        }
        guard let layout = try? JSONMemberEditor.parse(Array(backup.bytes)),
              layout.members.filter({ $0.key == "statusLine" }).count <= 1 else {
            throw refuse("백업의 JSON 구조가 올바르지 않습니다")
        }
        let raw = object["statusLine"]
        if raw != nil, !(raw is [String: Any]) { throw refuse("백업의 statusLine이 객체가 아닙니다") }
        let value = raw as? [String: Any]
        let command = value?["command"] as? String ?? ""
        let kind = previousKind(of: value)
        switch kind {
        case .absent:
            break
        case .legacyPython:
            guard value?["type"] as? String == "command", legacyBridgePath(in: command, source: source) != nil else {
                throw refuse("백업의 Python 브리지 명령이 Tokenly 0.1.0 형식과 다릅니다")
            }
        case .tokenlyUnrecorded:
            guard value?["type"] as? String == "command", isTokenlyNative(command, source: source) else {
                throw refuse("백업의 Tokenly 명령이 이 대상의 명령이 아닙니다")
            }
        case .userCommand:
            throw refuse("백업에는 사용자 명령이 있지만 연결 기록에는 없습니다")
        }
        if let value, let installed = record["installed"], jsonEqual(value, installed) {
            throw refuse("백업이 연결 후 상태와 같습니다")
        }
        let text = value == nil ? nil : JSONMemberEditor.valueText(of: "statusLine", in: backup.bytes)
        return Previous(kind: kind, value: value, text: text, origin: .backup(url))
    }

    /// Restoring a Python bridge command whose script no longer exists would leave a broken status line.
    static func checkRestorable(_ previous: Previous) throws {
        guard previous.kind == .legacyPython, let path = bridgeScriptPath(in: previous.value?["command"] as? String ?? "") else { return }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure("연결 전 Python 브리지 파일이 없어 복원하지 않았습니다(\(tilde(path))). 아무것도 변경하지 않았습니다.")
        }
    }

    /// One line for `--status`: what disconnecting would do. Never prints commands.
    static func disconnectDescription(source: StatusLineSource, paths: TokenlyPaths) -> String {
        guard let record = readRecord(source, paths: paths) else { return "확인 불가 (연결 기록 없음)" }
        do {
            let previous = try restoreTarget(record: record, source: source, paths: paths)
            try checkRestorable(previous)
            let text: String
            switch previous.kind {
            case .absent: text = "statusLine 제거 (연결 전 없음)"
            case .legacyPython: text = "Tokenly 0.1.0 Python 브리지 명령 복원"
            case .userCommand: text = "연결 전 statusLine 복원"
            case .tokenlyUnrecorded: text = "연결 전 Tokenly statusLine 복원"
            }
            if case .backup = previous.origin { return text + " (연결 때 만든 백업에서 확인)" }
            return text
        } catch {
            return "해제 불가 · \(error)"
        }
    }

    static func backupDateFormatter() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }

    /// Time stamp of a connector backup named `<source>-settings-yyyyMMdd-HHmmss-SSS-xxxxxx.json`.
    static func backupDate(of name: String, source: StatusLineSource) -> Date? {
        let pattern = "^" + source.rawValue + #"-settings-(\d{8}-\d{6}-\d{3})-[0-9a-f]{6}\.json$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return nil }
        return backupDateFormatter().date(from: String(name[range]))
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
        let currentObject = current as? [String: Any]
        let currentPrevious = Previous(kind: previousKind(of: currentObject), value: currentObject,
                                       text: currentObject == nil ? nil : JSONMemberEditor.valueText(of: "statusLine", in: settings.bytes),
                                       origin: .record)

        var original: [String: Any]?
        var previous: Previous?
        var reconnect = false            // keep the first connect's previous, time and backup
        var notes: [String] = []
        switch state {
        case .notConfigured:
            previous = currentPrevious
            notes.append("현재 statusLine 없음 → Tokenly 명령을 추가합니다. 연결 해제 시 statusLine을 제거합니다.")
        case .otherCommand:
            original = currentObject
            previous = currentPrevious
            notes.append("기존 statusLine을 보존하고, Tokenly가 먼저 한도를 저장한 뒤 기존 명령을 같은 입력으로 실행해 출력을 그대로 표시합니다.")
            if let c = original?["command"] as? String { notes.append("보존할 기존 명령: \(c)") }
        case .legacyPython:
            previous = currentPrevious
            notes.append("Tokenly 0.1.0 Python 브리지 명령을 네이티브 명령으로 바꿉니다(Python 불필요). 연결 해제 시 지금의 Python 명령을 복원합니다.")
        case .connected:
            original = record?["original"] as? [String: Any]
            previous = record.flatMap { try? restoreTarget(record: $0, source: source, paths: paths) }
            reconnect = true
        case .tokenlyUnrecorded:
            previous = currentPrevious
            notes.append("연결 기록 없는 Tokenly 명령입니다. 감싸지 않으며, 연결 해제 시 지금 값을 복원합니다.")
        case .modifiedAfterConnect:
            let currentCommand = currentObject?["command"] as? String ?? ""
            if isTokenlyNative(currentCommand) {
                original = record?["original"] as? [String: Any]       // user tweaked options only
                previous = record.flatMap { try? restoreTarget(record: $0, source: source, paths: paths) }
                reconnect = true
                notes.append("연결 후 바뀐 Tokenly statusLine을 다시 맞춥니다(연결 전 상태 기록은 유지).")
            } else {
                original = currentObject                               // user put their own command back
                previous = currentPrevious
                notes.append("연결 후 사용자가 바꾼 statusLine을 새 기존 명령으로 보존합니다.")
            }
        }
        // Never wrap a command that would call Tokenly again.
        if let c = original?["command"] as? String, isTokenlyNative(c) || isLegacyPython(c) { original = nil }

        // Re-connecting keeps the installed options; otherwise carry the previous options over
        // (e.g. `padding`, AGY's `stack_with_default`) — from the wrapped command or the replaced status line.
        var installed: [String: Any] = [:]
        if reconnect, let old = record?["installed"] as? [String: Any] {
            installed = old
        } else if let options = original ?? previous?.value {
            for (k, v) in options where k != "command" && k != "type" { installed[k] = v }
        }
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
            "version": 2, "source": source.rawValue, "settingsPath": url.path,
            "connectedAt": StatusLineReceiver.timestamp(now),
            "installed": installed, "original": original ?? NSNull()
        ]
        if reconnect, let record {
            newRecord["connectedAt"] = record["connectedAt"] ?? newRecord["connectedAt"]   // v1 backups are matched by this time
            newRecord["updatedAt"] = StatusLineReceiver.timestamp(now)
            if let backupFile = record["backupFile"] { newRecord["backupFile"] = backupFile }
            if let text = record["originalText"] { newRecord["originalText"] = text }
        }
        if let previous { newRecord["previous"] = previous.recordValue }   // unresolved v1: left out, resolved again on disconnect
        var summary = ["대상: \(tilde(url.path))" + (settings.exists ? "" : " (새로 만듦, 권한 0600)")]
        summary += notes
        summary.append("새 statusLine: \(compactJSON(installed))")
        summary.append("statusLine 외의 설정 값은 바꾸지 않습니다. 변경 전 원본을 백업합니다.")
        return Plan(source: source, settingsURL: url, fileExisted: settings.exists, originalBytes: settings.bytes,
                    originalMode: settings.mode, newBytes: newBytes, summary: summary, record: newRecord, noChange: false,
                    referencesBackup: !reconnect)
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
        var summary = ["대상: \(tilde(url.path))"]
        var expected = object
        let newBytes: Data
        switch state {
        case .notConfigured:
            return unchanged("statusLine이 없습니다. 변경할 내용이 없습니다.")
        case .otherCommand:
            throw Failure("현재 statusLine은 Tokenly 명령이 아닙니다. 사용자 설정이므로 변경하지 않았습니다.")
        case .modifiedAfterConnect:
            throw Failure("연결 후 statusLine이 바뀌었습니다. 사용자가 변경한 설정을 덮어쓰지 않기 위해 중단했습니다. 필요하면 백업(\(tilde(paths.backupFolder.path)))을 확인하세요.")
        case .connected:
            guard let record else { throw Failure("연결 기록을 읽을 수 없습니다. 아무것도 변경하지 않았습니다.") }
            let previous = try restoreTarget(record: record, source: source, paths: paths)
            try checkRestorable(previous)
            if let value = previous.value {
                newBytes = try JSONMemberEditor.setting(member: "statusLine", to: value, in: settings.bytes, rawValue: previous.text)
                expected["statusLine"] = value
            } else {
                newBytes = try JSONMemberEditor.removing(member: "statusLine", from: settings.bytes)
                expected.removeValue(forKey: "statusLine")
            }
            switch previous.kind {
            case .absent: summary.append("연결 전에는 statusLine이 없었습니다 → statusLine을 제거합니다.")
            case .legacyPython: summary.append("연결 전 Tokenly 0.1.0 Python 브리지 명령을 복원합니다: \(previous.value?["command"] as? String ?? "")")
            case .userCommand: summary.append("연결 전 statusLine을 복원합니다: \(compactJSON(previous.value ?? [:]))")
            case .tokenlyUnrecorded: summary.append("연결 전 Tokenly statusLine(연결 기록 없음)을 복원합니다: \(compactJSON(previous.value ?? [:]))")
            }
            if case .backup(let backup) = previous.origin {
                summary.append("연결 기록이 이전 형식이라, 연결할 때 만든 백업에서 연결 전 상태를 확인했습니다: \(tilde(backup.path))")
            }
        case .legacyPython, .tokenlyUnrecorded:
            newBytes = try JSONMemberEditor.removing(member: "statusLine", from: settings.bytes)
            expected.removeValue(forKey: "statusLine")
            summary.append(state == .legacyPython ? "Tokenly 0.1.0 Python 브리지 statusLine을 제거합니다."
                                                  : "연결 기록 없는 Tokenly statusLine을 제거합니다(이전 명령은 백업 폴더에서 확인).")
        }
        try verify(newBytes, equals: expected)
        summary.append("statusLine 외의 설정 값은 바꾸지 않습니다. 변경 전 원본을 백업합니다.")
        return Plan(source: source, settingsURL: url, fileExisted: true, originalBytes: settings.bytes,
                    originalMode: settings.mode, newBytes: newBytes, summary: summary, record: nil, noChange: false)
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
            let f = backupDateFormatter()
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
        if var record = plan.record {
            if plan.referencesBackup { record["backupFile"] = backup?.path ?? NSNull() }
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

    /// Value equality of two parsed JSON values. Key order and formatting never matter. Types do:
    /// `true` ≠ `1`, `"1"` ≠ `1`, `null` ≠ a missing key. Numbers compare by value, so `1` == `1.0` —
    /// JSON has a single number type and Claude Code (JavaScript) and AGY (Go) read both identically.
    /// (`NSObject.isEqual` alone would also treat `true` as `1`, which could hide a user's edit.)
    static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull):
            return true
        case let (x as String, y as String):
            return x == y
        case let (x as NSNumber, y as NSNumber):
            let xBool = CFGetTypeID(x) == CFBooleanGetTypeID(), yBool = CFGetTypeID(y) == CFBooleanGetTypeID()
            guard xBool == yBool else { return false }
            return xBool ? x.boolValue == y.boolValue : x.compare(y) == .orderedSame
        case let (x as [Any], y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { jsonEqual($0, $1) }
        case let (x as [String: Any], y as [String: Any]):
            return x.count == y.count && x.allSatisfy { key, value in y[key].map { jsonEqual(value, $0) } ?? false }
        default:
            return false
        }
    }

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
           StatusLineConnector.jsonEqual(parsed, value) {
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
