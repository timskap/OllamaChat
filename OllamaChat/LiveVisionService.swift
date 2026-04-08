import AVFoundation
import CoreImage
import CoreML
import SwiftUI

// MARK: - Models

struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect      // normalized 0..1, top-left origin, image space
    let color: Color
}

struct CameraDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

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

// Fixed RGB triplets for each class (sRGB, no NSColor conversion)
private let classRGB: [(UInt8, UInt8, UInt8)] = (0..<80).map { i in
    let h = Float(i) * 360.0 / 80.0
    return hsvToRGB(h: h, s: 0.85, v: 0.95)
}

private func hsvToRGB(h: Float, s: Float, v: Float) -> (UInt8, UInt8, UInt8) {
    let c = v * s
    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    var r: Float = 0, g: Float = 0, b: Float = 0
    switch h {
    case 0..<60: r = c; g = x; b = 0
    case 60..<120: r = x; g = c; b = 0
    case 120..<180: r = 0; g = c; b = x
    case 180..<240: r = 0; g = x; b = c
    case 240..<300: r = x; g = 0; b = c
    default: r = c; g = 0; b = x
    }
    return (UInt8((r + m) * 255), UInt8((g + m) * 255), UInt8((b + m) * 255))
}

private func swiftUIColor(_ rgb: (UInt8, UInt8, UInt8)) -> Color {
    Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
}

// MARK: - Service

