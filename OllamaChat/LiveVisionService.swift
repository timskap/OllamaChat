import AVFoundation
import CoreML
import SwiftUI
import Vision

struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect  // normalized 0..1 (Vision coordinates: origin bottom-left)
    let mask: CIImage?       // segmentation mask
    let color: Color
}

@MainActor
class LiveVisionService: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var detections: [DetectedObject] = []
    @Published var statusText = ""
    @Published var fps: Double = 0
    @Published var showMasks = true
    @Published var showBoxes = true

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.ollama.vision.video")

    private var visionModel: VNCoreMLModel?
    private var lastFrameTime = Date()
    private var frameCount = 0
    private var lastFpsUpdate = Date()

    // Color palette for classes
    private let colors: [Color] = [
        .red, .blue, .green, .orange, .purple, .yellow, .pink, .cyan,
        .mint, .indigo, .teal, .brown, .red.opacity(0.7), .blue.opacity(0.7)
    ]
    private var classColors: [String: Color] = [:]

    override init() {
        super.init()
        loadModel()
    }

    private func loadModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            // Try to find the .mlmodelc (compiled) or .mlpackage in bundle
            if let url = Bundle.main.url(forResource: "yolo26n-seg", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "yolo26n-seg", withExtension: "mlpackage") {
                let mlModel = try MLModel(contentsOf: url, configuration: config)
                self.visionModel = try VNCoreMLModel(for: mlModel)
                statusText = "Model loaded"
            } else {
                statusText = "Model not found in bundle"
            }
        } catch {
            statusText = "Model load error: \(error.localizedDescription)"
        }
    }

    // MARK: - Camera

    func start() {
        guard !isRunning else { return }
        Task {
            // Request camera permission
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                statusText = "Camera permission denied"
                return
            }

            await setupCamera()
        }
    }

    private func setupCamera() async {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        // Find front-facing or any camera
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first else {
            statusText = "No camera found"
            captureSession.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
        } catch {
            statusText = "Camera input error: \(error.localizedDescription)"
            captureSession.commitConfiguration()
            return
        }

        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()

        // Start on background queue (canStart on main thread blocks)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            Task { @MainActor in
                self?.isRunning = true
                self?.statusText = "Running"
            }
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.stopRunning()
            Task { @MainActor in
                self?.isRunning = false
                self?.detections = []
                self?.statusText = ""
                self?.fps = 0
            }
        }
    }

    // MARK: - Inference

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let model = visionModel else { return }

        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.statusText = "Inference error: \(error.localizedDescription)" }
                return
            }
            self.handleResults(request.results)
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            // ignore
        }
    }

    private func handleResults(_ results: [Any]?) {
        guard let results = results else { return }

        var detected: [DetectedObject] = []

        for result in results {
            // YOLO seg returns VNRecognizedObjectObservation with masks
            if let observation = result as? VNRecognizedObjectObservation {
                guard let topLabel = observation.labels.first else { continue }
                let label = topLabel.identifier
                let conf = topLabel.confidence
                guard conf > 0.4 else { continue }

                let color = classColors[label] ?? colors[abs(label.hashValue) % colors.count]
                classColors[label] = color

                detected.append(DetectedObject(
                    label: label,
                    confidence: conf,
                    boundingBox: observation.boundingBox,
                    mask: nil,
                    color: color
                ))
            }
        }

        Task { @MainActor in
            self.detections = detected
            self.updateFPS()
        }
    }

    private func updateFPS() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFpsUpdate)
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            lastFpsUpdate = now
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension LiveVisionService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor in
            self.processFrame(pixelBuffer)
        }
    }
}
