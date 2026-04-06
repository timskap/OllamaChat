import SwiftUI

struct SettingsView: View {
    @ObservedObject var audio: AudioService
    @ObservedObject var tts: TTSService
    @ObservedObject var telegram: TelegramService
    @ObservedObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var botTokenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Picker("", selection: $selectedTab) {
                Text("Models").tag(0)
                HStack {
                    Text("Telegram")
                    if !telegram.pendingUsers.isEmpty {
                        Circle().fill(.red).frame(width: 8, height: 8)
                    }
                }.tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            Divider().padding(.top, 12)

            if selectedTab == 0 {
                modelsTab
            } else {
                telegramTab
            }
        }
        .frame(width: 500, height: 550)
        .onAppear {
            // Load bot token from first project with telegram configured
            if let project = store.projects.first(where: { !$0.telegram.botToken.isEmpty && !$0.telegram.botToken.hasPrefix("tg_user_") }) {
                botTokenDraft = project.telegram.botToken
            }
        }
    }

    // MARK: - Models Tab

    private var modelsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // STT
                ModelCard(
                    title: "Whisper Large v3 Turbo",
                    subtitle: "Speech-to-Text · Russian, English, 100+ languages · ~630 MB",
                    icon: "mic.fill", color: .blue,
                    isLoaded: audio.isModelLoaded, isDownloading: audio.isDownloading,
                    progress: audio.downloadProgress,
                    downloadedMB: audio.downloadedMB, totalMB: audio.totalMB,
                    statusText: audio.statusText,
                    isCached: audio.isModelCached,
                    onDownload: { Task { await audio.loadModel() } }
                )

                // TTS Engine Selection
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2.fill").font(.title3).foregroundStyle(.orange).frame(width: 28)
                        Text("Text-to-Speech").font(.headline)
                        Spacer()
                    }

                    Picker("Engine", selection: $tts.selectedEngine) {
                        ForEach(TTSEngine.allCases, id: \.self) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)

                    if tts.selectedEngine == .apple {
                        // Apple voice picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Voice").font(.subheadline.bold())

                            Picker("Voice", selection: $tts.appleVoiceID) {
                                Text("System Default").tag("")
                                ForEach(TTSService.availableAppleVoices, id: \.id) { voice in
                                    Text("\(voice.name) (\(voice.lang))").tag(voice.id)
                                }
                            }

                            HStack {
                                Text("Speed").font(.subheadline)
                                Slider(value: $tts.appleRate, in: 0.1...0.75)
                                Text(String(format: "%.2f", tts.appleRate))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 35)
                            }

                            Button("Test Voice") {
                                tts.speak("Hello! This is a test of the selected voice.")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(tts.isSpeaking)
                        }

                        InfoCard(title: "Apple Speech", subtitle: "Built-in · No download · Many voices", icon: "apple.logo", color: .secondary, badge: "Ready")
                    } else {
                        // Qwen3 TTS
                        ModelCard(
                            title: "Qwen3-TTS 0.6B",
                            subtitle: "Natural AI voice · ~600 MB",
                            icon: "waveform", color: .orange,
                            isLoaded: tts.isModelLoaded, isDownloading: tts.isDownloading,
                            progress: 0, downloadedMB: 0, totalMB: 0,
                            statusText: tts.statusText,
                            isCached: tts.isModelCached,
                            onDownload: { Task { await tts.loadQwen3Model() } }
                        )
                    }
                }
                .padding(16)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                InfoCard(title: "Apple Sound Classifier", subtitle: "300+ sound categories · Built-in, no download", icon: "ear", color: .green, badge: "Ready")
                InfoCard(title: "Ollama — Gemma 4 26B", subtitle: "Chat model · Managed by Ollama separately", icon: "brain.head.profile", color: .purple, badge: "External")
            }
            .padding(20)
        }
    }

    // MARK: - Telegram Tab

    private var telegramTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Status
                HStack {
                    Image(systemName: "paperplane")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text("Telegram Bot")
                        .font(.headline)
                    Spacer()
                    if telegram.isRunning {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(telegram.statusText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                // Bot token
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bot Token")
                        .font(.subheadline.bold())
                    HStack {
                        SecureField("Paste token from @BotFather", text: $botTokenDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") { saveBotToken() }
                            .buttonStyle(.borderedProminent)
                            .disabled(botTokenDraft.isEmpty)
                    }
                }

                // Enable/disable
                if let project = botProject, !project.telegram.botToken.isEmpty {
                    Toggle("Bot enabled", isOn: Binding(
                        get: { project.telegram.enabled },
                        set: { toggleBot(enabled: $0) }
                    ))

                    Divider()

                    // Pending users
                    let pending = telegram.pendingUsers
                    if !pending.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Pending Approval", systemImage: "person.badge.clock")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            ForEach(pending) { user in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(user.username).font(.body.bold())
                                        Text("ID: \(user.id)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Approve") {
                                        telegram.approveUser(userId: user.id, projectID: user.projectID)
                                    }.buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                                    Button("Deny") {
                                        telegram.denyUser(userId: user.id, projectID: user.projectID)
                                    }.buttonStyle(.bordered).tint(.red).controlSize(.small)
                                }
                                .padding(8)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    // Approved users
                    let approved = project.telegram.users.filter { $0.approved }
                    if !approved.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Approved Users", systemImage: "person.badge.shield.checkmark")
                                .font(.subheadline.bold())
                            ForEach(approved) { user in
                                HStack {
                                    Text(user.username).font(.body)
                                    Text("(\(user.id))").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(role: .destructive) {
                                        telegram.removeUser(userId: user.id, projectID: project.id)
                                    } label: {
                                        Image(systemName: "person.badge.minus")
                                    }.buttonStyle(.borderless)
                                }
                                .padding(6)
                                .background(Color.secondary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    if pending.isEmpty && approved.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.slash").font(.title).foregroundStyle(.tertiary)
                            Text("No users yet. When someone writes to the bot, they'll appear here.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private var botProject: Project? {
        store.projects.first(where: { !$0.telegram.botToken.isEmpty && !$0.telegram.botToken.hasPrefix("tg_user_") })
    }

    private func saveBotToken() {
        // Find or create the bot project (first non-tg_user project)
        let projectID: UUID
        if let existing = botProject {
            projectID = existing.id
        } else if let first = store.projects.first(where: { !$0.telegram.botToken.hasPrefix("tg_user_") }) {
            projectID = first.id
        } else {
            let p = store.addProject(name: "Telegram Bot")
            projectID = p.id
        }
        guard let pIdx = store.projects.firstIndex(where: { $0.id == projectID }) else { return }
        store.projects[pIdx].telegram.botToken = botTokenDraft
        store.save()
    }

    private func toggleBot(enabled: Bool) {
        guard let project = botProject,
              let pIdx = store.projects.firstIndex(where: { $0.id == project.id }) else { return }
        store.projects[pIdx].telegram.enabled = enabled
        store.save()
        if enabled {
            telegram.start(projectID: project.id, store: store, audio: audio)
        } else {
            telegram.stop()
        }
    }
}

// MARK: - Reusable Cards

struct ModelCard: View {
    let title: String; let subtitle: String; let icon: String; let color: Color
    let isLoaded: Bool; let isDownloading: Bool; let progress: Double
    let downloadedMB: Int64; let totalMB: Int64; let statusText: String
    var isCached: Bool = false
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoaded {
                    Text("Ready").font(.caption.bold()).foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.green.opacity(0.1)).clipShape(Capsule())
                } else if isDownloading {
                    ProgressView().controlSize(.small)
                } else if isCached {
                    HStack(spacing: 6) {
                        Text("Cached").font(.caption.bold()).foregroundStyle(.blue)
                        Button(action: onDownload) { Text("Load").font(.caption.bold()) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.blue.opacity(0.08)).clipShape(Capsule())
                } else {
                    Button(action: onDownload) { Text("Download").font(.caption.bold()) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            if isDownloading {
                if totalMB > 0 {
                    ProgressView(value: progress)
                    Text("\(downloadedMB) / \(totalMB) MB").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else if !statusText.isEmpty {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(statusText).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !isDownloading && !isLoaded && !statusText.isEmpty {
                Text(statusText).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16).background(Color.secondary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct InfoCard: View {
    let title: String; let subtitle: String; let icon: String; let color: Color; let badge: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge).font(.caption.bold()).foregroundStyle(badge == "Ready" ? .green : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background((badge == "Ready" ? Color.green : Color.secondary).opacity(0.1)).clipShape(Capsule())
        }
        .padding(16).background(Color.secondary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
