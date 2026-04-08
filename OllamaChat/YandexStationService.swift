import Foundation
import SwiftUI

/// Yandex Station integration via local WebSocket protocol
/// Based on AlexxIT/YandexStation Home Assistant plugin
@MainActor
class YandexStationService: ObservableObject {
    @Published var isConnected = false
    @Published var statusText = ""
    @Published var deviceName = ""
    @Published var lastCommand = ""
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "yandexStationEnabled") }
    }
    @Published var deviceHost: String {
        didSet { UserDefaults.standard.set(deviceHost, forKey: "yandexStationHost") }
    }
    @Published var devicePort: String {
        didSet { UserDefaults.standard.set(devicePort, forKey: "yandexStationPort") }
    }
    @Published var conversationToken: String {
        didSet { UserDefaults.standard.set(conversationToken, forKey: "yandexStationToken") }
    }
    @Published var triggerWord: String {
        didSet { UserDefaults.standard.set(triggerWord, forKey: "yandexStationTrigger") }
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    weak var ollama: OllamaService?
    weak var store: ProjectStore?

    /// Called when the station hears the trigger word + query
    var onCommandReceived: ((String) -> Void)?

    init() {
        self.enabled = UserDefaults.standard.bool(forKey: "yandexStationEnabled")
        self.deviceHost = UserDefaults.standard.string(forKey: "yandexStationHost") ?? ""
        self.devicePort = UserDefaults.standard.string(forKey: "yandexStationPort") ?? "1961"
        self.conversationToken = UserDefaults.standard.string(forKey: "yandexStationToken") ?? ""
        self.triggerWord = UserDefaults.standard.string(forKey: "yandexStationTrigger") ?? "оллама"
    }

    // MARK: - Connection

    func connect() {
        guard !deviceHost.isEmpty, !conversationToken.isEmpty else {
            statusText = "Configure host and token in Settings"
            return
        }

        guard let url = URL(string: "wss://\(deviceHost):\(devicePort)") else {
            statusText = "Invalid URL"
            return
        }

        // Yandex Station uses self-signed cert, allow it
        let session = URLSession(configuration: .default, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        statusText = "Connecting..."
        receiveMessage()
        sendInitialPing()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        statusText = ""
    }

    private func sendInitialPing() {
        let msg: [String: Any] = [
            "conversationToken": conversationToken,
            "id": UUID().uuidString,
            "payload": ["command": "softwareVersion"],
            "sentTime": Int(Date().timeIntervalSince1970 * 1000)
        ]
        send(json: msg)

        // Start keepalive
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendPing()
            }
        }
    }

    private func sendPing() {
        let msg: [String: Any] = [
            "conversationToken": conversationToken,
            "id": UUID().uuidString,
            "payload": ["command": "ping"],
            "sentTime": Int(Date().timeIntervalSince1970 * 1000)
        ]
        send(json: msg)
    }

    /// Send TTS — make Alice speak text
    func say(_ text: String) {
        let msg: [String: Any] = [
            "conversationToken": conversationToken,
            "id": UUID().uuidString,
            "payload": [
                "command": "sendText",
                "text": "Повтори за мной '\(text.replacingOccurrences(of: "'", with: " "))'"
            ],
            "sentTime": Int(Date().timeIntervalSince1970 * 1000)
        ]
        send(json: msg)
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.statusText = "Send error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.statusText = "Disconnected: \(error.localizedDescription)"
                    self.isConnected = false
                    self.pingTimer?.invalidate()
                case .success(let message):
                    if !self.isConnected {
                        self.isConnected = true
                        self.statusText = "Connected"
                    }
                    if case .string(let text) = message {
                        self.handleMessage(text)
                    }
                    self.receiveMessage()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Look for voice command in state
        if let state = json["state"] as? [String: Any],
           let voiceState = state["aliceState"] as? String {
            print("[Yandex] State: \(voiceState)")
        }

        // Extract recognized voice text
        if let state = json["state"] as? [String: Any],
           let lastVoice = state["lastVoiceTime"] {
            print("[Yandex] Last voice: \(lastVoice)")
        }

        // Parse vinsResponse for query text
        if let payload = json["payload"] as? [String: Any],
           let query = payload["request"] as? [String: Any],
           let original = query["original_utterance"] as? String {
            print("[Yandex] Heard: \(original)")
            handleVoiceCommand(original)
        }
    }

    /// Check if voice command starts with trigger word, route to Ollama
    private func handleVoiceCommand(_ text: String) {
        lastCommand = text
        let lower = text.lowercased()
        let trigger = triggerWord.lowercased()

        guard lower.contains(trigger) else { return }

        // Extract query after trigger word
        let query: String
        if let range = lower.range(of: trigger) {
            query = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        } else {
            query = text
        }

        guard !query.isEmpty else { return }

        print("[Yandex] Triggered query: \(query)")
        onCommandReceived?(query)
    }
}

/// Allow self-signed certificates (Yandex Station uses local self-signed cert)
private class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
