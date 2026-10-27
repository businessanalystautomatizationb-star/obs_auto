import Foundation

/// Watches the OBS level meter of the "other participants" audio source while a
/// recording runs and raises an alarm when it is missing or stays silent too long —
/// the failure mode where the file only contains your own microphone.
/// All methods are expected to be called on the main thread.
final class AudioWatchdog {
    /// Name of the OBS input carrying the call's audio (macOS Audio Capture of zoom.us).
    let inputName: String
    /// ~ -50 dBFS: well above digital silence, well below quiet speech.
    private let threshold: Float = 0.003
    /// No input in the meters at all after this long → the source is missing/disabled.
    private let missingLimit: TimeInterval = 20
    /// Continuous silence this long → others are probably not being captured.
    private let silenceLimit: TimeInterval = 120

    var onAlarm: ((String, String) -> Void)?
    var onRecovered: (() -> Void)?

    private var timer: Timer?
    private var startedAt = Date()
    private var lastHeard: Date?
    private var inputSeen = false
    private var alarmed = false

    init(inputName: String) {
        self.inputName = inputName
    }

    func start() {
        stop()
        startedAt = Date()
        lastHeard = nil
        inputSeen = false
        alarmed = false
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func feed(_ levels: [String: Float]) {
        guard timer != nil, let level = levels[inputName] else { return }
        inputSeen = true
        guard level > threshold else { return }
        lastHeard = Date()
        if alarmed {
            alarmed = false
            onRecovered?()
        }
    }

    private func check() {
        guard !alarmed else { return }
        let now = Date()
        if !inputSeen {
            if now.timeIntervalSince(startedAt) > missingLimit {
                raise("Собеседники НЕ записываются",
                      "В OBS нет активного источника «\(inputName)». Откройте OBS и проверьте, что источник есть и включён — иначе в записи будет только ваш голос.")
            }
            return
        }
        let silentFor = now.timeIntervalSince(lastHeard ?? startedAt)
        if silentFor > silenceLimit {
            raise("Нет звука собеседников",
                  "Уже \(Int(silentFor / 60)) мин в источнике «\(inputName)» тишина. Если собеседники говорят — звук не пишется: проверьте в OBS источник «\(inputName)» (выбрано приложение zoom.us, не выключен).")
        }
    }

    private func raise(_ title: String, _ message: String) {
        alarmed = true
        onAlarm?(title, message)
    }
}
