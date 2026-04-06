import AVFoundation
import Foundation
import SwiftUI
import TTSKit

enum TTSEngine: String, CaseIterable, Codable {
    case apple = "Apple"
    case qwen3 = "Qwen3-TTS"
}

@MainActor
class TTSService: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isSpeaking = false
    @Published var isDownloading = false
    @Published var statusText = ""
    @Published var selectedEngine: TTSEngine {
        didSet { UserDefaults.standard.set(selectedEngine.rawValue, forKey: "ttsEngine") }
    }
    @Published var appleVoiceID: String {
        didSet { UserDefaults.standard.set(appleVoiceID, forKey: "ttsAppleVoice") }
    }
    @Published var appleRate: Float {
        didSet { UserDefaults.standard.set(appleRate, forKey: "ttsAppleRate") }
    }

    private var ttsKit: TTSKit?
    private var speakTask: Task<Void, Never>?
    private let appleSynth = AVSpeechSynthesizer()

    init() {
        let engine = UserDefaults.standard.string(forKey: "ttsEngine") ?? TTSEngine.apple.rawValue
        self.selectedEngine = TTSEngine(rawValue: engine) ?? .apple
        self.appleVoiceID = UserDefaults.standard.string(forKey: "ttsAppleVoice") ?? ""
        let rate = UserDefaults.standard.float(forKey: "ttsAppleRate")
        self.appleRate = rate > 0 ? rate : AVSpeechUtteranceDefaultSpeechRate
    }

    // MARK: - Qwen3 Model

    func loadQwen3Model() async {
        guard ttsKit == nil else { return }
        do {
            isDownloading = true
            statusText = "Downloading Qwen3-TTS model..."
            let config = TTSKitConfig(model: .qwen3TTS_0_6b)
            let tts = try await TTSKit(config)
            ttsKit = tts
            isModelLoaded = true
            isDownloading = false
            statusText = ""
        } catch {
            isDownloading = false
            statusText = "TTS failed: \(error.localizedDescription)"
        }
    }

    // Keep old API for compatibility
    func loadModel() async {
        await loadQwen3Model()
    }

    // MARK: - Speak

    func speak(_ text: String, language: String? = nil) {
        guard !isSpeaking else { return }

        switch selectedEngine {
        case .apple:
            speakWithApple(text, language: language)
        case .qwen3:
            speakWithQwen3(text)
        }
    }

    func stopSpeaking() {
        speakTask?.cancel()
        speakTask = nil
        appleSynth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Apple TTS

    private func speakWithApple(_ text: String, language: String? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = appleRate

        if let lang = language, !lang.isEmpty {
            // Auto-select voice matching the detected language
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
        } else if !appleVoiceID.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: appleVoiceID) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        isSpeaking = true
        appleSynth.speak(utterance)

        // Monitor completion
        speakTask = Task {
            while appleSynth.isSpeaking {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            await MainActor.run { isSpeaking = false }
        }
    }

    // MARK: - Qwen3 TTS

    private func speakWithQwen3(_ text: String) {
        guard let ttsKit else {
            // Auto-download if not loaded
            Task {
                await loadQwen3Model()
                if ttsKit != nil { speakWithQwen3(text) }
            }
            return
        }

        isSpeaking = true
        speakTask = Task {
            do {
                _ = try await ttsKit.play(text: text, playbackStrategy: .auto)
            } catch {
                if !Task.isCancelled { print("TTS error: \(error)") }
            }
            await MainActor.run { isSpeaking = false }
        }
    }

    // MARK: - Available Apple Voices

    static var availableAppleVoices: [(id: String, name: String, lang: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { $0.language < $1.language }
            .map { (id: $0.identifier, name: $0.name, lang: $0.language) }
    }
}