@MainActor
class LiveVisionService: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var detections: [DetectedObject] = []
    @Published var maskImage: CGImage?
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
    private let processingQueue = DispatchQueue(label: "com.ollama.vision.inference", qos: .userInitiated)

    private var coreMLModel: MLModel?
    private var lastFpsUpdate = Date()
    private var frameCount = 0

    // Atomic flag for frame skipping (only touched on processingQueue)
    private var processingLock = false

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
                statusText = "YOLO26-seg loaded"
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
            mediaType: .video, position: .unspecified
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
            mediaType: .video, position: .unspecified
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

    // MARK: - Inference (called from processingQueue)

    private func runInference(pixelBuffer: CVPixelBuffer, threshold: Float, doMasks: Bool) {
        guard let model = coreMLModel else { return }

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

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: 640, height: 640)),
              let inputBuffer = makePixelBuffer(from: cgImage, width: 640, height: 640) else { return }

        do {
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: inputBuffer)])
            let result = try model.prediction(from: provider)

            let (newDetections, maskCG) = parseResult(
                result: result, originalSize: srcSize, threshold: threshold, doMasks: doMasks
            )

            DispatchQueue.main.async { [weak self] in
                self?.detections = newDetections
                self?.maskImage = maskCG
                self?.updateFPS()
            }
        } catch {
            print("[LiveVision] Inference error: \(error)")
        }
    }

    private func makePixelBuffer(from cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
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

    /// Parse YOLO output. Returns (detections in image-space top-left coords, optional mask CGImage)
    private func parseResult(result: MLFeatureProvider, originalSize: CGSize, threshold: Float, doMasks: Bool) -> ([DetectedObject], CGImage?) {
        var detTensor: MLMultiArray?
        var protoTensor: MLMultiArray?

        for name in result.featureNames {
            guard let value = result.featureValue(for: name)?.multiArrayValue else { continue }
            if value.shape.count == 3 && value.shape[2].intValue == 38 {
                detTensor = value
            } else if value.shape.count == 4 && value.shape[1].intValue == 32 {
                protoTensor = value
            }
        }

        guard let det = detTensor else { return ([], nil) }

        let numDetections = det.shape[1].intValue
        let numFeatures = det.shape[2].intValue
        let pointer = det.dataPointer.bindMemory(to: Float.self, capacity: det.count)

        // Image space transform: model output is in 640x640 model input coords
        // which maps to the center square of original frame
        let sq = min(originalSize.width, originalSize.height)
        let offsetX = (originalSize.width - sq) / 2
        let offsetY = (originalSize.height - sq) / 2

        var detections: [DetectedObject] = []
        var validForMask: [(Int, [Float], (UInt8, UInt8, UInt8))] = []  // (cls, coeffs, rgb) in 640-space

        for i in 0..<numDetections {
            let base = i * numFeatures
            let x1 = pointer[base + 0]
            let y1 = pointer[base + 1]
            let x2 = pointer[base + 2]
            let y2 = pointer[base + 3]
            let conf = pointer[base + 4]
            let cls = Int(pointer[base + 5])

            if conf < threshold { continue }
            if cls < 0 || cls >= cocoLabels.count { continue }

            let label = cocoLabels[cls]
            let rgb = classRGB[cls]
            let color = swiftUIColor(rgb)

            // Convert from 640x640 model space to original image space (top-left, 0..1)
            let bx1 = (CGFloat(x1) / 640.0 * sq + offsetX) / originalSize.width
            let by1 = (CGFloat(y1) / 640.0 * sq + offsetY) / originalSize.height
            let bx2 = (CGFloat(x2) / 640.0 * sq + offsetX) / originalSize.width
            let by2 = (CGFloat(y2) / 640.0 * sq + offsetY) / originalSize.height

            let bbox = CGRect(x: bx1, y: by1, width: bx2 - bx1, height: by2 - by1)
            detections.append(DetectedObject(label: label, confidence: conf, boundingBox: bbox, color: color))

            // For mask: keep coefficients in 640-space coordinates
            if doMasks && numFeatures >= 38 {
                let coeffs = Array(UnsafeBufferPointer(start: pointer.advanced(by: base + 6), count: 32))
                validForMask.append((cls, coeffs, rgb))
            }

            // Limit detections to avoid overlap chaos
            if detections.count >= 30 { break }
        }

        // Build mask
        var maskCG: CGImage?
        if doMasks, let proto = protoTensor, !validForMask.isEmpty {
            // Re-iterate detections to get bbox in 640 model space for mask cropping
            var detsForMask: [(CGRect, [Float], (UInt8, UInt8, UInt8))] = []
            var idx = 0
            for i in 0..<numDetections {
                let base = i * numFeatures
                let conf = pointer[base + 4]
                let cls = Int(pointer[base + 5])
                if conf < threshold || cls < 0 || cls >= cocoLabels.count { continue }
                if idx >= validForMask.count { break }
                let x1 = CGFloat(pointer[base + 0])
                let y1 = CGFloat(pointer[base + 1])
                let x2 = CGFloat(pointer[base + 2])
                let y2 = CGFloat(pointer[base + 3])
                let bbox640 = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
                detsForMask.append((bbox640, validForMask[idx].1, validForMask[idx].2))
                idx += 1
                if idx >= 30 { break }
            }
            maskCG = buildMask(detections: detsForMask, proto: proto)
        }

        return (detections, maskCG)
    }

    /// Build mask from detections with bbox in 640x640 model space
    private func buildMask(detections: [(CGRect, [Float], (UInt8, UInt8, UInt8))], proto: MLMultiArray) -> CGImage? {
        guard !detections.isEmpty else { return nil }

        let pH = proto.shape[2].intValue  // 160
        let pW = proto.shape[3].intValue  // 160
        let pC = proto.shape[1].intValue  // 32
        let protoPtr = proto.dataPointer.bindMemory(to: Float.self, capacity: proto.count)

        var pixels = [UInt8](repeating: 0, count: pW * pH * 4)

        // Mask coordinates: bbox in 640-space → scale to 160-space
        let scale = Float(pW) / 640.0  // 0.25

        for (bbox640, coeffs, rgb) in detections {
            guard coeffs.count == pC else { continue }

            let xStart = max(0, Int(Float(bbox640.minX) * scale))
            let xEnd = min(pW, Int(Float(bbox640.maxX) * scale) + 1)
            let yStart = max(0, Int(Float(bbox640.minY) * scale))
            let yEnd = min(pH, Int(Float(bbox640.maxY) * scale) + 1)

            if xEnd <= xStart || yEnd <= yStart { continue }

            let (r, g, b) = rgb

            pixels.withUnsafeMutableBufferPointer { buf in
                for y in yStart..<yEnd {
                    for x in xStart..<xEnd {
                        var sum: Float = 0
                        for c in 0..<pC {
                            let pIdx = c * pH * pW + y * pW + x
                            sum += coeffs[c] * protoPtr[pIdx]
                        }
                        let prob = 1.0 / (1.0 + expf(-sum))
                        if prob > 0.5 {
                            let pix = (y * pW + x) * 4
                            buf[pix + 0] = r
                            buf[pix + 1] = g
                            buf[pix + 2] = b
                            buf[pix + 3] = 130
                        }
                    }
                }
            }
        }

        guard let providerRef = CGDataProvider(data: NSData(bytes: pixels, length: pixels.count)) else { return nil }
        return CGImage(
            width: pW, height: pH, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: pW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: providerRef,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    @MainActor
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

// MARK: - Capture delegate

extension LiveVisionService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Drop frame if still processing previous one
        processingQueue.async { [weak self] in
            guard let self else { return }
            if self.processingLock { return }
            self.processingLock = true

            // Snapshot UI settings on main, then run inference on this background queue
            let semaphore = DispatchSemaphore(value: 0)
            var threshold: Float = 0.4
            var doMasks: Bool = true
            DispatchQueue.main.async {
                threshold = self.confidenceThreshold
                doMasks = self.showMasks
                semaphore.signal()
            }
            semaphore.wait()

            self.runInference(pixelBuffer: pixelBuffer, threshold: threshold, doMasks: doMasks)
            self.processingLock = false
        }
    }
}
