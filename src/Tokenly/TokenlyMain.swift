import Foundation

/// Process entry point. Command-line modes (`--statusline`, `--status`, `--connect`, `--disconnect`)
/// run and exit before any SwiftUI/AppKit object is created; every other launch (Finder, Dock, login
/// item, `open`) starts the menu bar app exactly as before.
@main
enum TokenlyMain {
    static func main() {
        if let status = BridgeCommand.runIfRequested(arguments: CommandLine.arguments) {
            exit(status)
        }
        TokenlyApp.main()
    }
}
