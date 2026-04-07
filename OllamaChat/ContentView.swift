import SwiftUI

struct ContentView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var ollama = OllamaService()
    @StateObject private var audio = AudioService()
    @StateObject private var soundClassifier = SoundClassifierService()
    @StateObject private var tts = TTSService()
    @StateObject private var telegram = TelegramService()

    @StateObject private var queueMonitor = QueueMonitor.shared

    @State private var selectedProjectID: UUID?
    @State private var selectedChatID: UUID?
    @State private var showInstructions = false
    @State private var showSettings = false
    @State private var showQueue = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                selectedProjectID: $selectedProjectID,
                selectedChatID: $selectedChatID,
                showInstructions: $showInstructions
            )
        } detail: {
            if showInstructions, let projectID = selectedProjectID {
                InstructionsView(store: store, projectID: projectID)
            } else if let projectID = selectedProjectID, let chatID = selectedChatID {
                ChatView(store: store, ollama: ollama, audio: audio, soundClassifier: soundClassifier, tts: tts, projectID: projectID, chatID: chatID)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a chat or create a new one")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button(action: { showQueue = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.clipboard")
                            if !queueMonitor.items.isEmpty {
                                Text("\(queueMonitor.items.count)")
                                    .font(.caption2.bold().monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.orange))
                            }
                        }
                    }
                    .help("Processing Queue")

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(audio: audio, tts: tts, ollama: ollama, telegram: telegram, store: store)
        }
        .sheet(isPresented: $showQueue) {
            QueueMonitorView(monitor: queueMonitor)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            // Auto-load Whisper if cached
            if audio.isModelCached && !audio.isModelLoaded {
                Task { await audio.loadModel() }
            }

            if selectedProjectID == nil, let first = store.projects.first {
                selectedProjectID = first.id
                selectedChatID = first.chats.first?.id
            }
            // Auto-start telegram bots
            for project in store.projects {
                if project.telegram.enabled && !project.telegram.botToken.isEmpty && !project.telegram.botToken.hasPrefix("tg_user_") {
                    telegram.start(projectID: project.id, store: store, audio: audio)
                }
            }
        }
        .badge(telegram.pendingUsers.count)
    }
}

#Preview {
    ContentView()
}
