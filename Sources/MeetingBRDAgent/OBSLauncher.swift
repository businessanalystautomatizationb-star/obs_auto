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

    /// Graceful quit (not a kill) — by the time this is called, OBS has already finished
    /// writing and closing the recording file (RecordStateChanged/outputActive:false already
    /// fired), and nothing later in the pipeline (ffmpeg/Deepgram/Claude) needs OBS running.
    /// It relaunches on its own next time a meeting is detected.
    static func quit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "quit app \"OBS\""]
        try? process.run()
    }
}
