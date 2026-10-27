import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!

    private let config = Config.loadOrCreateDefault()
    private var obs: OBSClient!
    private let windowWatcher = WindowWatcher()
    private var pipeline: Pipeline!

    private var isRecording = false
    private var lastNotifiedStatus: String?
    /// Set when a recording was requested but OBS wasn't connected yet — fulfilled
    /// once `obs.onConnected` fires, instead of silently dropping the start command.
    private var pendingRecordingStart = false

    /// StartRecord is retried until OBS confirms (RecordStateChanged → STARTED): right
    /// after launch OBS accepts the websocket before its scenes/outputs are loaded and
    /// silently drops the first command — that's how a meeting ended up not recorded.
    private var startRetryTimer: Timer?
    private var startDeadline = Date()
    private let startTimeout: TimeInterval = 60
    private let startRetryInterval: TimeInterval = 3

    /// OBS global audio inputs: «Звук Zoom» = macOS Audio Capture of zoom.us (independent
    /// of which displays are connected), «Микр/доп» = the microphone.
    private let callAudioInput = "Звук Zoom"
    private let micInput = "Микр/доп"
    private lazy var audioWatchdog = AudioWatchdog(inputName: callAudioInput)

    func applicationDidFinishLaunching(_ notification: Notification) {
        pipeline = Pipeline(config: config)
        // OBS is launched lazily, only when a meeting is actually detected (see
        // beginRecording()) — no point keeping it running from login until whenever the
        // first call of the day happens.
        setupStatusItem()
        setupOBS()
        setupWindowWatcher()

        if config.deepgramKey == "CHANGE_ME" || config.anthropicKey == "CHANGE_ME" || config.obsPassword == "CHANGE_ME" {
            setStatus("⚠️ Заполни ~/.meeting-brd-agent/config.json")
        }
    }

    // MARK: - Menu bar UI

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "🟡"

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Ожидание встречи…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        startItem = NSMenuItem(title: "Начать запись", action: #selector(startRecordingManually), keyEquivalent: "r")
        menu.addItem(startItem)
        stopItem = NSMenuItem(title: "Остановить запись", action: #selector(stopRecordingManually), keyEquivalent: "s")
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Открыть конфиг", action: #selector(openConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Открыть папку с документами", action: #selector(openOutputFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(Config.path)
    }

    @objc private func openOutputFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.outputFolder, isDirectory: true))
    }

    @objc private func startRecordingManually() {
        guard !isRecording else { return }
        beginRecording()
    }

    @objc private func stopRecordingManually() {
        guard isRecording else { return }
        setStatus("Останавливаю запись вручную…")
        obs.stopRecording()
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusMenuItem.title = text
            // Dedup so a repeated identical message (e.g. the OBS reconnect loop
            // retrying every 5s while OBS is down) doesn't spam the notification center.
            guard text != self.lastNotifiedStatus else { return }
            self.lastNotifiedStatus = text
            Notifier.send("MeetingBRDAgent", text)
        }
    }

    private func beginRecording() {
        isRecording = true
        statusItem.button?.title = "🔴"
        startItem.isEnabled = false
        stopItem.isEnabled = true

        if obs.isConnected {
            startRecordingVerified()
        } else {
            // OBS isn't running (or isn't connected yet) — launch/connect now and defer
            // the actual StartRecord until obs.onConnected fires, instead of showing 🔴
            // with nothing actually being recorded.
            pendingRecordingStart = true
            setStatus("OBS не запущен, открываю и жду подключения…")
            OBSLauncher.launchIfNeeded()
            obs.connect()
            armStartTimeout()
        }
    }

    /// Sends StartRecord now and keeps re-sending until OBS confirms or the deadline passes.
    private func startRecordingVerified() {
        setStatus("Запускаю запись, жду подтверждения от OBS…")
        if startRetryTimer == nil { armStartTimeout() }
        obs.startRecording()
    }

    private func armStartTimeout() {
        startRetryTimer?.invalidate()
        startDeadline = Date().addingTimeInterval(startTimeout)
        startRetryTimer = Timer.scheduledTimer(withTimeInterval: startRetryInterval, repeats: true) { [weak self] _ in
            self?.retryStart()
        }
    }

    private func retryStart() {
        guard isRecording else { return cancelStartRetry() }
        if Date() > startDeadline {
            cancelStartRetry()
            pendingRecordingStart = false
            isRecording = false
            statusItem.button?.title = "⚠️"
            startItem.isEnabled = true
            stopItem.isEnabled = false
            setStatus("Запись НЕ началась")
            Alarm.show("Запись НЕ идёт",
                       "OBS не подтвердил начало записи за \(Int(startTimeout)) сек. Откройте OBS и нажмите «Начать запись» вручную (или меню агента → «Начать запись»).")
            return
        }
        // While still disconnected, OBSClient's own reconnect loop is at work and
        // onConnected will send the first StartRecord — nothing to do here yet.
        if obs.isConnected && !pendingRecordingStart {
            obs.startRecording()
        }
    }

    private func cancelStartRetry() {
        startRetryTimer?.invalidate()
        startRetryTimer = nil
    }

    private func recordingConfirmed() {
        cancelStartRetry()
        // Covers a recording started by hand in OBS too, so the stop/alarm logic applies.
        isRecording = true
        statusItem.button?.title = "🔴"
        startItem.isEnabled = false
        stopItem.isEnabled = true
        setStatus("Запись идёт ✅")
        // Settings can drift between meetings (a click in the mixer) — force both sides on.
        obs.setInputMute(callAudioInput, muted: false)
        obs.setInputMute(micInput, muted: false)
        audioWatchdog.start()
    }

    // MARK: - OBS

    private func setupOBS() {
        obs = OBSClient(host: config.obsHost, port: config.obsPort, password: config.obsPassword)
        obs.onConnected = { [weak self] in
            guard let self else { return }
            if self.pendingRecordingStart {
                DispatchQueue.main.async {
                    self.pendingRecordingStart = false
                    self.startRecordingVerified()
                }
            } else {
                self.setStatus("Подключено к OBS. Ожидание встречи…")
            }
        }
        obs.onError = { [weak self] message in
            self?.setStatus("OBS: \(message)")
        }
        obs.onRecordingStarted = { [weak self] in
            DispatchQueue.main.async { self?.recordingConfirmed() }
        }
        obs.onRequestFailed = { [weak self] requestType, code, comment in
            print("DIAG OBS \(requestType) failed: code=\(code) \(comment)")
            // 500 = OutputRunning: an earlier retry already got through, so it's recording.
            if requestType == "StartRecord" && code == 500 {
                DispatchQueue.main.async { self?.recordingConfirmed() }
            }
        }
        obs.onInputLevels = { [weak self] levels in
            DispatchQueue.main.async { self?.audioWatchdog.feed(levels) }
        }
        audioWatchdog.onAlarm = { [weak self] title, message in
            self?.statusItem.button?.title = "⚠️"
            self?.setStatus(title)
            Alarm.show(title, message)
        }
        audioWatchdog.onRecovered = { [weak self] in
            guard let self, self.isRecording else { return }
            self.statusItem.button?.title = "🔴"
            self.setStatus("Звук собеседников появился, запись идёт ✅")
            Alarm.dismiss()
        }
        obs.onRecordingStopped = { [weak self] path in
            guard let self else { return }
            DispatchQueue.main.async {
                self.audioWatchdog.stop()
                self.cancelStartRetry()
            }
            self.isRecording = false
            self.statusItem.button?.title = "🟡"
            self.startItem.isEnabled = true
            self.stopItem.isEnabled = false
            self.setStatus("Запись сохранена, закрываю OBS и запускаю обработку…")
            OBSLauncher.quit()
            self.pipeline.run(recordingPath: path) { [weak self] message in
                self?.setStatus(message)
            }
        }
        // No obs.connect() here — connecting (and launching OBS) happens lazily in
        // beginRecording() once a meeting is actually detected, so the agent doesn't sit
        // there retrying a websocket connection every 5s for hours with nothing to record.
    }

    // MARK: - Meeting detection

    private func setupWindowWatcher() {
        windowWatcher.onMeetingDetected = { [weak self] in
            guard let self, !self.isRecording else { return }
            self.setStatus("Встреча обнаружена, записываю…")
            self.beginRecording()
        }
        windowWatcher.onMeetingEnded = { [weak self] in
            guard let self, self.isRecording else { return }
            self.setStatus("Встреча завершена, останавливаю запись…")
            self.obs.stopRecording()
        }
        // Safety net for manually-started recordings (and for cases where the exact
        // title never matched to begin with): stop once the call app has genuinely
        // closed, regardless of how the recording was started.
        windowWatcher.onCallAppWindowGone = { [weak self] in
            guard let self, self.isRecording else { return }
            self.setStatus("Zoom/Teams закрыт, останавливаю запись…")
            self.obs.stopRecording()
        }
        windowWatcher.start()
    }
}
