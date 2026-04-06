import Foundation

struct Message: Identifiable, Codable, Equatable {
    var id = UUID()
    let role: String
    var content: String
    var thinking: String
    var imageBase64: String?

    init(role: String, content: String, thinking: String = "", imageBase64: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.thinking = thinking
        self.imageBase64 = imageBase64
    }
}

struct Chat: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var messages: [Message]
    var createdAt: Date

    init(title: String = "New Chat", messages: [Message] = [], createdAt: Date = .now) {
        self.id = UUID()
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
    }
}

struct TelegramUser: Identifiable, Codable, Equatable {
    var id: Int64          // Telegram user ID
    var username: String   // @username or first_name
    var approved: Bool
    var requestedAt: Date

    init(id: Int64, username: String, approved: Bool = false, requestedAt: Date = .now) {
        self.id = id
        self.username = username
        self.approved = approved
        self.requestedAt = requestedAt
    }
}

struct TelegramConfig: Codable, Equatable {
    var botToken: String
    var enabled: Bool
    var users: [TelegramUser]

    init(botToken: String = "", enabled: Bool = false, users: [TelegramUser] = []) {
        self.botToken = botToken
        self.enabled = enabled
        self.users = users
    }
}

struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var instructions: String
    var chats: [Chat]
    var telegram: TelegramConfig
    var createdAt: Date

    init(name: String = "New Project", instructions: String = "", chats: [Chat] = [], telegram: TelegramConfig = TelegramConfig(), createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.instructions = instructions
        self.chats = chats
        self.telegram = telegram
        self.createdAt = createdAt
    }
}
