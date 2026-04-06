import AVFoundation
import SpeakerKit
import SwiftUI
import WhisperKit

@MainActor
class AudioService: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isModelLoaded = false
    @Published var isModelCached = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedMB: Int64 = 0
    @Published var totalMB: Int64 = 0
    @Published var statusText: String = ""
    @Published var audioLevel: Float = 0

    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempURL: URL?

    private let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

    init() {
        // Check cache on startup (sync, fast — just file existence checks)
        isModelCached = findCachedModel() != nil
    }

    // MARK: - Model Loading

    func loadModel() async {
        guard whisperKit == nil else { return }

        // Check if model is already downloaded locally
        if let localFolder = findCachedModel() {
            statusText = "Loading Whisper model..."
            do {
                let config = WhisperKitConfig(
                    model: modelVariant,
                    modelFolder: localFolder.path,
                    download: false
                )
                whisperKit = try await WhisperKit(config)
                isModelLoaded = true
                statusText = ""
                return
            } catch {
                // Cache corrupted — fall through to re-download
                statusText = "Cache corrupted, re-downloading..."
                clearModelCache()
            }
        }

        // Download model
        await downloadAndLoadModel()
    }

    private func downloadAndLoadModel() async {
        for attempt in 0..<2 {
            do {
                isDownloading = true
                statusText = attempt == 0 ? "Downloading Whisper model..." : "Retrying download..."
                downloadProgress = 0

                let modelFolder = try await WhisperKit.download(
                    variant: modelVariant,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            self.downloadProgress = progress.fractionCompleted
                            self.downloadedMB = progress.completedUnitCount / (1024 * 1024)
                            self.totalMB = progress.totalUnitCount / (1024 * 1024)
                        }
                    }
                )

                isDownloading = false
                statusText = "Loading model (first time may take 1-2 min)..."

                let config = WhisperKitConfig(
                    model: modelVariant,
                    modelFolder: modelFolder.path,
                    download: false
                )
                whisperKit = try await WhisperKit(config)
                isModelLoaded = true
                statusText = ""
                return
            } catch {
                isDownloading = false
                if attempt == 0 {
                    statusText = "Clearing corrupted cache..."
                    clearModelCache()
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    statusText = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Check common HuggingFace Hub cache locations for the model
    private func findCachedModel() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        // HuggingFace Hub caches models in these locations
        let searchPaths = [
            home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml"),
            home.appendingPathComponent(".cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/snapshots"),
        ]

        for basePath in searchPaths {
            let modelPath = basePath.appendingPathComponent(modelVariant)
            if isValidModelFolder(modelPath) {
                return modelPath
            }

            // Also search inside snapshot subdirectories
            if let snapshots = try? fm.contentsOfDirectory(at: basePath, includingPropertiesForKeys: nil) {
                for snapshot in snapshots {
                    let candidate = snapshot.appendingPathComponent(modelVariant)
                    if isValidModelFolder(candidate) {
                        return candidate
                    }
                }
            }
        }

        return nil
    }

    /// Validate that a folder contains the required Whisper model files
    private func isValidModelFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        let requiredFiles = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc", "config.json"]
        return requiredFiles.allSatisfy { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private func clearModelCache() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        let cacheDirs = [
            home.appendingPathComponent(".cache/huggingface/hub"),
            home.appendingPathComponent("Documents/huggingface/models/argmaxinc"),
        ]

        for dir in cacheDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in contents where item.lastPathComponent.contains("whisperkit") || item.lastPathComponent.contains("whisper") {
                try? fm.removeItem(at: item)
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        tempURL = url

        do {
            let wavFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            audioFile = try AVAudioFile(forWriting: url, settings: wavFormat.settings)
            let converter = AVAudioConverter(from: recordingFormat, to: wavFormat)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                guard let self, let converter else { return }

                // Compute RMS level
                if let channelData = buffer.floatChannelData?[0] {
                    let count = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<count { sum += channelData[i] * channelData[i] }
                    let rms = sqrt(sum / Float(max(count, 1)))
                    let level = min(rms * 5, 1.0)
                    Task { @MainActor in self.audioLevel = level }
                }

                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * (16000.0 / recordingFormat.sampleRate)
                )
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: wavFormat, frameCapacity: frameCount) else { return }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData || status == .endOfStream {
                    try? self.audioFile?.write(from: convertedBuffer)
                }
            }

            engine.prepare()
            try engine.start()
            audioEngine = engine
            isRecording = true
        } catch {
            print("Recording error: \(error)")
        }
    }

    func stopRecording() async -> String? {
        guard isRecording else { return nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        isRecording = false

        guard let url = tempURL else { return nil }
        defer {
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
        }

        return await transcribe(url: url)
    }

    func cancelRecording() {
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        isRecording = false
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
        }
    }

    // MARK: - Transcription

    private func transcribe(url: URL) async -> String? {
        guard let whisperKit else { return nil }
        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let options = DecodingOptions(language: "ru")
            let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
            let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        } catch {
            print("Transcription error: \(error)")
            return nil
        }
    }

    /// Transcribe an audio file (public, for TelegramService etc.)
    func transcribeFile(at url: URL) async -> String? {
        guard let whisperKit else { return nil }
        do {
            let options = DecodingOptions(language: "ru")
            let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
            let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        } catch {
            print("Transcription error: \(error)")
            return nil
        }
    }

    /// Ensure SpeakerKit is loaded (lazy, once)
    private func ensureSpeakerKit() async throws -> SpeakerKit {
        if let existing = speakerKit { return existing }
        print("[SpeakerKit] Downloading and loading models...")
        let sk = try await SpeakerKit()
        speakerKit = sk
        print("[SpeakerKit] Ready")
        return sk
    }

    /// Transcribe with speaker diarization — returns formatted dialogue
    func transcribeFileWithSpeakers(at url: URL) async -> String? {
        guard let whisperKit else { return nil }

        // Step 1: Transcribe with word timestamps
        print("[Diarize] Transcribing with word timestamps...")
        let options = DecodingOptions(language: "ru", wordTimestamps: true)
        let transcriptionResults: [TranscriptionResult]
        do {
            transcriptionResults = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        } catch {
            print("[Diarize] Transcription failed: \(error)")
            return await transcribeFile(at: url)
        }
        guard !transcriptionResults.isEmpty else {
            print("[Diarize] No transcription results")
            return nil
        }

        let plainText = transcriptionResults.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        print("[Diarize] Transcribed: \(plainText.prefix(100))...")

        // Step 2: Load audio for diarization
        let audioArray: [Float]
        do {
            let audioBuffer = try AudioProcessor.loadAudio(fromPath: url.path)
            guard let channelData = audioBuffer.floatChannelData?[0] else {
                print("[Diarize] No audio channel data")
                return plainText
            }
            audioArray = Array(UnsafeBufferPointer(start: channelData, count: Int(audioBuffer.frameLength)))
            print("[Diarize] Audio loaded: \(audioArray.count) samples (\(String(format: "%.1f", Double(audioArray.count) / 16000))s)")
        } catch {
            print("[Diarize] Audio load failed: \(error)")
            return plainText
        }

        // Step 3: Run speaker diarization
        do {
            let sk = try await ensureSpeakerKit()
            print("[Diarize] Running diarization...")
            // Lower threshold to better separate similar voices
            let diarizeOptions = PyannoteDiarizationOptions(
                clusterDistanceThreshold: 0.5,
                minClusterSize: 1
            )
            let diarization = try await sk.diarize(audioArray: audioArray, options: diarizeOptions)
            print("[Diarize] Found \(diarization.speakerCount) speakers, \(diarization.segments.count) segments")

            // Single speaker — return plain text
            if diarization.speakerCount <= 1 {
                return plainText.isEmpty ? nil : plainText
            }

            // Step 4: Merge with transcription
            let speakerSegments = diarization.addSpeakerInfo(to: transcriptionResults)

            var dialogue = ""
            var lastSpeaker = -1

            for segmentGroup in speakerSegments {
                for segment in segmentGroup {
                    let speakerId = segment.speaker.speakerId ?? 0
                    let words = segment.speakerWords.map { $0.wordTiming.word }.joined()

                    if speakerId != lastSpeaker {
                        if !dialogue.isEmpty { dialogue += "\n" }
                        dialogue += "Speaker \(speakerId + 1): "
                        lastSpeaker = speakerId
                    }
                    dialogue += words
                }
            }

            let result = dialogue.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[Diarize] Result:\n\(result.prefix(200))")
            return result.isEmpty ? plainText : result
        } catch {
            print("[Diarize] Diarization failed: \(error)")
            return plainText.isEmpty ? nil : plainText
        }
    }
}
