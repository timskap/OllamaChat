import Foundation

@MainActor
class TelegramService: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = ""
    @Published var pendingUsers: [PendingUser] = []

    struct PendingUser: Identifiable {
        var id: Int64
        var username: String
        var projectID: UUID
    }

    private var pollingTask: Task<Void, Never>?
    private var thinkingEnabled: Set<String> = []
    private var webSearchEnabled: Set<String> = []
    /// /whisper mode — just transcribe, no LLM response
    private var whisperMode: Set<String> = []
    /// Active generation tasks keyed by convKey, for cancellation
    private var activeTasks: [String: Task<Void, Never>] = [:]

    private let ollamaURL = "http://localhost:11434/api/chat"
    private var ollamaModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? "gemma4:26b"
    }
    private let streamEditInterval: TimeInterval = 1.5

    private var botProjectID: UUID?
    private weak var store: ProjectStore?
    private weak var audio: AudioService?

    private func convKey(_ chatId: Int64, _ threadId: Int64?) -> String {
        "\(chatId)_\(threadId ?? 0)"
    }

    // MARK: - Start / Stop

    func start(projectID: UUID, store: ProjectStore, audio: AudioService? = nil) {
        guard let project = store.projects.first(where: { $0.id == projectID }),
              !project.telegram.botToken.isEmpty,
              project.telegram.enabled,
              !isRunning else { return }

        self.botProjectID = projectID
        self.store = store
        self.audio = audio
        isRunning = true
        statusText = "Connected"

        let token = project.telegram.botToken

        pollingTask = Task {
            var offset: Int64 = 0
            while !Task.isCancelled {
                do {
                    let updates = try await getUpdates(token: token, offset: offset)
                    for update in updates {
                        offset = update.updateId + 1
                        if let inlineQuery = update.inlineQuery {
                            await handleInlineQuery(token: token, query: inlineQuery)
                        } else if let chosenResult = update.chosenInlineResult {
                            await handleChosenInlineResult(token: token, result: chosenResult)
                        } else if let message = update.message {
                            if let photo = message.photo {
                                await handlePhoto(token: token, chatId: message.chatId, threadId: message.threadId,
                                    userId: message.userId, username: message.displayName,
                                    fileId: photo.fileId, caption: message.caption)
                            } else if let voice = message.voice {
                                await handleVoice(token: token, chatId: message.chatId, threadId: message.threadId,
                                    userId: message.userId, username: message.displayName,
                                    fileId: voice.fileId, duration: voice.duration)
                            } else if let text = message.text {
                                await handleIncoming(token: token, chatId: message.chatId, threadId: message.threadId,
                                    userId: message.userId, username: message.displayName, text: text)
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        statusText = "Error: \(error.localizedDescription)"
                        try? await Task.sleep(for: .seconds(5))
                        if !Task.isCancelled { statusText = "Reconnecting..." }
                    }
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        isRunning = false
        statusText = ""
    }

    // MARK: - Per-User Project Management

    /// Get or create a project for a Telegram user, returns projectID
    private func userProjectID(userId: Int64, username: String) -> UUID {
        guard let store else { return UUID() }

        // Look for existing project tagged with this userId
        let tag = "tg_user_\(userId)"
        if let existing = store.projects.first(where: { $0.name.hasSuffix(tag) || $0.telegram.botToken == tag }) {
            return existing.id
        }

        // Create new project for this user
        let project = store.addProject(name: "\(username)")
        // Tag it with user id in telegram.botToken field (not a real token, just a tag for lookup)
        if let pIdx = store.projects.firstIndex(where: { $0.id == project.id }) {
            store.projects[pIdx].telegram.botToken = tag

            // Copy instructions from bot project
            if let botPID = botProjectID,
               let botProject = store.projects.first(where: { $0.id == botPID }) {
                store.projects[pIdx].instructions = botProject.instructions
            }
            store.save()
        }
        return project.id
    }

    /// Get or create a chat within a user's project for a specific conversation
    private func chatID(forUser userId: Int64, username: String, chatId: Int64, threadId: Int64?, isInline: Bool = false) -> (projectID: UUID, chatID: UUID) {
        guard let store else { return (UUID(), UUID()) }

        let projectID = userProjectID(userId: userId, username: username)
        let chatTag = isInline ? "inline" : convKey(chatId, threadId)

        guard let pIdx = store.projects.firstIndex(where: { $0.id == projectID }) else {
            return (projectID, UUID())
        }

        // Find existing chat with this tag as title prefix
        let tagPrefix = "[\(chatTag)]"
        if let existingChat = store.projects[pIdx].chats.first(where: { $0.title.hasPrefix(tagPrefix) }) {
            return (projectID, existingChat.id)
        }

        // Create new chat
        let title = isInline ? "[inline] Inline Chat" : "[\(chatTag)] New Chat"
        if let chat = store.addChat(projectID: projectID, title: title) {
            return (projectID, chat.id)
        }
        return (projectID, UUID())
    }

    /// Auto-title a chat from first user message (remove tag prefix for display)
    private func autoTitle(projectID: UUID, chatID: UUID, text: String) {
        guard let store,
              let pIdx = store.projects.firstIndex(where: { $0.id == projectID }),
              let cIdx = store.projects[pIdx].chats.firstIndex(where: { $0.id == chatID }) else { return }

        let chat = store.projects[pIdx].chats[cIdx]
        // Only auto-title if still has default "New Chat" or "Inline Chat" suffix
        if chat.title.hasSuffix("New Chat") || chat.title.hasSuffix("Inline Chat") {
            let tag = chat.title.components(separatedBy: "] ").first ?? ""
            let preview = String(text.prefix(40))
            store.projects[pIdx].chats[cIdx].title = "\(tag)] \(preview)"
            store.save()
        }
    }

    // MARK: - Authorization

    private func isUserApproved(userId: Int64) -> Bool {
        guard let botPID = botProjectID,
              let project = store?.projects.first(where: { $0.id == botPID }) else { return false }
        return project.telegram.users.contains(where: { $0.id == userId && $0.approved })
    }

    private func isUserKnown(userId: Int64) -> Bool {
        guard let botPID = botProjectID,
              let project = store?.projects.first(where: { $0.id == botPID }) else { return false }
        return project.telegram.users.contains(where: { $0.id == userId })
    }

    private func registerPendingUser(userId: Int64, username: String) {
        guard let botPID = botProjectID, let store else { return }
        guard let pIdx = store.projects.firstIndex(where: { $0.id == botPID }) else { return }
        if !store.projects[pIdx].telegram.users.contains(where: { $0.id == userId }) {
            store.projects[pIdx].telegram.users.append(TelegramUser(id: userId, username: username, approved: false))
            store.save()
        }
        if !pendingUsers.contains(where: { $0.id == userId && $0.projectID == botPID }) {
            pendingUsers.append(PendingUser(id: userId, username: username, projectID: botPID))
        }
    }

    private func checkAuth(token: String, chatId: Int64, threadId: Int64? = nil, userId: Int64, username: String) async -> Bool {
        if isUserApproved(userId: userId) { return true }
        if !isUserKnown(userId: userId) {
            registerPendingUser(userId: userId, username: username)
            await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Access requested. Please wait for approval.")
        } else {
            await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Your access request is pending approval.")
        }
        return false
    }

    func approveUser(userId: Int64, projectID: UUID) {
        guard let store,
              let pIdx = store.projects.firstIndex(where: { $0.id == projectID }),
              let uIdx = store.projects[pIdx].telegram.users.firstIndex(where: { $0.id == userId }) else { return }
        store.projects[pIdx].telegram.users[uIdx].approved = true
        store.save()
        pendingUsers.removeAll { $0.id == userId && $0.projectID == projectID }
        let token = store.projects[pIdx].telegram.botToken
        Task { await sendMessage(token: token, chatId: userId, text: "You have been approved! You can now chat.") }
    }

    func denyUser(userId: Int64, projectID: UUID) {
        guard let store, let pIdx = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        store.projects[pIdx].telegram.users.removeAll { $0.id == userId }
        store.save()
        pendingUsers.removeAll { $0.id == userId && $0.projectID == projectID }
    }

    func removeUser(userId: Int64, projectID: UUID) {
        guard let store, let pIdx = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        store.projects[pIdx].telegram.users.removeAll { $0.id == userId }
        store.save()
    }

    // MARK: - Telegram API Types

    private struct TGUpdate {
        let updateId: Int64; let message: TGMessage?
        let inlineQuery: TGInlineQuery?; let chosenInlineResult: TGChosenInlineResult?
    }
    private struct TGVoice { let fileId: String; let duration: Int }
    private struct TGPhoto { let fileId: String }
    private struct TGMessage {
        let chatId: Int64; let userId: Int64; let threadId: Int64?
        let text: String?; let voice: TGVoice?; let photo: TGPhoto?
        let caption: String?; let displayName: String
    }
    private struct TGInlineQuery {
        let id: String; let userId: Int64; let query: String; let displayName: String
    }
    private struct TGChosenInlineResult {
        let resultId: String; let userId: Int64; let query: String
        let inlineMessageId: String?; let displayName: String
    }

    // MARK: - Telegram API

    private func getUpdates(token: String, offset: Int64) async throws -> [TGUpdate] {
        let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 40
        let body: [String: Any] = ["offset": offset, "timeout": 30,
            "allowed_updates": ["message", "inline_query", "chosen_inline_result"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let result = json["result"] as? [[String: Any]] else { return [] }

        return result.compactMap { item in
            guard let updateId = item["update_id"] as? Int64 else { return nil }
            var msg: TGMessage?; var iq: TGInlineQuery?; var cir: TGChosenInlineResult?

            if let m = item["message"] as? [String: Any], let chat = m["chat"] as? [String: Any], let chatId = chat["id"] as? Int64 {
                let (userId, displayName) = parseFrom(m["from"] as? [String: Any], fallbackId: chatId)
                let threadId = m["message_thread_id"] as? Int64
                var voice: TGVoice?; var photo: TGPhoto?
                if let v = m["voice"] as? [String: Any], let fid = v["file_id"] as? String {
                    voice = TGVoice(fileId: fid, duration: v["duration"] as? Int ?? 0)
                }
                if let photos = m["photo"] as? [[String: Any]], let last = photos.last, let fid = last["file_id"] as? String {
                    photo = TGPhoto(fileId: fid)
                }
                msg = TGMessage(chatId: chatId, userId: userId, threadId: threadId, text: m["text"] as? String,
                    voice: voice, photo: photo, caption: m["caption"] as? String, displayName: displayName)
            }
            if let q = item["inline_query"] as? [String: Any], let qid = q["id"] as? String, let query = q["query"] as? String {
                let (userId, dn) = parseFrom(q["from"] as? [String: Any], fallbackId: 0)
                iq = TGInlineQuery(id: qid, userId: userId, query: query, displayName: dn)
            }
            if let c = item["chosen_inline_result"] as? [String: Any], let rid = c["result_id"] as? String, let query = c["query"] as? String {
                let (userId, dn) = parseFrom(c["from"] as? [String: Any], fallbackId: 0)
                cir = TGChosenInlineResult(resultId: rid, userId: userId, query: query, inlineMessageId: c["inline_message_id"] as? String, displayName: dn)
            }
            return TGUpdate(updateId: updateId, message: msg, inlineQuery: iq, chosenInlineResult: cir)
        }
    }

    private func parseFrom(_ from: [String: Any]?, fallbackId: Int64) -> (Int64, String) {
        let userId = from?["id"] as? Int64 ?? fallbackId
        let username = from?["username"] as? String
        let firstName = from?["first_name"] as? String ?? "Unknown"
        return (userId, username.map { "@\($0)" } ?? firstName)
    }

    @discardableResult
    private func sendMessage(token: String, chatId: Int64, threadId: Int64? = nil, text: String) async -> Int64? {
        let html = Self.markdownToTelegramHTML(text)
        let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["chat_id": chatId, "text": html, "parse_mode": "HTML"]
        if let threadId { body["message_thread_id"] = threadId }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if let (data, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool {
            if ok { return (json["result"] as? [String: Any])?["message_id"] as? Int64 }
            var plain: [String: Any] = ["chat_id": chatId, "text": text]
            if let threadId { plain["message_thread_id"] = threadId }
            request.httpBody = try? JSONSerialization.data(withJSONObject: plain)
            if let (d2, _) = try? await URLSession.shared.data(for: request),
               let j2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any],
               let r2 = j2["result"] as? [String: Any] { return r2["message_id"] as? Int64 }
        }
        return nil
    }

    private func editMessage(token: String, chatId: Int64, messageId: Int64, text: String) async {
        let html = Self.markdownToTelegramHTML(text)
        let url = URL(string: "https://api.telegram.org/bot\(token)/editMessageText")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chatId, "message_id": messageId, "text": html, "parse_mode": "HTML"] as [String: Any])
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, !ok {
            let desc = json["description"] as? String ?? ""
            if desc.contains("not modified") { return }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chatId, "message_id": messageId, "text": text] as [String: Any])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func editInlineMessage(token: String, inlineMessageId: String, text: String, removeKeyboard: Bool = false) async {
        let html = Self.markdownToTelegramHTML(text)
        let url = URL(string: "https://api.telegram.org/bot\(token)/editMessageText")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["inline_message_id": inlineMessageId, "text": html, "parse_mode": "HTML"]
        if removeKeyboard { body["reply_markup"] = ["inline_keyboard": [[String: String]]()] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let (data, _) = try? await URLSession.shared.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, !ok {
            let desc = json["description"] as? String ?? ""
            if desc.contains("not modified") { return }
            var plain: [String: Any] = ["inline_message_id": inlineMessageId, "text": text]
            if removeKeyboard { plain["reply_markup"] = ["inline_keyboard": [[String: String]]()] }
            request.httpBody = try? JSONSerialization.data(withJSONObject: plain)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func answerInlineQuery(token: String, queryId: String, results: [[String: Any]]) async {
        let url = URL(string: "https://api.telegram.org/bot\(token)/answerInlineQuery")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["inline_query_id": queryId, "results": results, "cache_time": 0] as [String: Any])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func sendChatAction(token: String, chatId: Int64, threadId: Int64? = nil) async {
        let url = URL(string: "https://api.telegram.org/bot\(token)/sendChatAction")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["chat_id": chatId, "action": "typing"]
        if let threadId { body["message_thread_id"] = threadId }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - File Download

    private func downloadFile(token: String, fileId: String) async -> URL? {
        // Step 1: Get file path from Telegram
        let getFileURL = URL(string: "https://api.telegram.org/bot\(token)/getFile?file_id=\(fileId)")!
        guard let (data, _) = try? await URLSession.shared.data(from: getFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let result = json["result"] as? [String: Any],
              let filePath = result["file_path"] as? String else {
            print("[Voice] Failed to get file path from Telegram for fileId: \(fileId)")
            return nil
        }
        print("[Voice] File path: \(filePath)")

        // Step 2: Download file
        let downloadURL = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)")!
        let tempDir = FileManager.default.temporaryDirectory
        let ext = (filePath as NSString).pathExtension.isEmpty ? "oga" : (filePath as NSString).pathExtension
        let localFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        guard let (fileData, _) = try? await URLSession.shared.data(from: downloadURL),
              (try? fileData.write(to: localFile)) != nil else {
            print("[Voice] Failed to download file from Telegram")
            return nil
        }
        print("[Voice] Downloaded \(fileData.count) bytes → \(localFile.lastPathComponent)")

        // Step 3: Convert to WAV via ffmpeg
        let localWAV = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpeg = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("[Voice] ffmpeg not found at any known path")
            try? FileManager.default.removeItem(at: localFile); return nil
        }
        print("[Voice] Using ffmpeg: \(ffmpeg)")

        // Run ffmpeg off main thread to avoid blocking MainActor
        let inputPath = localFile.path
        let outputPath = localWAV.path
        let ffmpegPath = ffmpeg

        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = ["-i", inputPath, "-ar", "16000", "-ac", "1", "-f", "wav", "-y", outputPath]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]

                do {
                    try process.run()
                    process.waitUntilExit()
                    let ok = process.terminationStatus == 0
                    print("[Voice] ffmpeg exit: \(process.terminationStatus)")
                    continuation.resume(returning: ok)
                } catch {
                    print("[Voice] ffmpeg launch error: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }

        try? FileManager.default.removeItem(at: localFile)

        if success && FileManager.default.fileExists(atPath: localWAV.path) {
            print("[Voice] Converted to WAV successfully")
            return localWAV
        }
        print("[Voice] WAV conversion failed")
        return nil
    }

    private func downloadFileAsBase64(token: String, fileId: String) async -> String? {
        let getFileURL = URL(string: "https://api.telegram.org/bot\(token)/getFile?file_id=\(fileId)")!
        guard let (data, _) = try? await URLSession.shared.data(from: getFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let result = json["result"] as? [String: Any],
              let filePath = result["file_path"] as? String else { return nil }
        let downloadURL = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)")!
        guard let (fileData, _) = try? await URLSession.shared.data(from: downloadURL) else { return nil }
        return fileData.base64EncodedString()
    }

    // MARK: - Streaming Ollama

    struct OllamaResult { var content: String; var thinking: String }

    private func streamOllama(payload: [[String: Any]], think: Bool, webSearch: Bool = false, searchQuery: String? = nil, task: Task<Void, Never>? = nil, onChunk: @escaping (String) async -> Void) async -> OllamaResult? {
        let instructions: String = {
            guard let botPID = botProjectID, let project = store?.projects.first(where: { $0.id == botPID }) else { return "" }
            return project.instructions
        }()

        var searchContext = ""
        if webSearch, let query = searchQuery {
            if let results = await WebSearchService.shared.searchAndFormat(query: query) { searchContext = results }
        }

        var messages: [[String: Any]] = []
        var systemPrompt = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchContext.isEmpty { systemPrompt += (systemPrompt.isEmpty ? "" : "\n\n") + searchContext }
        let langInstruction = "IMPORTANT: Start every response with a language tag like [ru-RU] or [en-US] matching the language you respond in. This tag must be the very first characters of your response. Never explain or mention this tag."
        systemPrompt += (systemPrompt.isEmpty ? "" : "\n\n") + langInstruction
        messages.append(["role": "system", "content": systemPrompt])
        messages.append(contentsOf: payload)

        let body: [String: Any] = ["model": ollamaModel, "messages": messages, "stream": true, "think": think]
        guard let url = URL(string: ollamaURL), let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.timeoutInterval = 300

        do {
            let (stream, _) = try await URLSession.shared.bytes(for: request)
            var content = "", thinking = "", isThinkingPhase = think
            var lastEditTime = Date.distantPast

            for try await line in stream.lines {
                if Task.isCancelled { return OllamaResult(content: content + "\n\n⚠️ _Cancelled_", thinking: thinking) }

                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = json["message"] as? [String: Any] else { continue }

                if let t = msg["thinking"] as? String, !t.isEmpty { thinking += t }
                if let t = msg["content"] as? String, !t.isEmpty {
                    if isThinkingPhase { isThinkingPhase = false }
                    content += t
                }

                let now = Date()
                if now.timeIntervalSince(lastEditTime) >= streamEditInterval {
                    lastEditTime = now
                    let stripped = OllamaService.stripLangTag(content)
                    let display = isThinkingPhase ? "🧠 Thinking..." : (stripped + " ▍")
                    await onChunk(display)
                }
                if let done = json["done"] as? Bool, done { break }
            }
            return content.isEmpty && thinking.isEmpty ? nil : OllamaResult(content: content, thinking: thinking)
        } catch { return nil }
    }

    // MARK: - Inline Bot

    private func handleInlineQuery(token: String, query: TGInlineQuery) async {
        guard !query.query.trimmingCharacters(in: .whitespaces).isEmpty else {
            await answerInlineQuery(token: token, queryId: query.id, results: []); return
        }
        guard isUserApproved(userId: query.userId) else {
            let r: [String: Any] = ["type": "article", "id": "auth", "title": "Access required",
                "description": "Send /start to the bot first", "input_message_content": ["message_text": "I need access."]]
            await answerInlineQuery(token: token, queryId: query.id, results: [r]); return
        }
        let r: [String: Any] = ["type": "article", "id": UUID().uuidString,
            "title": "Ask: \(String(query.query.prefix(64)))", "description": "Tap to send",
            "input_message_content": ["message_text": "💬 \(query.query)\n\n⏳ Generating..."],
            "reply_markup": ["inline_keyboard": [[["text": "⏳ Generating...", "callback_data": "noop"]]]]]
        await answerInlineQuery(token: token, queryId: query.id, results: [r])
    }

    private func handleChosenInlineResult(token: String, result: TGChosenInlineResult) async {
        guard let inlineMessageId = result.inlineMessageId, isUserApproved(userId: result.userId) else { return }
        let text = result.query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        // Log to user's inline chat
        let ids = chatID(forUser: result.userId, username: result.displayName, chatId: result.userId, threadId: nil, isInline: true)
        store?.appendMessage(projectID: ids.projectID, chatID: ids.chatID, message: Message(role: "user", content: text))

        let payload: [[String: Any]] = [["role": "user", "content": text]]
        let response = await streamOllama(payload: payload, think: false) { chunk in
            await self.editInlineMessage(token: token, inlineMessageId: inlineMessageId, text: "💬 \(text)\n\n\(chunk)")
        }
        let rawContent = response?.content ?? "No response from model."
        let finalText = OllamaService.stripLangTag(rawContent)
        await editInlineMessage(token: token, inlineMessageId: inlineMessageId, text: "💬 \(text)\n\n\(finalText)", removeKeyboard: true)

        // Log response
        store?.appendMessage(projectID: ids.projectID, chatID: ids.chatID, message: Message(role: "assistant", content: finalText))
        store?.save()
    }

    // MARK: - Voice

    private func handleVoice(token: String, chatId: Int64, threadId: Int64?, userId: Int64, username: String, fileId: String, duration: Int) async {
        guard await checkAuth(token: token, chatId: chatId, threadId: threadId, userId: userId, username: username) else { return }
        guard let audio, audio.isModelLoaded else {
            await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Voice model not loaded yet."); return
        }
        await sendChatAction(token: token, chatId: chatId, threadId: threadId)
        guard let wavURL = await downloadFile(token: token, fileId: fileId) else {
            await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Failed to process voice. Install ffmpeg."); return
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let key = convKey(chatId, threadId)

        // Whisper-only mode: transcribe and return text (with diarization)
        if whisperMode.contains(key) {
            let transcription = await audio.transcribeFileWithSpeakers(at: wavURL)
            if let text = transcription, !text.isEmpty {
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "🎙 Transcription:\n\n\(text)")
            } else {
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Could not transcribe voice.")
            }
            return
        }

        // Normal mode: transcribe and send to AI
        guard let transcription = await audio.transcribeFile(at: wavURL), !transcription.isEmpty else {
            await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Could not transcribe voice."); return
        }
        await handleIncoming(token: token, chatId: chatId, threadId: threadId, userId: userId, username: username, text: transcription, isVoice: true)
    }

    // MARK: - Photo

    private func handlePhoto(token: String, chatId: Int64, threadId: Int64?, userId: Int64, username: String, fileId: String, caption: String?) async {
        guard await checkAuth(token: token, chatId: chatId, threadId: threadId, userId: userId, username: username) else { return }
        await sendChatAction(token: token, chatId: chatId, threadId: threadId)
        guard let imageBase64 = await downloadFileAsBase64(token: token, fileId: fileId) else {
            await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Failed to download image."); return
        }
        let text = (caption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? caption! : "What's in this image?"
        await handleIncoming(token: token, chatId: chatId, threadId: threadId, userId: userId, username: username, text: text, imageBase64: imageBase64)
    }

    // MARK: - Main Message Handler

    private func handleIncoming(token: String, chatId: Int64, threadId: Int64? = nil, userId: Int64, username: String, text: String, isVoice: Bool = false, imageBase64: String? = nil) async {
        guard await checkAuth(token: token, chatId: chatId, threadId: threadId, userId: userId, username: username) else { return }

        let key = convKey(chatId, threadId)

        // Commands
        if text == "/clear" {
            let ids = chatID(forUser: userId, username: username, chatId: chatId, threadId: threadId)
            store?.clearChat(projectID: ids.projectID, chatID: ids.chatID)
            await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Conversation cleared.")
            return
        }
        if text == "/start" {
            await sendMessage(token: token, chatId: chatId, threadId: threadId,
                text: "Hello! Commands:\n/thinking — toggle thinking\n/web — toggle web search\n/whisper — transcribe-only mode (no AI reply)\n/cancel — cancel generation\n/clear — clear chat")
            return
        }
        if text.hasPrefix("/thinking") {
            if thinkingEnabled.contains(key) { thinkingEnabled.remove(key)
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "🧠 Thinking: OFF")
            } else { thinkingEnabled.insert(key)
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "🧠 Thinking: ON")
            }; return
        }
        if text.hasPrefix("/web") {
            if webSearchEnabled.contains(key) { webSearchEnabled.remove(key)
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "🌐 Web search: OFF")
            } else { webSearchEnabled.insert(key)
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "🌐 Web search: ON")
            }; return
        }
        if text.hasPrefix("/whisper") {
            let isOn = whisperMode.contains(key)
            if isOn {
                whisperMode.remove(key)
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "🎙 Whisper mode: OFF\nVoice messages will be answered by AI.")
            } else {
                whisperMode.insert(key)
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "🎙 Whisper mode: ON\nVoice messages will be transcribed only (with speaker detection).\nNo AI response.")
            }
            return
        }
        if text == "/cancel" {
            if let task = activeTasks[key] { task.cancel(); activeTasks.removeValue(forKey: key)
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "⚠️ Generation cancelled.")
            } else {
                await sendMessage(token: token, chatId: chatId, threadId: threadId, text: "Nothing to cancel.")
            }; return
        }

        // Get/create chat in user's project
        let ids = chatID(forUser: userId, username: username, chatId: chatId, threadId: threadId)

        // Log user message to store
        let userMsg = Message(role: "user", content: text, imageBase64: imageBase64)
        store?.appendMessage(projectID: ids.projectID, chatID: ids.chatID, message: userMsg)
        autoTitle(projectID: ids.projectID, chatID: ids.chatID, text: text)

        let think = thinkingEnabled.contains(key)
        let webSearch = webSearchEnabled.contains(key)

        var placeholder = "⏳ Generating..."
        if webSearch { placeholder = "🌐 Searching..." }
        else if think { placeholder = "🧠 Thinking..." }
        if imageBase64 != nil { placeholder = "🖼 Analyzing image..." }

        guard let messageId = await sendMessage(token: token, chatId: chatId, threadId: threadId, text: placeholder) else { return }

        // Build payload from stored chat messages
        var payload: [[String: Any]] = []
        if let pIdx = store?.projects.firstIndex(where: { $0.id == ids.projectID }),
           let cIdx = store?.projects[pIdx].chats.firstIndex(where: { $0.id == ids.chatID }) {
            for msg in store!.projects[pIdx].chats[cIdx].messages {
                var entry: [String: Any] = ["role": msg.role, "content": msg.content]
                if let img = msg.imageBase64, !img.isEmpty { entry["images"] = [img] }
                payload.append(entry)
            }
        }

        // Create cancellable task
        let genTask = Task {
            let result = await self.streamOllama(payload: payload, think: think, webSearch: webSearch, searchQuery: text) { chunk in
                await self.editMessage(token: token, chatId: chatId, messageId: messageId, text: chunk)
            }

            let rawContent = result?.content ?? "No response from model."
            let content = OllamaService.stripLangTag(rawContent)
            let thinking = result?.thinking ?? ""

            // Log assistant response
            self.store?.appendMessage(projectID: ids.projectID, chatID: ids.chatID, message: Message(role: "assistant", content: content, thinking: thinking))
            self.store?.save()

            let finalDisplay = think && !thinking.isEmpty ? "💭 Thinking:\n\(thinking)\n\n\(content)" : content
            await self.editMessage(token: token, chatId: chatId, messageId: messageId, text: finalDisplay)

            if finalDisplay.count > 4000 {
                let chunks = self.splitMessage(finalDisplay, maxLength: 4000)
                await self.editMessage(token: token, chatId: chatId, messageId: messageId, text: chunks[0])
                for chunk in chunks.dropFirst() {
                    await self.sendMessage(token: token, chatId: chatId, threadId: threadId, text: chunk)
                }
            }
        }

        activeTasks[key] = genTask
        await genTask.value
        activeTasks.removeValue(forKey: key)
    }

    private func splitMessage(_ text: String, maxLength: Int) -> [String] {
        if text.count <= maxLength { return [text] }
        var chunks: [String] = []; var current = text
        while !current.isEmpty {
            if current.count <= maxLength { chunks.append(current); break }
            let prefix = String(current.prefix(maxLength))
            if let nl = prefix.lastIndex(of: "\n") {
                chunks.append(String(current[..<nl]))
                current = String(current[current.index(after: nl)...])
            } else { chunks.append(prefix); current = String(current.dropFirst(maxLength)) }
        }
        return chunks
    }

    // MARK: - Markdown → Telegram HTML

    static func markdownToTelegramHTML(_ text: String) -> String {
        var r = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let patterns: [(String, String, NSRegularExpression.Options)] = [
            ("```(\\w*)\\n([\\s\\S]*?)```", "<pre><code class=\"language-$1\">$2</code></pre>", .dotMatchesLineSeparators),
            ("`([^`]+)`", "<code>$1</code>", []),
            ("\\*\\*(.+?)\\*\\*", "<b>$1</b>", .dotMatchesLineSeparators),
            ("(?<!\\w)\\*([^*]+?)\\*(?!\\w)", "<i>$1</i>", []),
            ("(?<!\\w)_([^_]+?)_(?!\\w)", "<i>$1</i>", []),
            ("~~(.+?)~~", "<s>$1</s>", []),
            ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>", []),
            ("(?m)^&gt; (.+)$", "<blockquote>$1</blockquote>", []),
            ("(?m)^#{1,6} (.+)$", "<b>$1</b>", []),
        ]
        for (pattern, template, opts) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: opts) {
                r = regex.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: template)
            }
        }
        return r.replacingOccurrences(of: " class=\"language-\"", with: "")
    }
}
