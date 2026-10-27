import AppKit

/// Loud, hard-to-miss warning for "the recording is broken right now" situations:
/// a sound played several times plus a window above everything (including a
/// full-screen Zoom) — an ordinary notification banner is too easy to miss mid-call.
enum Alarm {
    private static var panel: NSPanel?
    private static let closer = Closer()

    static func show(_ title: String, _ message: String) {
        DispatchQueue.main.async {
            Notifier.send("⚠️ \(title)", message)
            playSound(times: 3)
            closer.action = nil
            showPanel("⚠️ \(title)", message)
        }
    }

    /// Quiet variant: same always-on-top panel, no sound, plus an action button
    /// (e.g. "Разобрать в Project Hub" once a meeting has been processed).
    static func offer(_ title: String, _ message: String, actionTitle: String, action: @escaping () -> Void) {
        DispatchQueue.main.async {
            Notifier.send(title, message)
            closer.action = action
            showPanel(title, message, actionTitle: actionTitle)
        }
    }

    static func dismiss() {
        DispatchQueue.main.async {
            panel?.orderOut(nil)
        }
    }

    private static func playSound(times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) {
                // A fresh instance each time — NSSound won't replay one that's still playing.
                (NSSound(named: "Sosumi")?.copy() as? NSSound)?.play()
            }
        }
    }

    private static func showPanel(_ title: String, _ message: String, actionTitle: String? = nil) {
        panel?.orderOut(nil)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.textColor = actionTitle == nil ? .systemRed : .labelColor

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.preferredMaxLayoutWidth = 420

        let button = NSButton(title: actionTitle == nil ? "Понятно" : "Позже", target: closer, action: #selector(Closer.close))
        var buttons = [button]
        if let actionTitle {
            let actionButton = NSButton(title: actionTitle, target: closer, action: #selector(Closer.runAction))
            actionButton.keyEquivalent = "\r"
            buttons.insert(actionButton, at: 0)
        } else {
            button.keyEquivalent = "\r"
        }

        let stack = NSStackView(views: [titleLabel, messageLabel, NSStackView(views: buttons)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "MeetingBRDAgent"
        newPanel.contentView = stack
        newPanel.isReleasedWhenClosed = false
        // Above full-screen apps and on every Space, so it shows up wherever the call is.
        newPanel.level = .screenSaver
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.setContentSize(stack.fittingSize)
        newPanel.center()
        newPanel.orderFrontRegardless()
        panel = newPanel
    }

    private final class Closer: NSObject {
        var action: (() -> Void)?
        @objc func close() { Alarm.dismiss() }
        @objc func runAction() {
            Alarm.dismiss()
            action?()
        }
    }
}
