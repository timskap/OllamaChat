import AppKit
import MarkdownUI
import SwiftUI

struct ChatView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var ollama: OllamaService
    @ObservedObject var audio: AudioService
    @ObservedObject var soundClassifier: SoundClassifierService
    @ObservedObject var tts: TTSService
    let projectID: UUID
    let chatID: UUID

    @State private var input = ""
    @State private var thinkingEnabled = true
    @State private var webSearchEnabled = false
    @State private var attachedImage: NSImage?
    @State private var attachedImageBase64: String?
    @State private var autoSpeak = false
    @FocusState private var inputFocused: Bool

    private var messages: [Message] {
        guard let pIdx = store.projects.firstIndex(where: { $0.id == projectID }),
              let cIdx = store.projects[pIdx].chats.firstIndex(where: { $0.id == chatID }) else { return [] }
        return store.projects[pIdx].chats[cIdx].messages
    }

    private var instructions: String {
        store.projects.first { $0.id == projectID }?.instructions ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                isThinking: ollama.isThinking && message.id == messages.last?.id
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.last?.content) {
                    scrollToBottom(proxy)
                }
                .onChange(of: messages.last?.thinking) {
                    scrollToBottom(proxy)
                }
            }

            // Composer area
            VStack(spacing: 0) {
                Divider()

                // Image preview
                if let img = attachedImage {
                    HStack(spacing: 8) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Button(action: { attachedImage = nil; attachedImageBase64 = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // Recording overlay
                if audio.isRecording {
                    RecordingBar(audio: audio, onStop: {
                        Task {
                            if let text = await audio.stopRecording() {
                                input += (input.isEmpty ? "" : " ") + text
                            }
                        }
                    }, onCancel: {
                        audio.cancelRecording()
                    })
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                } else {
                    // Text input with inline action buttons
                    VStack(spacing: 0) {
                        HStack(alignment: .bottom, spacing: 0) {
                            // Text editor
                            ExpandingTextEditor(text: $input, onSubmit: sendMessage)
                                .disabled(ollama.isGenerating)
                                .padding(.leading, 12)
                                .padding(.vertical, 8)

                            // Send or Stop button
                            if ollama.isGenerating {
                                Button(action: { ollama.cancelGeneration() }) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Stop generating")
                                .padding(.trailing, 10)
                                .padding(.bottom, 10)
                            } else {
                                Button(action: sendMessage) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(
                                            (input.trimmingCharacters(in: .whitespaces).isEmpty && attachedImage == nil)
                                            ? Color.secondary.opacity(0.4) : Color.accentColor
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty && attachedImage == nil)
                                .keyboardShortcut(.return, modifiers: .command)
                                .help("Send (⌘↵)")
                                .padding(.trailing, 10)
                                .padding(.bottom, 10)
                            }
                        }

                        // Bottom toolbar — action buttons + toggles
                        HStack(spacing: 2) {
                            // Action buttons
                            composerButton(icon: "photo", active: attachedImage != nil, color: .blue) { pickImage() }
                                .help("Attach image")
                                .disabled(ollama.isGenerating)

                            composerButton(icon: "mic", active: false, color: .primary) { audio.startRecording() }
                                .help("Voice input")
                                .disabled(!audio.isModelLoaded || audio.isTranscribing || ollama.isGenerating)

                            Divider().frame(height: 16).padding(.horizontal, 4)

                            // Feature toggles
                            composerToggle(icon: "brain", label: "Think", active: thinkingEnabled, color: .purple) {
                                thinkingEnabled.toggle()
                            }
                            composerToggle(icon: "globe", label: "Web", active: webSearchEnabled, color: .blue) {
                                webSearchEnabled.toggle()
                            }
                            composerToggle(icon: "ear", label: soundClassifier.isAutoRecording ? "Rec" : "Listen",
                                          active: soundClassifier.isListening, color: .green,
                                          badge: soundClassifier.isAutoRecording ? .red : nil) {
                                toggleSoundClassifier()
                            }
                            composerToggle(icon: autoSpeak ? "speaker.wave.2.fill" : "speaker.wave.2",
                                          label: "Speak", active: autoSpeak, color: .orange,
                                          badge: tts.isSpeaking ? .orange : nil) {
                                autoSpeak.toggle()
                                if autoSpeak && !tts.isModelLoaded { Task { await tts.loadModel() } }
                            }

                            Spacer()

                            // Status indicator
                            if ollama.isGenerating {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text(ollama.isSearching ? "Searching..." : ollama.isThinking ? "Thinking..." : "Generating...")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.trailing, 4)
                            }

                            // Clear chat
                            composerButton(icon: "trash", active: false, color: .secondary) {
                                store.clearChat(projectID: projectID, chatID: chatID)
                            }
                            .help("Clear chat")
                            .disabled(ollama.isGenerating)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
            }
            .background(.bar)
        }
        .onAppear {
            inputFocused = true
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
        .onChange(of: ollama.isGenerating) { wasGenerating, isGenerating in
            // Auto-speak the last assistant message when generation finishes
            if wasGenerating && !isGenerating && autoSpeak {
                if let lastMsg = messages.last, lastMsg.role == "assistant", !lastMsg.content.isEmpty {
                    let lang = ollama.detectedLanguage.isEmpty ? nil : ollama.detectedLanguage
                    tts.speak(lastMsg.content, language: lang)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let lastID = messages.last?.id {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty || attachedImage != nil else { return }
        let messageText = text.isEmpty ? "What's in this image?" : text
        let imgBase64 = attachedImageBase64
        input = ""
        attachedImage = nil
        attachedImageBase64 = nil
        Task {
            await ollama.send(
                messageText,
                imageBase64: imgBase64,
                instructions: instructions,
                thinkingEnabled: thinkingEnabled,
                webSearchEnabled: webSearchEnabled,
                store: store,
                projectID: projectID,
                chatID: chatID
            )
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url") { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { loadImage(from: url) }
                }
                return
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async { setImage(image) }
                }
                return
            }
        }
    }

    private func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        setImage(image)
    }

    private func setImage(_ image: NSImage) {
        attachedImage = image
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        attachedImageBase64 = jpeg.base64EncodedString()
    }

    // MARK: - Composer Button Helpers

    private func composerButton(icon: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: active ? "\(icon).fill" : icon)
                .font(.system(size: 13))
                .foregroundStyle(active ? color : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func composerToggle(icon: String, label: String, active: Bool, color: Color, badge: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11))
                if let badge {
                    Circle().fill(badge).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(active ? color : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(active ? color.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private func toggleSoundClassifier() {
        if soundClassifier.isListening {
            soundClassifier.stop()
        } else {
            soundClassifier.onSpeechTranscribed = { [self] text in
                guard !ollama.isGenerating else { return }
                // Auto-send transcribed speech
                Task {
                    await ollama.send(
                        text,
                        instructions: instructions,
                        thinkingEnabled: thinkingEnabled,
                        webSearchEnabled: webSearchEnabled,
                        store: store,
                        projectID: projectID,
                        chatID: chatID
                    )
                }
            }
            soundClassifier.start(audioService: audio)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    var isThinking: Bool = false

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(isUser ? "You" : "Gemma")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isUser && !message.thinking.isEmpty {
                    ThinkingBlock(text: message.thinking, isStreaming: isThinking)
                }

                if !isUser && isThinking && message.content.isEmpty && message.thinking.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Image thumbnail
                if let imgBase64 = message.imageBase64, !imgBase64.isEmpty,
                   let imgData = Data(base64Encoded: imgBase64),
                   let nsImage = NSImage(data: imgData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if !message.content.isEmpty || isUser {
                    if isUser {
                        Text(message.content.isEmpty ? "..." : message.content)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Markdown(message.content)
                            .markdownTheme(.chat)
                            .textSelection(.enabled)
                            .padding(10)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Thinking Block

struct ThinkingBlock: View {
    let text: String
    var isStreaming: Bool = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)

                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Text(isStreaming ? "Thinking..." : "Thought process")
                        .font(.caption)

                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Expanding Text Editor

struct ExpandingTextEditor: View {
    @Binding var text: String
    var onSubmit: () -> Void

    @State private var textHeight: CGFloat = 36

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 160
    private let font: NSFont = .systemFont(ofSize: 14)

    var body: some View {
        ExpandingNSTextView(text: $text, calculatedHeight: $textHeight, font: font, onSubmit: onSubmit)
            .frame(height: min(max(textHeight, minHeight), maxHeight))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }
}

private struct ExpandingNSTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    var font: NSFont
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Initial height calc
        DispatchQueue.main.async {
            context.coordinator.recalcHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalcHeight()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ExpandingNSTextView
        weak var textView: NSTextView?

        init(_ parent: ExpandingNSTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalcHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                } else {
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }

        func recalcHeight() {
            guard let textView, let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let usedRect = layoutManager.usedRect(for: container)
            let inset = textView.textContainerInset
            let newHeight = usedRect.height + inset.height * 2 + 2
            DispatchQueue.main.async {
                self.parent.calculatedHeight = newHeight
            }
        }
    }
}

// MARK: - Recording Bar

struct RecordingBar: View {
    @ObservedObject var audio: AudioService
    let onStop: () -> Void
    let onCancel: () -> Void

    @State private var elapsed: TimeInterval = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            // Cancel
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel recording")

            // Pulsing dot
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .scaleEffect(pulseScale)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulseScale)

            // Timer
            Text(formatTime(elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)

            Spacer()

            Text("Recording...")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            // Stop & transcribe
            Button(action: onStop) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                    Text("Done")
                        .font(.callout.bold())
                }
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Stop and transcribe")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            elapsed = 0
            pulseScale = 1.3
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                elapsed += 0.1
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        let tenths = Int((t - Double(Int(t))) * 10)
        return String(format: "%d:%02d.%d", mins, secs, tenths)
    }
}

// MARK: - Chat Markdown Theme

extension Theme {
    static let chat = Theme()
        .text {
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.chatCodeBg)
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.3))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.15))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 2)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: 0, bottom: 8)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .relativeFrame(width: .em(0.15))
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.horizontal, length: .em(0.6))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(10)
            }
            .background(Color.chatCodeBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 4, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.15))
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: .secondary.opacity(0.2)))
                .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
        .thematicBreak {
            Divider()
                .markdownMargin(top: 8, bottom: 8)
        }
}

extension Color {
    static let chatCodeBg: Color = {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(white: 1, alpha: 0.08)
            } else {
                return NSColor(white: 0, alpha: 0.05)
            }
        })
        #else
        return Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(white: 1, alpha: 0.08)
            } else {
                return UIColor(white: 0, alpha: 0.05)
            }
        })
        #endif
    }()
}

