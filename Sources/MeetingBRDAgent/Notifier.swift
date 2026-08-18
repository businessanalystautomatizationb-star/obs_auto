import Foundation

/// Posts native macOS notifications via `terminal-notifier` (`brew install terminal-notifier`).
/// UNUserNotificationCenter needs a proper .app bundle with a registered bundle identifier
/// to work — this is a bare executable, so it can't use that API directly.
/// `osascript -e 'display notification ...'` was tried first but silently never registered
/// a notification source on this machine (confirmed empty in System Settings → Notifications) —
/// terminal-notifier ships its own tiny .app bundle, which macOS does register reliably.
enum Notifier {
    private static let binaryPath = "/usr/local/bin/terminal-notifier"

    static func send(_ title: String, _ message: String) {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            print("DIAG Notifier: \(binaryPath) not executable/found")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-title", title, "-message", message]
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            print("DIAG Notifier: exit=\(process.terminationStatus) stderr=\"\(errText)\"")
        } catch {
            print("DIAG Notifier: run() threw \(error)")
        }
    }
}
