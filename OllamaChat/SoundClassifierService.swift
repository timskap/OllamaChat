import AVFoundation
import Combine
import SoundAnalysis
import SwiftUI

struct SoundDetection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Double
    let timestamp: Date
}

@MainActor
class SoundClassifierService: ObservableObject {
    @Published var isListening = false
    @Published var detections: [SoundDetection] = []
    @Published var topSound: String = ""
    @Published var isSpeechDetected = false
    @Published var isAutoRecording = false

    /// Called when speech ends and transcription should be sent
    var onSpeechTranscribed: ((String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: Observer?
    private let analysisQueue = DispatchQueue(label: "com.ollama.soundanalysis")

    private weak var audioService: AudioService?
    private var silenceTimer: Timer?
    private var levelObserver: AnyCancellable?
    private let silenceThreshold: Float = 0.02
    private let silenceTimeout: TimeInterval = 2.0

    func start(audioService: AudioService? = nil) {
        guard !isListening else { return }
        self.audioService = audioService
        startClassifierEngine()
        isListening = true
    }

    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        levelObserver?.cancel()
        levelObserver = nil

        if isAutoRecording {
            audioService?.cancelRecording()
            isAutoRecording = false
        }

        stopClassifierEngine()
        isListening = false
        isSpeechDetected = false
        topSound = ""
    }

    /// Classify a single audio file
    func classifyFile(at url: URL, maxResults: Int = 5) async -> [SoundDetection] {
        await withCheckedContinuation { continuation in
            do {
                let fileAnalyzer = try SNAudioFileAnalyzer(url: url)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.windowDuration = CMTimeMakeWithSeconds(3.0, preferredTimescale: 48_000)

                var allResults: [SoundDetection] = []
                let obs = Observer { results in allResults.append(contentsOf: results) }

                try fileAnalyzer.add(request, withObserver: obs)
                fileAnalyzer.analyze { _ in
                    var best: [String: Double] = [:]
                    for r in allResults { best[r.label] = max(best[r.label] ?? 0, r.confidence) }
                    let sorted = best.sorted { $0.value > $1.value }.prefix(maxResults)
                    continuation.resume(returning: sorted.map { SoundDetection(label: $0.key, confidence: $0.value, timestamp: .now) })
                }
            } catch { continuation.resume(returning: []) }
        }
    }

    // MARK: - Speech Detection

    private func handleResults(_ results: [SoundDetection]) {
        let significant = results.filter { $0.confidence > 0.3 }
        if let best = significant.first {
            topSound = "\(best.label) (\(Int(best.confidence * 100))%)"
        }
        detections.append(contentsOf: significant)
        if detections.count > 50 { detections.removeFirst(detections.count - 50) }

        let hasSpeech = results.contains { isSpeechLabel($0.label) && $0.confidence > 0.4 }

        if hasSpeech && !isAutoRecording {
            startAutoRecording()
        }
    }

    private func isSpeechLabel(_ label: String) -> Bool {
        let labels = ["speech", "conversation", "narration"]
        return labels.contains { label.lowercased().contains($0) }
    }

    private func startAutoRecording() {
        guard let audioService, audioService.isModelLoaded, !audioService.isRecording else { return }

        isSpeechDetected = true
        isAutoRecording = true

        // Stop classifier to free the audio tap
        stopClassifierEngine()

        // Start whisper recording
        audioService.startRecording()

        // Monitor audio level to detect silence
        levelObserver = audioService.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.checkSilence(level: level)
            }
    }

    private func checkSilence(level: Float) {
        if level < silenceThreshold {
            // Quiet — start/continue silence timer
            if silenceTimer == nil {
                silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.endSpeech()
                    }
                }
            }
        } else {
            // Sound detected — reset silence timer
            silenceTimer?.invalidate()
            silenceTimer = nil
        }
    }

    private func endSpeech() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        levelObserver?.cancel()
        levelObserver = nil
        isSpeechDetected = false

        guard isAutoRecording, let audioService else { return }
        isAutoRecording = false

        Task {
            if let text = await audioService.stopRecording(), !text.isEmpty {
                onSpeechTranscribed?(text)
            }
            // Restart classifier to listen for next speech
            if isListening {
                startClassifierEngine()
            }
        }
    }

    // MARK: - Engine Management

    private func startClassifierEngine() {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        let streamAnalyzer = SNAudioStreamAnalyzer(format: format)

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTimeMakeWithSeconds(1.5, preferredTimescale: 48_000)
            request.overlapFactor = 0.5

            let obs = Observer { [weak self] results in
                Task { @MainActor in self?.handleResults(results) }
            }
            observer = obs
            try streamAnalyzer.add(request, withObserver: obs)

            engine.inputNode.installTap(onBus: 0, bufferSize: 8192, format: format) { buffer, time in
                self.analysisQueue.async {
                    streamAnalyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
                }
            }

            engine.prepare()
            try engine.start()
            audioEngine = engine
            analyzer = streamAnalyzer
        } catch {
            print("SoundClassifier error: \(error)")
        }
    }

    private func stopClassifierEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        analyzer = nil
        observer = nil
    }

    // MARK: - Observer

    private class Observer: NSObject, SNResultsObserving {
        let handler: ([SoundDetection]) -> Void
        init(handler: @escaping ([SoundDetection]) -> Void) { self.handler = handler }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            let top = classification.classifications
                .filter { $0.confidence > 0.1 }.prefix(3)
                .map { SoundDetection(label: $0.identifier, confidence: $0.confidence, timestamp: .now) }
            if !top.isEmpty { handler(Array(top)) }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {}
        func requestDidComplete(_ request: SNRequest) {}
    }
}
