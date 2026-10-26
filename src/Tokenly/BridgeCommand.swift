import Darwin
import Foundation

/// Command-line modes of the Tokenly executable. Anything else (including no arguments or the
/// `-NS…`/`-Apple…` arguments macOS adds) starts the menu bar app.
///
///   Tokenly --statusline claude|agy                  status-line bridge (run by Claude Code / AGY)
///   Tokenly --status                                 show connection state (changes nothing)
///   Tokenly --connect claude|agy [--dry-run|--yes]   connect after a preview and confirmation
///   Tokenly --disconnect claude|agy [--dry-run|--yes] restore what Tokenly changed
enum BridgeCommand {
    static func runIfRequested(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32? {
        guard arguments.count >= 2 else { return nil }
        let rest = Array(arguments.dropFirst(2))
        switch arguments[1] {
        case "--statusline":
            signal(SIGPIPE, SIG_IGN)        // a reader that goes away must not kill us
            ChildCommand.installCancellationHandlers()
            guard rest.count == 1, let source = StatusLineSource(rawValue: rest[0]) else { return usage() }
            if isatty(STDIN_FILENO) == 1 { return usage() }   // status lines always pipe JSON
            let input = StatusLineReceiver.readInput(from: .standardInput)
            let outcome = StatusLineBridge.run(source: source, input: input, paths: .current(environment: environment),
                                               environment: environment)
            FileHandle.standardOutput.write(outcome.output)
            return outcome.status
        case "--status":
            return status(paths: .current(environment: environment))
        case "--connect", "--disconnect":
            signal(SIGPIPE, SIG_IGN)
            let flags = Set(rest.dropFirst())
            guard let target = rest.first, let source = StatusLineSource(rawValue: target),
                  flags.isSubset(of: ["--dry-run", "--yes"]), !(flags.contains("--dry-run") && flags.contains("--yes")) else {
                return usage()
            }
            return change(connect: arguments[1] == "--connect", source: source, dryRun: flags.contains("--dry-run"),
                          assumeYes: flags.contains("--yes"), environment: environment)
        case "--help", "-h":
            return usage(status: 0)
        default:
            return nil
        }
    }

    // MARK: --status

    static func status(paths: TokenlyPaths) -> Int32 {
        print("Tokenly 실행 파일: \(executablePath())")
        for source in StatusLineSource.allCases {
            print("\n[\(source.displayName)]")
            print("  설정 파일: \(StatusLineConnector.tilde(paths.settingsFile(source).path))")
            let text: String
            do {
                switch try StatusLineConnector.state(source: source, paths: paths) {
                case .notConfigured: text = "연결 안 됨 (statusLine 없음)"
                case .connected:
                    let wrapped = StatusLineConnector.originalCommand(for: source, paths: paths) != nil
                    text = "연결됨" + (wrapped ? " · 기존 statusLine 출력 유지" : "")
                case .tokenlyUnrecorded: text = "Tokenly 명령이 있으나 연결 기록 없음"
                case .legacyPython: text = "Tokenly 0.1.0 Python 브리지(--connect로 네이티브 전환 가능)"
                case .otherCommand: text = "다른 statusLine 사용 중 (Tokenly 연결 안 됨)"
                case .modifiedAfterConnect: text = "연결 후 statusLine이 바뀜 (자동 해제 불가)"
                }
            } catch {
                text = "확인 불가 · \(error)"
            }
            print("  상태: \(text)")
            if (try? StatusLineConnector.state(source: source, paths: paths)) == .connected {
                print("  연결 해제 시: \(StatusLineConnector.disconnectDescription(source: source, paths: paths))")
            }
            let quota = paths.quotaFile(source)
            if let data = FileManager.default.contents(atPath: quota.path),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let captured = object["captured_at"] as? String {
                print("  마지막 수신: \(captured)")
            } else {
                print("  마지막 수신: 없음")
            }
        }
        return 0
    }

    // MARK: --connect / --disconnect

    static func change(connect: Bool, source: StatusLineSource, dryRun: Bool, assumeYes: Bool,
                       environment: [String: String]) -> Int32 {
        let paths = TokenlyPaths.current(environment: environment)
        let executable = environment["TOKENLY_EXECUTABLE"] ?? executablePath()
        if connect, !dryRun, environment["TOKENLY_ALLOW_ANY_LOCATION"] == nil,
           !LoginItemManager.isStableInstallLocation(bundleURL(of: executable), home: paths.home) {
            printError("연결은 /Applications 또는 ~/Applications에 설치한 Tokenly에서 실행하세요. 현재: \(executable)")
            return 2
        }
        let plan: StatusLineConnector.Plan
        do {
            plan = connect ? try StatusLineConnector.planConnect(source: source, paths: paths, executable: executable)
                           : try StatusLineConnector.planDisconnect(source: source, paths: paths)
        } catch {
            printError("중단: \(error)")
            return 3
        }
        print("[\(source.displayName) \(connect ? "연결" : "연결 해제")\(dryRun ? " · 미리보기" : "")]")
        plan.summary.forEach { print("  " + $0) }
        if plan.noChange || dryRun { return 0 }
        if !assumeYes {
            guard isatty(STDIN_FILENO) == 1 else {
                printError("확인이 필요합니다. 터미널에서 실행하거나, 내용을 확인한 뒤 --yes를 붙이세요.")
                return 4
            }
            print("계속할까요? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), answer == "y" || answer == "yes" else {
                print("취소했습니다. 아무것도 변경하지 않았습니다.")
                return 0
            }
        }
        do {
            let result = try StatusLineConnector.apply(plan, paths: paths)
            print("완료.")
            result.messages.suffix(2).forEach { print("  " + $0) }
            if connect { print("  \(source == .claude ? "Claude Code" : "AGY CLI")의 다음 상태줄 갱신부터 적용됩니다.") }
            return 0
        } catch {
            printError("실패: \(error)")
            printError("원본 백업은 \(StatusLineConnector.tilde(paths.backupFolder.path))에 있습니다.")
            return 5
        }
    }

    // MARK: Helpers

    static func executablePath() -> String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    static func bundleURL(of executable: String) -> URL {
        // …/Tokenly.app/Contents/MacOS/Tokenly → …/Tokenly.app
        URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    @discardableResult
    static func usage(status: Int32 = 64) -> Int32 {
        let text = """
        사용법:
          Tokenly --status
          Tokenly --connect claude|agy [--dry-run | --yes]
          Tokenly --disconnect claude|agy [--dry-run | --yes]
          Tokenly --statusline claude|agy   (Claude Code·AGY가 표준입력으로 호출)

        """
        (status == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data(text.utf8))
        return status
    }
}
