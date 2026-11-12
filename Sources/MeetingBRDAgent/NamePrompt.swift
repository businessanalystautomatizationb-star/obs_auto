import AppKit

/// The protocol name the user picks while the pipeline is already running. The pipeline
/// only needs it at the very last step (saving), so it waits here instead of up front.
final class PendingName {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var answered = false
    private var value: String?

    /// nil = no name given (skipped / window closed) → the recording's file name is used.
    func resolve(_ name: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !answered else { return }
        answered = true
        value = name
        semaphore.signal()
    }

    var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return answered
    }

    /// Blocks the calling (background) thread until the user answers.
    func wait() -> String? {
        semaphore.wait()
        semaphore.signal() // let any later wait() return immediately too
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// «Как назвать протокол?» — a small always-on-top window with the meeting date
/// pre-filled; the user appends the project/topic so protocols of different projects
/// can be told apart in the MeetingDocs folder.
enum NamePrompt {
    private static var panel: NSPanel?
    private static var field: NSTextField?
    private static var pending: PendingName?
    private static let handler = Handler()

    static func ask(defaultName: String, recordingName: String, into pendingName: PendingName) {
        DispatchQueue.main.async {
            close(resolving: nil) // a previous unanswered prompt → it keeps the recording name
            pending = pendingName

            let title = NSTextField(labelWithString: "Как назвать протокол?")
            title.font = .boldSystemFont(ofSize: 18)

            let hint = NSTextField(wrappingLabelWithString:
                "Запись: \(recordingName)\nДопишите после даты проект и тему встречи. Протокол уже готовится — окно можно заполнить в любой момент.")
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = .secondaryLabelColor
            hint.preferredMaxLayoutWidth = 420

            let input = NSTextField(string: defaultName)
            input.font = .systemFont(ofSize: 15)
            input.widthAnchor.constraint(equalToConstant: 420).isActive = true
            input.target = handler
            input.action = #selector(Handler.save) // Enter
            field = input

            let save = NSButton(title: "Сохранить", target: handler, action: #selector(Handler.save))
            save.keyEquivalent = "\r"
            let skip = NSButton(title: "Без названия", target: handler, action: #selector(Handler.skip))

            let stack = NSStackView(views: [title, hint, input, NSStackView(views: [save, skip])])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

            let newPanel = EditablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            newPanel.title = "MeetingBRDAgent"
            newPanel.contentView = stack
            newPanel.isReleasedWhenClosed = false
            newPanel.delegate = handler
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.setContentSize(stack.fittingSize)
            newPanel.center()
            panel = newPanel

            NSApp.activate(ignoringOtherApps: true)
            newPanel.makeKeyAndOrderFront(nil)
            newPanel.makeFirstResponder(input)
            // Cursor after the date, so typing continues the name instead of replacing it.
            input.currentEditor()?.selectedRange = NSRange(location: (defaultName as NSString).length, length: 0)
            Notifier.send("Как назвать протокол?", "Окно ввода названия открыто — допишите проект и тему.")
        }
    }

    /// Closes the window if it's still open (e.g. the pipeline failed) — counts as no name.
    static func dismiss() {
        DispatchQueue.main.async { close(resolving: nil) }
    }

    private static func close(resolving name: String?) {
        let current = pending
        pending = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        field = nil
        current?.resolve(name)
    }

    private final class Handler: NSObject, NSWindowDelegate {
        @objc func save() {
            let text = NamePrompt.field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NamePrompt.close(resolving: text.isEmpty ? nil : text)
        }
        @objc func skip() { NamePrompt.close(resolving: nil) }
        func windowWillClose(_ notification: Notification) { NamePrompt.close(resolving: nil) }
    }

    /// The agent has no Edit menu (menu bar app), so ⌘V/⌘C/⌘X/⌘A/⌘Z wouldn't reach the
    /// text field on their own — route them by hand.
    private final class EditablePanel: NSPanel {
        override var canBecomeKey: Bool { true }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return super.performKeyEquivalent(with: event)
            }
            let actions: [String: Selector] = [
                "v": #selector(NSText.paste(_:)), "м": #selector(NSText.paste(_:)),
                "c": #selector(NSText.copy(_:)), "с": #selector(NSText.copy(_:)),
                "x": #selector(NSText.cut(_:)), "ч": #selector(NSText.cut(_:)),
                "a": #selector(NSText.selectAll(_:)), "ф": #selector(NSText.selectAll(_:)),
                "z": Selector(("undo:")), "я": Selector(("undo:"))
            ]
            if let action = actions[key], NSApp.sendAction(action, to: nil, from: self) {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
