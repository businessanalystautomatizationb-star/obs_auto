import Foundation
import CryptoKit

/// Minimal obs-websocket v5 client: enough to authenticate, start/stop
/// recording, and learn the output file path when recording stops.
final class OBSClient: NSObject, URLSessionWebSocketDelegate {
    private let host: String
    private let port: Int
    private let password: String
    private let reconnectInterval: TimeInterval = 5

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var identified = false
    private var reconnectTimer: Timer?

    var onRecordingStopped: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onError: ((String) -> Void)?

    var isConnected: Bool { identified }

    init(host: String, port: Int, password: String) {
        self.host = host
        self.port = port
        self.password = password
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        identified = false
        guard let url = URL(string: "ws://\(host):\(port)") else { return }
        task = session.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
    }

    /// OBS may not be running yet, or may quit/restart mid-session (e.g. while
    /// tweaking settings) — keep retrying instead of leaving a dead socket around.
    private func scheduleReconnect() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reconnectTimer == nil else { return }
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: self.reconnectInterval, repeats: false) { [weak self] _ in
                self?.reconnectTimer = nil
                self?.connect()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        identified = false
        onError?("Соединение с OBS разорвано, переподключаюсь…")
        scheduleReconnect()
    }

    func startRecording() {
        send(op: 6, data: ["requestType": "StartRecord", "requestId": UUID().uuidString])
    }

    func stopRecording() {
        send(op: 6, data: ["requestType": "StopRecord", "requestId": UUID().uuidString])
    }

    private func send(op: Int, data: [String: Any]) {
        guard identified else {
            onError?("OBS не подключён — команда не отправлена")
            return
        }
        let message: [String: Any] = ["op": op, "d": data]
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: json, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.onError?("send error: \(error.localizedDescription)") }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.identified = false
                self.onError?("receive error: \(error.localizedDescription)")
                self.scheduleReconnect()
                return
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text)
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? Int else { return }

        switch op {
        case 0: // Hello
            handleHello(obj["d"] as? [String: Any] ?? [:])
        case 2: // Identified
            identified = true
            onConnected?()
        case 5: // Event
            handleEvent(obj["d"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func handleHello(_ hello: [String: Any]) {
        var identify: [String: Any] = ["rpcVersion": 1]

        if let authInfo = hello["authentication"] as? [String: Any],
           let challenge = authInfo["challenge"] as? String,
           let salt = authInfo["salt"] as? String {
            identify["authentication"] = computeAuth(password: password, salt: salt, challenge: challenge)
        }

        let message: [String: Any] = ["op": 1, "d": identify]
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: json, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func computeAuth(password: String, salt: String, challenge: String) -> String {
        func sha256Base64(_ input: String) -> String {
            let digest = SHA256.hash(data: Data(input.utf8))
            return Data(digest).base64EncodedString()
        }
        let secret = sha256Base64(password + salt)
        return sha256Base64(secret + challenge)
    }

    private func handleEvent(_ eventData: [String: Any]) {
        guard let eventType = eventData["eventType"] as? String else { return }
        if eventType == "RecordStateChanged" {
            guard let inner = eventData["eventData"] as? [String: Any],
                  let outputActive = inner["outputActive"] as? Bool,
                  outputActive == false,
                  let path = inner["outputPath"] as? String else { return }
            onRecordingStopped?(path)
        }
    }
}
