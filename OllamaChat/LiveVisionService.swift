import AVFoundation
import CoreImage
import CoreML
import SwiftUI
import Vision

struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect  // normalized 0..1 in image space (origin top-left)
    let maskCoefficients: [Float]?  // 32 floats for prototype combination
    let color: Color
}

struct CameraDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
class LiveVisionService: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var detections: [DetectedObject] = []
    @Published var maskImage: CGImage?  // combined mask layer
    @Published var statusText = ""
    @Published var fps: Double = 0
    @Published var showMasks = true
    @Published var showBoxes = true
    @Published var availableCameras: [CameraDevice] = []
    @Published var selectedCameraID: String {
        didSet { UserDefaults.standard.set(selectedCameraID, forKey: "liveVisionCameraID") }
    }
    @Published var confidenceThreshold: Float = 0.4

    let captureSession = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.ollama.vision.video")

    private var coreMLModel: MLModel?
    private var visionModel: VNCoreMLModel?
    private let ciContext = CIContext()
    private var lastFpsUpdate = Date()
    private var frameCount = 0

    private let colors: [Color] = [
        .red, .blue, .green, .orange, .purple, .yellow, .pink, .cyan,
        .mint, .indigo, .teal, .brown
    ]
    private var classColors: [String: Color] = [:]

    // COCO 80 class names
    private let cocoLabels = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
        "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
        "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]

    override init() {
        self.selectedCameraID = UserDefaults.standard.string(forKey: "liveVisionCameraID") ?? ""
        super.init()
        loadModel()
        refreshCameraList()
    }

    private func loadModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            if let url = Bundle.main.url(forResource: "yolo26n-seg", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "yolo26n-seg", withExtension: "mlpackage") {
                self.coreMLModel = try MLModel(contentsOf: url, configuration: config)
                self.visionModel = try VNCoreMLModel(for: coreMLModel!)
                statusText = "YOLO26-seg loaded"
                print("[LiveVision] Model loaded. Outputs: \(coreMLModel!.modelDescription.outputDescriptionsByName.keys)")
            } else {
                statusText = "Model not found in bundle"
            }
        } catch {
            statusText = "Model load error: \(error.localizedDescription)"
        }
    }

    // MARK: - Camera

    func refreshCameraList() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .deskViewCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
        if selectedCameraID.isEmpty || !availableCameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = availableCameras.first?.id ?? ""
        }
    }

    func switchCamera(to id: String) {
        selectedCameraID = id
        guard isRunning else { return }
        Task { await applyCameraInput() }
    }

    func start() {
        guard !isRunning else { return }
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                statusText = "Camera permission denied"
                return
            }
            await setupCamera()
        }
    }

    private func setupCamera() async {
        refreshCameraList()
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        if !applyCameraInputLocked() {
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
                self?.maskImage = nil
                self?.statusText = ""
                self?.fps = 0
            }
        }
    }

    private func applyCameraInput() async {
        captureSession.beginConfiguration()
        _ = applyCameraInputLocked()
        captureSession.commitConfiguration()
    }

    private func applyCameraInputLocked() -> Bool {
        if let existing = currentInput {
            captureSession.removeInput(existing)
            currentInput = nil
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .deskViewCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let device: AVCaptureDevice?
        if !selectedCameraID.isEmpty {
            device = discovery.devices.first { $0.uniqueID == selectedCameraID } ?? discovery.devices.first
        } else {
            device = discovery.devices.first
        }
        guard let device else {
            statusText = "No camera found"
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                currentInput = input
                statusText = "Using \(device.localizedName)"
                return true
            }
        } catch {
            statusText = "Camera input error: \(error.localizedDescription)"
        }
        return false
    }

    // MARK: - Inference

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let model = coreMLModel else { return }

        // Convert pixel buffer to 640x640 input
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let srcSize = ciImage.extent.size

        // Center-crop to square then scale to 640
        let sq = min(srcSize.width, srcSize.height)
        let cropX = (srcSize.width - sq) / 2
        let cropY = (srcSize.height - sq) / 2
        let cropped = ciImage.cropped(to: CGRect(x: cropX, y: cropY, width: sq, height: sq))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
        let scale = 640.0 / sq
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = ciContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: 640, height: 640)) else { return }

        // Create input
        guard let inputBuffer = pixelBufferFromCGImage(cgImage, width: 640, height: 640) else { return }

        do {
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: inputBuffer)])
            let result = try model.prediction(from: provider)
            parseYOLOOutput(result: result, originalSize: srcSize)
        } catch {
            print("[LiveVision] Inference error: \(error)")
        }
    }

    private func pixelBufferFromCGImage(_ cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func parseYOLOOutput(result: MLFeatureProvider, originalSize: CGSize) {
        // Find the detection output (1×300×38) and mask proto (1×32×160×160)
        let outputs = result.featureNames
        var detTensor: MLMultiArray?
        var protoTensor: MLMultiArray?

        for name in outputs {
            guard let value = result.featureValue(for: name)?.multiArrayValue else { continue }
            if value.shape.count == 3 && value.shape[2].intValue == 38 {
                detTensor = value
            } else if value.shape.count == 4 && value.shape[1].intValue == 32 {
                protoTensor = value
            }
        }

        guard let det = detTensor else { return }

        let numDetections = det.shape[1].intValue  // 300
        let numFeatures = det.shape[2].intValue    // 38 = [x1,y1,x2,y2, conf, cls, ...32 mask coeffs]
        let pointer = det.dataPointer.bindMemory(to: Float.self, capacity: det.count)

        var newDetections: [DetectedObject] = []

        for i in 0..<numDetections {
            let base = i * numFeatures
            // Format: x1, y1, x2, y2, conf, cls, m0..m31  (Ultralytics end2end output)
            let x1 = pointer[base + 0] / 640.0
            let y1 = pointer[base + 1] / 640.0
            let x2 = pointer[base + 2] / 640.0
            let y2 = pointer[base + 3] / 640.0
            let conf = pointer[base + 4]
            let cls = Int(pointer[base + 5])

            if conf < confidenceThreshold { continue }
            if cls < 0 || cls >= cocoLabels.count { continue }

            let label = cocoLabels[cls]
            let color = classColors[label] ?? colors[abs(label.hashValue) % colors.count]
            classColors[label] = color

            // Mask coefficients (32 floats)
            var coeffs: [Float]? = nil
            if numFeatures >= 38 {
                coeffs = Array(UnsafeBufferPointer(start: pointer.advanced(by: base + 6), count: 32))
            }

            // Convert from 640x640 padded to original image (we center-cropped to square before scaling)
            // bbox is in 0..1 of the 640x640 input which maps to the center square of original
            let sq = min(originalSize.width, originalSize.height)
            let offsetX = (originalSize.width - sq) / 2
            let offsetY = (originalSize.height - sq) / 2

            let bx1 = (CGFloat(x1) * sq + offsetX) / originalSize.width
            let by1 = (CGFloat(y1) * sq + offsetY) / originalSize.height
            let bx2 = (CGFloat(x2) * sq + offsetX) / originalSize.width
            let by2 = (CGFloat(y2) * sq + offsetY) / originalSize.height

            newDetections.append(DetectedObject(
                label: label,
                confidence: conf,
                boundingBox: CGRect(x: bx1, y: by1, width: bx2 - bx1, height: by2 - by1),
                maskCoefficients: coeffs,
                color: color
            ))
        }

        // Combine masks if requested
        let combinedMask: CGImage? = (showMasks && protoTensor != nil) ?
            buildCombinedMask(detections: newDetections, proto: protoTensor!, originalSize: originalSize) : nil

        Task { @MainActor in
            self.detections = newDetections
            self.maskImage = combinedMask
            self.updateFPS()
        }
    }

    /// Combine all detection masks into one CGImage
    private func buildCombinedMask(detections: [DetectedObject], proto: MLMultiArray, originalSize: CGSize) -> CGImage? {
        guard !detections.isEmpty else { return nil }

        let pH = proto.shape[2].intValue  // 160
        let pW = proto.shape[3].intValue  // 160
        let pC = proto.shape[1].intValue  // 32
        let protoPtr = proto.dataPointer.bindMemory(to: Float.self, capacity: proto.count)

        // Output mask buffer (RGBA at proto resolution)
        var pixels = [UInt8](repeating: 0, count: pW * pH * 4)

        for det in detections {
            guard let coeffs = det.maskCoefficients, coeffs.count == pC else { continue }

            // Compute mask = sigmoid(sum_c coeffs[c] * proto[c])
            // Then crop to bounding box
            let bb = det.boundingBox
            let xStart = Int(bb.minX * CGFloat(pW))
            let xEnd = Int(bb.maxX * CGFloat(pW))
            let yStart = Int(bb.minY * CGFloat(pH))
            let yEnd = Int(bb.maxY * CGFloat(pH))

            // Extract RGB — convert from any colorspace (catalog/dynamic) to sRGB first
            let rawColor = NSColor(det.color)
            let nsColor = rawColor.usingColorSpace(.sRGB) ?? rawColor.usingColorSpace(.deviceRGB) ?? rawColor.usingColorSpace(.genericRGB)
            let r: UInt8 = nsColor.flatMap { UInt8(($0.redComponent * 255).clamped(to: 0...255)) } ?? 255
            let g: UInt8 = nsColor.flatMap { UInt8(($0.greenComponent * 255).clamped(to: 0...255)) } ?? 0
            let b: UInt8 = nsColor.flatMap { UInt8(($0.blueComponent * 255).clamped(to: 0...255)) } ?? 0

            for y in max(0, yStart)..<min(pH, yEnd) {
                for x in max(0, xStart)..<min(pW, xEnd) {
                    var sum: Float = 0
                    for c in 0..<pC {
                        let pIdx = c * pH * pW + y * pW + x
                        sum += coeffs[c] * protoPtr[pIdx]
                    }
                    let prob = 1.0 / (1.0 + expf(-sum))
                    if prob > 0.5 {
                        let pix = (y * pW + x) * 4
                        pixels[pix + 0] = r
                        pixels[pix + 1] = g
                        pixels[pix + 2] = b
                        pixels[pix + 3] = 120  // semi-transparent
                    }
                }
            }
        }

        // Build CGImage from pixel buffer
        let providerRef = CGDataProvider(data: NSData(bytes: pixels, length: pixels.count))
        return CGImage(
            width: pW, height: pH, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: pW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: providerRef!,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
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

extension LiveVisionService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor in
            self.processFrame(pixelBuffer)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
