import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ProjectStore
    @Binding var selectedProjectID: UUID?
    @Binding var selectedChatID: UUID?
    @Binding var showInstructions: Bool

    var body: some View {
        List(selection: $selectedChatID) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(project.chats) { chat in
                        ChatRow(
                            chat: chat,
                            projectID: project.id,
                            store: store,
                            selectedProjectID: $selectedProjectID
                        )
                        .tag(chat.id)
                    }
                } header: {
                    ProjectHeader(
                        project: project,
                        store: store,
                        selectedProjectID: $selectedProjectID,
                        selectedChatID: $selectedChatID,
                        showInstructions: $showInstructions
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: addProject) {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                .help("New Project")
            }
        }
        .onChange(of: selectedChatID) { _, newValue in
            if let chatID = newValue {
                // Find which project owns this chat
                for project in store.projects {
                    if project.chats.contains(where: { $0.id == chatID }) {
                        selectedProjectID = project.id
                        showInstructions = false
                        break
                    }
                }
            }
        }
    }

    private func addProject() {
        let project = store.addProject()
        selectedProjectID = project.id
        selectedChatID = project.chats.first?.id
    }
}

struct ProjectHeader: View {
    let project: Project
    @ObservedObject var store: ProjectStore
    @Binding var selectedProjectID: UUID?
    @Binding var selectedChatID: UUID?
    @Binding var showInstructions: Bool
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        HStack {
            if isRenaming {
                TextField("Name", text: $renameText, onCommit: {
                    store.renameProject(projectID: project.id, name: renameText)
                    isRenaming = false
                })
                .textFieldStyle(.plain)
                .font(.headline)
            } else {
                Text(project.name)
                    .font(.headline)
            }

            Spacer()

            Button(action: {
                selectedProjectID = project.id
                showInstructions = true
                selectedChatID = nil
            }) {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Project Instructions")

            Button(action: addChat) {
                Image(systemName: "plus.bubble")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("New Chat")
        }
        .contextMenu {
            Button("Rename") {
                renameText = project.name
                isRenaming = true
            }
            Button("New Chat") { addChat() }
            Divider()
            Button("Delete Project", role: .destructive) {
                store.deleteProject(project.id)
                if selectedProjectID == project.id {
                    selectedProjectID = store.projects.first?.id
                    selectedChatID = store.projects.first?.chats.first?.id
                }
            }
            .disabled(store.projects.count <= 1)
        }
    }

    private func addChat() {
        if let chat = store.addChat(projectID: project.id) {
            selectedProjectID = project.id
            selectedChatID = chat.id
            showInstructions = false
        }
    }
}

struct ChatRow: View {
    let chat: Chat
    let projectID: UUID
    @ObservedObject var store: ProjectStore
    @Binding var selectedProjectID: UUID?
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        Group {
            if isRenaming {
                TextField("Title", text: $renameText, onCommit: {
                    store.renameChat(projectID: projectID, chatID: chat.id, title: renameText)
                    isRenaming = false
                })
                .textFieldStyle(.plain)
            } else {
                HStack {
                    Image(systemName: "bubble.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(chat.title)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("Rename") {
                renameText = chat.title
                isRenaming = true
            }
            Button("Delete Chat", role: .destructive) {
                store.deleteChat(projectID: projectID, chatID: chat.id)
            }
        }
    }
}
