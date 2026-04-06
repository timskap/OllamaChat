import Foundation

@MainActor
class OllamaService: ObservableObject {
    @Published var isGenerating = false
    @Published var isThinking = false
    @Published var isSearching = false
    @Published var detectedLanguage: String = ""

    private let baseURL = "http://localhost:11434"
    private var model = "gemma4:26b"
    private var currentTask: Task<Void, Never>?

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

        let task = Task {
            defer {
                Task { @MainActor in
                    self.isGenerating = false
                    self.isThinking = false
                    self.isSearching = false
                    store.saveAfterStreaming()
                }
            }

            // Web search
            var searchContext = ""
            if webSearchEnabled {
                await MainActor.run { isSearching = true }
                if let results = await WebSearchService.shared.searchAndFormat(query: text) {
                    searchContext = results
                }
                await MainActor.run { isSearching = false }
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

            // Inject language tag instruction for TTS
            let langInstruction = "IMPORTANT: Start every response with a language tag like [ru-RU] or [en-US] matching the language you respond in. This tag must be the very first characters of your response. Never explain or mention this tag."
            systemPrompt += (systemPrompt.isEmpty ? "" : "\n\n") + langInstruction

            payload.append(["role": "system", "content": systemPrompt])

            for msg in chatMessages.dropLast() {
                var entry: [String: Any] = ["role": msg.role, "content": msg.content]
                if let img = msg.imageBase64, !img.isEmpty {
                    entry["images"] = [img]
                }
                payload.append(entry)
            }

            let body: [String: Any] = [
                "model": self.model,
                "messages": payload,
                "stream": true,
                "think": thinkingEnabled
            ]

            guard let url = URL(string: "\(self.baseURL)/api/chat"),
                  let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                let (stream, _) = try await URLSession.shared.bytes(for: request)
                var accContent = ""
                var accThinking = ""
                var langParsed = false

                for try await line in stream.lines {
                    if Task.isCancelled {
                        store.updateLastMessage(projectID: projectID, chatID: chatID, content: Self.stripLangTag(accContent) + "\n\n⚠️ _Cancelled_")
                        return
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

                        // Parse language tag from first tokens
                        if !langParsed, let lang = Self.extractLangTag(accContent) {
                            langParsed = true
                            await MainActor.run { self.detectedLanguage = lang }
                        }

                        store.updateLastMessage(projectID: projectID, chatID: chatID, content: Self.stripLangTag(accContent))
                    }

                    if let done = json["done"] as? Bool, done { break }
                }
            } catch {
                if !Task.isCancelled {
                    store.updateLastMessage(projectID: projectID, chatID: chatID, content: "[Error: \(error.localizedDescription)]")
                }
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

    // MARK: - Language Tag Helpers

    /// Extract language tag like "ru-RU" from "[ru-RU] text..."
    static func extractLangTag(_ text: String) -> String? {
        guard text.hasPrefix("["),
              let end = text.firstIndex(of: "]") else { return nil }
        let tag = String(text[text.index(after: text.startIndex)..<end])
        // Validate it looks like a locale: xx-XX or xx
        if tag.count >= 2 && tag.count <= 10 && tag.first?.isLetter == true {
            return tag
        }
        return nil
    }

    /// Strip the leading [xx-XX] tag from text
    static func stripLangTag(_ text: String) -> String {
        guard text.hasPrefix("["),
              let end = text.firstIndex(of: "]") else { return text }
        let after = text.index(after: end)
        var result = String(text[after...])
        // Remove leading whitespace/newline after tag
        while result.first == " " || result.first == "\n" {
            result.removeFirst()
        }
        return result
    }
}
