import AVFoundation
import SwiftUI
import WhisperKit

@MainActor
class AudioService: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isModelLoaded = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0 // 0.0 - 1.0
    @Published var downloadedMB: Int64 = 0
    @Published var totalMB: Int64 = 0
    @Published var statusText: String = ""
    @Published var audioLevel: Float = 0 // 0.0 - 1.0, updated during recording

    private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempURL: URL?

    private let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

    func loadModel() async {
        guard whisperKit == nil else { return }

        // Try up to 2 times (clear cache on first failure)
        for attempt in 0..<2 {
            do {
                isDownloading = true
                statusText = attempt == 0 ? "Downloading Whisper model..." : "Retrying download (cleared cache)..."
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
                    // Clear corrupted cache and retry
                    statusText = "Clearing corrupted cache..."
                    clearModelCache()
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    statusText = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func clearModelCache() {
        // HuggingFace Hub default cache location
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cacheDir = homeDir.appendingPathComponent(".cache/huggingface/hub")
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for item in contents where item.lastPathComponent.contains("whisperkit") {
            try? fm.removeItem(at: item)
        }
    }

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
                    let level = min(rms * 5, 1.0) // amplify for UI
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

    /// Transcribe an audio file at the given URL (public, for use by TelegramService etc.)
    /// The file must be in a format AVFoundation can read (WAV, M4A, MP3, CAF, etc.)
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
}
