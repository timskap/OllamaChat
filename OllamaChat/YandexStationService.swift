import Foundation
import Network
import SwiftUI

struct YandexDevice: Identifiable, Codable, Equatable {
    var id: String        // device_id (quasar)
    var name: String
    var platform: String
    var host: String?     // discovered via Bonjour
    var port: Int?
    var conversationToken: String?
}

@MainActor
class YandexStationService: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var statusText = ""
    @Published var lastCommand = ""
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "yandexStationEnabled") }
    }
    @Published var xToken: String {
        didSet { UserDefaults.standard.set(xToken, forKey: "yandexXToken") }
    }
    @Published var triggerWord: String {
        didSet { UserDefaults.standard.set(triggerWord, forKey: "yandexStationTrigger") }
    }
    @Published var devices: [YandexDevice] = []
    @Published var selectedDeviceID: String {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "yandexSelectedDevice") }
    }
    @Published var isDiscovering = false
    @Published var isFetchingDevices = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var bonjourBrowser: NWBrowser?
    private var discoveredHosts: [String: (host: String, port: Int)] = [:] // device_id → host:port

    /// Called when the station hears the trigger word + query
    var onCommandReceived: ((String) -> Void)?

    override init() {
        self.enabled = UserDefaults.standard.bool(forKey: "yandexStationEnabled")
        self.xToken = UserDefaults.standard.string(forKey: "yandexXToken") ?? ""
        self.triggerWord = UserDefaults.standard.string(forKey: "yandexStationTrigger") ?? "оллама"
        self.selectedDeviceID = UserDefaults.standard.string(forKey: "yandexSelectedDevice") ?? ""
        super.init()
        // Load cached devices
        if let data = UserDefaults.standard.data(forKey: "yandexDevices"),
           let cached = try? JSONDecoder().decode([YandexDevice].self, from: data) {
            self.devices = cached
        }
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: "yandexDevices")
        }
    }

    // MARK: - Login: get x_token from Session_id cookie

    /// Exchange Yandex Session_id cookie for x_token
    func loginWithSessionId(_ sessionId: String) async -> Bool {
        statusText = "Logging in..."
        let url = URL(string: "https://mobileproxy.passport.yandex.net/1/bundle/oauth/token_by_sessionid")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("passport.yandex.ru", forHTTPHeaderField: "Ya-Client-Host")
        request.setValue("Session_id=\(sessionId)", forHTTPHeaderField: "Ya-Client-Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=c0ebe342af7d48fbbbfcf2d2eedb8f9e&client_secret=ad0a908f0aa341a182a37ecd75bc319e"
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                statusText = "Login failed: invalid response"
                return false
            }
            if let token = json["access_token"] as? String {
                xToken = token
                statusText = "Logged in successfully"
                return true
            } else {
                let err = json["error_description"] as? String ?? "unknown"
                statusText = "Login failed: \(err)"
                return false
            }
        } catch {
            statusText = "Login error: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Discover devices

    func discoverDevices() async {
        guard !xToken.isEmpty else {
            statusText = "Set x_token first"
            return
        }

        isFetchingDevices = true
        defer { isFetchingDevices = false }
        statusText = "Loading devices from Yandex..."

        // Step 1: Get all devices from Yandex IoT API
        let url = URL(string: "https://iot.quasar.yandex.ru/m/v3/user/devices")!
        var request = URLRequest(url: url)
        request.setValue("OAuth \(xToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let households = json["households"] as? [[String: Any]] else {
                statusText = "Failed to parse devices"
                return
            }

            var foundDevices: [YandexDevice] = []
            for household in households {
                guard let allDevices = household["all"] as? [[String: Any]] else { continue }
                for d in allDevices {
                    guard let id = d["id"] as? String,
                          let name = d["name"] as? String,
                          let type = d["type"] as? String else { continue }
                    // Only Yandex speakers/stations
                    if type.contains("yandex.station") || type.contains("yandex.module") || type.contains("speaker") {
                        // Need to fetch device_id and platform separately
                        if let (deviceId, platform) = await loadSpeakerConfig(deviceId: id) {
                            foundDevices.append(YandexDevice(
                                id: deviceId, name: name, platform: platform,
                                host: nil, port: nil, conversationToken: nil
                            ))
                        }
                    }
                }
            }

            devices = foundDevices
            saveDevices()
            statusText = "Found \(foundDevices.count) speaker(s)"

            // Step 2: Discover IPs via Bonjour
            startBonjourDiscovery()

            // Step 3: Get conversation tokens for each device
            for i in devices.indices {
                if let token = await fetchGlagolToken(deviceId: devices[i].id, platform: devices[i].platform) {
                    devices[i].conversationToken = token
                }
            }
            saveDevices()
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    private func loadSpeakerConfig(deviceId: String) async -> (String, String)? {
        let url = URL(string: "https://iot.quasar.yandex.ru/m/user/devices/\(deviceId)/configuration")!
        var request = URLRequest(url: url)
        request.setValue("OAuth \(xToken)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qInfo = json["quasar_info"] as? [String: Any],
              let qDeviceId = qInfo["device_id"] as? String,
              let platform = qInfo["platform"] as? String else { return nil }
        return (qDeviceId, platform)
    }

    private func fetchGlagolToken(deviceId: String, platform: String) async -> String? {
        let url = URL(string: "https://quasar.yandex.net/glagol/token?device_id=\(deviceId)&platform=\(platform)")!
        var request = URLRequest(url: url)
        request.setValue("OAuth \(xToken)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String, status == "ok",
              let token = json["token"] as? String else { return nil }
        return token
    }

    // MARK: - Bonjour Discovery (_yandexio._tcp)

    func startBonjourDiscovery() {
        guard bonjourBrowser == nil else { return }
        isDiscovering = true
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_yandexio._tcp.", domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBonjourResults(results)
            }
        }
        browser.start(queue: .main)
        bonjourBrowser = browser

        // Stop discovery after 10 seconds
        Task {
            try? await Task.sleep(for: .seconds(10))
            await MainActor.run {
                self.bonjourBrowser?.cancel()
                self.bonjourBrowser = nil
                self.isDiscovering = false
            }
        }
    }

    private func handleBonjourResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // TXT records contain deviceId and platform
            var deviceId: String?
            if case .bonjour(let metadata) = result.metadata {
                deviceId = metadata.dictionary["deviceId"]
            }

            // Resolve host
            let conn = NWConnection(to: result.endpoint, using: .tcp)
            conn.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let endpoint = conn.currentPath?.remoteEndpoint {
                    if case .hostPort(let host, let port) = endpoint {
                        let hostStr = "\(host)".replacingOccurrences(of: "%en0", with: "")
                            .components(separatedBy: "%").first ?? "\(host)"
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            print("[Yandex] Discovered: \(name) at \(hostStr):\(port.rawValue), deviceId: \(deviceId ?? "?")")
                            if let did = deviceId, let idx = self.devices.firstIndex(where: { $0.id == did }) {
                                self.devices[idx].host = hostStr
                                self.devices[idx].port = Int(port.rawValue)
                                self.saveDevices()
                            }
                        }
                    }
                    conn.cancel()
                }
            }
            conn.start(queue: .main)
        }
    }

    // MARK: - WebSocket Connection

    func connect() {
        guard let device = devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first,
              let host = device.host, let port = device.port,
              let token = device.conversationToken else {
            statusText = "Device not ready (need host + token)"
            return
        }

        guard let url = URL(string: "wss://\(host):\(port)") else { return }

        let session = URLSession(configuration: .default, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        statusText = "Connecting to \(device.name)..."
        receiveMessage()
        sendInitial(token: token)
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        statusText = ""
    }

    private func sendInitial(token: String) {
        let msg: [String: Any] = [
            "conversationToken": token,
            "id": UUID().uuidString,
            "payload": ["command": "softwareVersion"],
            "sentTime": Int(Date().timeIntervalSince1970 * 1000)
        ]
        send(json: msg)

        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPing(token: token) }
        }
    }

    private func sendPing(token: String) {
        let msg: [String: Any] = [
            "conversationToken": token,
            "id": UUID().uuidString,
            "payload": ["command": "ping"],
            "sentTime": Int(Date().timeIntervalSince1970 * 1000)
        ]
        send(json: msg)
    }

    /// Native TTS via local mode — uses the "repeat_after_me" form
    /// (no "повторяю", supports SSML effects, no length limit)
    func say(_ text: String) {
        guard let device = devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first,
              let token = device.conversationToken else { return }

        // Convert Cyrillic to UPPERCASE (yandex parser quirk to avoid TTS chunking)
        let fixedText = text.uppercaseRussian()

        let payload: [String: Any] = [
            "command": "serverAction",
            "serverActionEventPayload": [
                "type": "server_action",
                "name": "update_form",
                "payload": [
                    "form_update": [
                        "name": "personal_assistant.scenarios.repeat_after_me",
                        "slots": [
                            ["type": "string", "name": "request", "value": fixedText]
                        ]
                    ],
                    "resubmit": true
                ]
            ]
        ]

        let msg: [String: Any] = [
            "conversationToken": token,
            "id": UUID().uuidString,
            "payload": payload,
            "sentTime": Int(Date().timeIntervalSince1970 * 1000)
        ]
        send(json: msg)
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in self?.statusText = "Send error: \(error.localizedDescription)" }
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

        // Try to extract original_utterance from various paths
        if let payload = json["payload"] as? [String: Any] {
            if let request = payload["request"] as? [String: Any],
               let original = request["original_utterance"] as? String {
                handleVoiceCommand(original)
            }
        }
        if let state = json["state"] as? [String: Any],
           let request = state["vinsResponse"] as? [String: Any],
           let payload = request["payload"] as? [String: Any],
           let req = payload["request"] as? [String: Any],
           let original = req["original_utterance"] as? String {
            handleVoiceCommand(original)
        }
    }

    private func handleVoiceCommand(_ text: String) {
        lastCommand = text
        let lower = text.lowercased()
        let trigger = triggerWord.lowercased()
        guard lower.contains(trigger) else { return }

        let query: String
        if let range = lower.range(of: trigger) {
            query = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        } else {
            query = text
        }
        guard !query.isEmpty else { return }
        print("[Yandex] Triggered: \(query)")
        onCommandReceived?(query)
    }
}

private extension String {
    /// Yandex parser quirk: uppercase Cyrillic prevents TTS from chunking long text
    func uppercaseRussian() -> String {
        var result = ""
        for char in self {
            let s = String(char)
            if s.range(of: "[а-яё]", options: .regularExpression) != nil {
                result += s.uppercased()
            } else {
                result += s
            }
        }
        return result
    }
}

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
