import AppKit
import CoreGraphics

/// Detects an in-progress call two ways:
///  - exact window-title patterns Zoom/Teams use, for automatic recording start
///  - "does any Zoom/Teams-owned window still exist at all" (no title match required),
///    used only as a safety net to auto-stop a recording — regardless of whether it was
///    started automatically or manually — once the call app has genuinely closed.
/// The title match proved unreliable for at least one Zoom build/locale (title text
/// doesn't say "Zoom Meeting"), so the stop path intentionally does not depend on it.
///
/// Requires Screen Recording permission (System Settings -> Privacy & Security ->
/// Screen Recording) for this process, otherwise window titles come back empty.
final class WindowWatcher {
    private let pollInterval: TimeInterval = 4
    private let missesBeforeEnd = 3 // ~12s debounce so a brief UI flicker doesn't stop the recording

    private let meetingTitlePatterns: [String] = [
        "Zoom Meeting",
        "Zoom Webinar",
        "Meeting | Microsoft Teams",
        // Russian-localized Zoom client (confirmed: "Конференция Zoom").
        "Конференция Zoom",
        "Zoom - вебинар",
        // Best-guess Russian Teams equivalent — confirm/adjust if it doesn't match.
        "Собрание | Microsoft Teams"
    ]
    private let callAppOwnerHints: [String] = ["zoom", "teams"]

    var onMeetingDetected: (() -> Void)?
    var onMeetingEnded: (() -> Void)?
    /// Fires once a previously-open Zoom/Teams window has been gone for the debounce
    /// period. Independent of the title-pattern match — safety net for manual recordings.
    var onCallAppWindowGone: (() -> Void)?

    private var timer: Timer?
    private var inMeeting = false
    private var consecutiveMisses = 0

    private var callAppWindowPresent = false
    private var callAppConsecutiveMisses = 0

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let (meetingTitleFound, anyCallWindow) = scanWindows()

        if meetingTitleFound {
            consecutiveMisses = 0
            if !inMeeting {
                inMeeting = true
                onMeetingDetected?()
            }
        } else if inMeeting {
            consecutiveMisses += 1
            if consecutiveMisses >= missesBeforeEnd {
                inMeeting = false
                consecutiveMisses = 0
                onMeetingEnded?()
            }
        }

        if anyCallWindow {
            callAppConsecutiveMisses = 0
            callAppWindowPresent = true
        } else if callAppWindowPresent {
            callAppConsecutiveMisses += 1
            if callAppConsecutiveMisses >= missesBeforeEnd {
                callAppWindowPresent = false
                callAppConsecutiveMisses = 0
                onCallAppWindowGone?()
            }
        }
    }

    private func scanWindows() -> (meetingTitleFound: Bool, anyCallWindow: Bool) {
        // .optionAll (not .optionOnScreenOnly) — a call window must still count while the
        // user has switched Spaces or apps away from it, not just while it's frontmost.
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return (false, false)
        }
        var titleFound = false
        var anyCallWindow = false
        for window in list {
            let owner = ((window[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            if callAppOwnerHints.contains(where: { owner.contains($0) }) {
                anyCallWindow = true
            }
            guard let title = window[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            if meetingTitlePatterns.contains(where: { title.contains($0) }) {
                titleFound = true
            }
        }
        return (titleFound, anyCallWindow)
    }
}
