
import Foundation

@MainActor
class OllamaService: ObservableObject {
    @Published var isGenerating = false
    @Published var isThinking = false
    @Published var isSearching = false
    @Published var detectedLanguage: String = ""
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "ollamaModel") }
    }
    @Published var availableModels: [String] = []

    private let baseURL = "http://localhost:11434"
    private var currentTask: Task<Void, Never>?

    init() {
        self.selectedModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? "gemma4:26b"
        Task { await fetchModels() }
    }

    func fetchModels() async {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return }
        let names = models.compactMap { $0["name"] as? String }.sorted()
        availableModels = names
        if !names.contains(selectedModel), let first = names.first {
            selectedModel = first
        }
    }

    func send(
        _ text: String,
        imageBase64: String? = nil,
        instructions: String,
        thinkingEnabled: Bool,
        webSearchEnabled: Bool,
        store: ProjectStore,
        projectID: UUID,
        chatID: UUID
    ) async {
        let userMsg = Message(role: "user", content: text, imageBase64: imageBase64)
        store.appendMessage(projectID: projectID, chatID: chatID, message: userMsg)
        store.autoTitleIfNeeded(projectID: projectID, chatID: chatID)

        let assistantMsg = Message(role: "assistant", content: "", thinking: "")
        store.appendMessage(projectID: projectID, chatID: chatID, message: assistantMsg)

        isGenerating = true
        isThinking = thinkingEnabled

        let queueId = QueueMonitor.shared.add(
            username: "You",
            preview: String(text.prefix(50)),
            source: .desktop,
            status: webSearchEnabled ? .searching : (thinkingEnabled ? .thinking : .generating)
        )

        let task = Task {
            defer {
                Task { @MainActor in
                    self.isGenerating = false
                    self.isThinking = false
                    self.isSearching = false
                    store.saveAfterStreaming()
                    QueueMonitor.shared.remove(queueId)
                }
            }

            // Web search
            var searchContext = ""
            if webSearchEnabled {
                await MainActor.run {
                    isSearching = true
                    QueueMonitor.shared.updateStatus(queueId, status: .searching)
                }
                if let results = await WebSearchService.shared.searchAndFormat(query: text) {
                    searchContext = results
                }
                await MainActor.run {
                    isSearching = false
                    QueueMonitor.shared.updateStatus(queueId, status: thinkingEnabled ? .thinking : .generating)
                }
            }

            guard !Task.isCancelled else { return }

            // Build payload
            guard let pIdx = store.projects.firstIndex(where: { $0.id == projectID }),
                  let cIdx = store.projects[pIdx].chats.firstIndex(where: { $0.id == chatID }) else { return }

            let chatMessages = store.projects[pIdx].chats[cIdx].messages
            var payload: [[String: Any]] = []

            var systemPrompt = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !searchContext.isEmpty {
                systemPrompt += (systemPrompt.isEmpty ? "" : "\n\n") + searchContext
            }
            let langInstruction = "IMPORTANT: Start every response with a language tag like [ru-RU] or [en-US] matching the language you respond in. This tag must be the very first characters of your response. Never explain or mention this tag."
            systemPrompt += (systemPrompt.isEmpty ? "" : "\n\n") + langInstruction
            payload.append(["role": "system", "content": systemPrompt])

            // Check if model likely supports vision (only official gemma4 does)
            let supportsVision = self.selectedModel.hasPrefix("gemma4:") && !self.selectedModel.contains("heretic")

            for msg in chatMessages.dropLast() {
                var entry: [String: Any] = ["role": msg.role, "content": msg.content]
                if supportsVision, let img = msg.imageBase64, !img.isEmpty {
                    entry["images"] = [img]
                }
                payload.append(entry)
            }

            guard let url = URL(string: "\(self.baseURL)/api/chat") else { return }

            print("[Ollama] Sending to \(self.selectedModel), messages: \(payload.count), vision: \(supportsVision), think: \(thinkingEnabled)")

            let success = await self.doStream(
                url: url, payload: payload, thinkingEnabled: thinkingEnabled,
                store: store, projectID: projectID, chatID: chatID
            )

            // If failed, retry without images as fallback
            if !success {
                print("[Ollama] Retrying without images...")
                let plainPayload: [[String: Any]] = payload.map { entry in
                    var clean = entry
                    clean.removeValue(forKey: "images")
                    return clean
                }
                let _ = await self.doStream(
                    url: url, payload: plainPayload, thinkingEnabled: thinkingEnabled,
                    store: store, projectID: projectID, chatID: chatID
                )
            }
        }

        currentTask = task
        await task.value
        currentTask = nil
    }

    func cancelGeneration() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Streaming

    /// Returns true on success, false on HTTP error (for retry logic)
    private func doStream(
        url: URL, payload: [[String: Any]], thinkingEnabled: Bool,
        store: ProjectStore, projectID: UUID, chatID: UUID
    ) async -> Bool {
        let body: [String: Any] = [
            "model": self.selectedModel,
            "messages": payload,
            "stream": true,
            "think": thinkingEnabled
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var errBody = ""
                for try await line in stream.lines { errBody += line }
                print("[Ollama] HTTP \(http.statusCode): \(errBody.prefix(300))")
                return false
            }

            var accContent = ""
            var accThinking = ""
            var langParsed = false

            for try await line in stream.lines {
                if Task.isCancelled {
                    store.updateLastMessage(projectID: projectID, chatID: chatID, content: Self.stripLangTag(accContent) + "\n\n⚠️ _Cancelled_")
                    return true
                }

                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = json["message"] as? [String: Any] else { continue }

                if let thinkToken = msg["thinking"] as? String, !thinkToken.isEmpty {
                    accThinking += thinkToken
                    store.updateLastMessage(projectID: projectID, chatID: chatID, thinking: accThinking)
                }

                if let token = msg["content"] as? String, !token.isEmpty {
                    await MainActor.run { if self.isThinking { self.isThinking = false } }
                    accContent += token

                    if !langParsed, let lang = Self.extractLangTag(accContent) {
                        langParsed = true
                        await MainActor.run { self.detectedLanguage = lang }
                    }

                    store.updateLastMessage(projectID: projectID, chatID: chatID, content: Self.stripLangTag(accContent))
                }

                if let done = json["done"] as? Bool, done { break }
            }
            return true
        } catch {
            print("[Ollama] Error: \(error)")
            if !Task.isCancelled {
                store.updateLastMessage(projectID: projectID, chatID: chatID, content: "[Error: \(error.localizedDescription)]")
            }
            return false
        }
    }

    // MARK: - Language Tag Helpers

    static func extractLangTag(_ text: String) -> String? {
        guard text.hasPrefix("["),
              let end = text.firstIndex(of: "]") else { return nil }
        let tag = String(text[text.index(after: text.startIndex)..<end])
        if tag.count >= 2 && tag.count <= 10 && tag.first?.isLetter == true {
            return tag
        }
        return nil
    }

    static func stripLangTag(_ text: String) -> String {
        guard text.hasPrefix("["),
              let end = text.firstIndex(of: "]") else { return text }
        let after = text.index(after: end)
        var result = String(text[after...])
        while result.first == " " || result.first == "\n" {
            result.removeFirst()
        }
        return result
    }
}
