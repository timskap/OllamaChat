import Foundation
import SwiftUI

@MainActor
class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OllamaChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }()

    init() {
        load()
        if projects.isEmpty {
            let defaultProject = Project(name: "Default", instructions: "", chats: [Chat(title: "New Chat")])
            projects.append(defaultProject)
            save()
        }
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    // MARK: - Projects

    func addProject(name: String = "New Project") -> Project {
        let project = Project(name: name, chats: [Chat(title: "New Chat")])
        projects.append(project)
        save()
        return project
    }

    func deleteProject(_ projectID: UUID) {
        projects.removeAll { $0.id == projectID }
        save()
    }

    func updateInstructions(projectID: UUID, instructions: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].instructions = instructions
        save()
    }

    func renameProject(projectID: UUID, name: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].name = name
        save()
    }

    // MARK: - Chats

    func addChat(projectID: UUID, title: String = "New Chat") -> Chat? {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let chat = Chat(title: title)
        projects[idx].chats.append(chat)
        save()
        return chat
    }

    func deleteChat(projectID: UUID, chatID: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].chats.removeAll { $0.id == chatID }
        save()
    }

    func renameChat(projectID: UUID, chatID: UUID, title: String) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let cIdx = projects[pIdx].chats.firstIndex(where: { $0.id == chatID }) else { return }
        projects[pIdx].chats[cIdx].title = title
        save()
    }

    // MARK: - Messages

    func appendMessage(projectID: UUID, chatID: UUID, message: Message) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let cIdx = projects[pIdx].chats.firstIndex(where: { $0.id == chatID }) else { return }
        projects[pIdx].chats[cIdx].messages.append(message)
        save()
    }

    func updateLastMessage(projectID: UUID, chatID: UUID, content: String? = nil, thinking: String? = nil) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let cIdx = projects[pIdx].chats.firstIndex(where: { $0.id == chatID }),
              var last = projects[pIdx].chats[cIdx].messages.last else { return }
        if let content { last.content = content }
        if let thinking { last.thinking = thinking }
        let mIdx = projects[pIdx].chats[cIdx].messages.count - 1
        projects[pIdx].chats[cIdx].messages[mIdx] = last
    }

    func saveAfterStreaming() {
        save()
    }

    func clearChat(projectID: UUID, chatID: UUID) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let cIdx = projects[pIdx].chats.firstIndex(where: { $0.id == chatID }) else { return }
        projects[pIdx].chats[cIdx].messages.removeAll()
        save()
    }

    // Auto-title from first user message
    func autoTitleIfNeeded(projectID: UUID, chatID: UUID) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }),
              let cIdx = projects[pIdx].chats.firstIndex(where: { $0.id == chatID }) else { return }
        let chat = projects[pIdx].chats[cIdx]
        if chat.title == "New Chat", let firstUser = chat.messages.first(where: { $0.role == "user" }) {
            let title = String(firstUser.content.prefix(40))
            projects[pIdx].chats[cIdx].title = title.isEmpty ? "New Chat" : title
            save()
        }
    }
}
