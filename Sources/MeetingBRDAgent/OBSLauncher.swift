import Foundation

/// Launches OBS in the background (no window activation/focus-steal) if it isn't
/// already running. `open -j` = launch hidden; idempotent if OBS is already open.
enum OBSLauncher {
    static func launchIfNeeded() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-j", "-a", "OBS"]
        try? process.run()
    }
}
