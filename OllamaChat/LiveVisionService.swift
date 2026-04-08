import AVFoundation
import CoreImage
import CoreML
import SwiftUI

// MARK: - Models

struct DetectedObject: Identifiable {
    let id = UUID()
    let trackId: Int            // persistent ID across frames (0 if untracked)
    let label: String
    let confidence: Float
    let boundingBox: CGRect      // normalized 0..1, top-left origin, image space
    let color: Color
}

struct CameraDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum YOLOModel: String, CaseIterable, Identifiable {
    case yolo26nSeg = "yolo26n-seg"
    case yolo26sSeg = "yolo26s-seg"
    case yolo26mSeg = "yolo26m-seg"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yolo26nSeg: return "YOLO26-N (fast, ~5MB)"
        case .yolo26sSeg: return "YOLO26-S (balanced, 20MB)"
        case .yolo26mSeg: return "YOLO26-M (accurate, 45MB)"
        }
    }
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
    @Published var confidenceThreshold: Float = 0.5
    @Published var iouThreshold: Float = 0.45
    /// Minimum interval between inference runs in seconds (throttling)
    @Published var inferenceInterval: Double = 0.25  // ~4 fps inference (1280 model is heavier)
    /// Maximum number of detections to keep per frame
    @Published var maxDetections: Int = 100 {
        didSet { tracker.maxConfirmed = maxDetections }
    }
    @Published var trackerMatchIoU: Float = 0.15 {
        didSet { tracker.matchIoUThreshold = trackerMatchIoU }
    }
    @Published var trackerMinHits: Int = 1 {
        didSet { tracker.minHitsToConfirm = trackerMinHits }
    }
    @Published var trackerMaxStale: Int = 20 {
        didSet { tracker.maxStaleFrames = trackerMaxStale }
    }
    @Published var trackerMaxAge: Int = 60 {
        didSet { tracker.maxAge = trackerMaxAge }
    }
    @Published var selectedYOLOModel: YOLOModel {
        didSet {
            UserDefaults.standard.set(selectedYOLOModel.rawValue, forKey: "liveVisionYOLOModel")
            reloadModel()
        }
    }
    /// Actual video frame aspect ratio (width / height), updated when frames arrive
    @Published var videoAspectRatio: CGFloat = 16.0 / 9.0
    /// Original frame size from camera
    @Published var videoFrameSize: CGSize = .zero

    let captureSession = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.ollama.vision.video")
    private let processingQueue = DispatchQueue(label: "com.ollama.vision.inference", qos: .userInitiated)

    private var coreMLModel: MLModel?
    private var modelInputSize: CGFloat = 640  // dynamically detected
    private var lastFpsUpdate = Date()
    private var frameCount = 0
    private var lastInferenceTime = Date.distantPast
    private let tracker = ObjectTracker()

    // Atomic flag for frame skipping (only touched on processingQueue)
    private var processingLock = false

    override init() {
        self.selectedCameraID = UserDefaults.standard.string(forKey: "liveVisionCameraID") ?? ""
        let savedModel = UserDefaults.standard.string(forKey: "liveVisionYOLOModel") ?? YOLOModel.yolo26sSeg.rawValue
        self.selectedYOLOModel = YOLOModel(rawValue: savedModel) ?? .yolo26sSeg
        super.init()
        // Sync initial values to tracker
        tracker.matchIoUThreshold = trackerMatchIoU
        tracker.minHitsToConfirm = trackerMinHits
        tracker.maxStaleFrames = trackerMaxStale
        tracker.maxAge = trackerMaxAge
        tracker.maxConfirmed = maxDetections
        loadModel()
        refreshCameraList()
    }

    func reloadModel() {
        coreMLModel = nil
        tracker.reset()
        loadModel()
    }

    private func loadModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            // Try selected model first, fall back to others
            let preferred = selectedYOLOModel.rawValue
            var modelNames = [preferred]
            for m in YOLOModel.allCases where m.rawValue != preferred {
                modelNames.append(m.rawValue)
            }
            for name in modelNames {
                if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                    ?? Bundle.main.url(forResource: name, withExtension: "mlpackage") {
                    self.coreMLModel = try MLModel(contentsOf: url, configuration: config)
                    // Detect model input size
                    if let imageDesc = coreMLModel!.modelDescription.inputDescriptionsByName.values.first?.imageConstraint {
                        self.modelInputSize = CGFloat(imageDesc.pixelsWide)
                    }
                    statusText = "\(name) loaded (\(Int(modelInputSize))px)"
                    print("[LiveVision] Loaded \(name), input \(Int(modelInputSize))x\(Int(modelInputSize))")
                    return
                }
            }
            statusText = "Model not found in bundle"
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
        tracker.reset()
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
        tracker.reset()
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

    private func runInference(pixelBuffer: CVPixelBuffer, threshold: Float, doMasks: Bool, iouThresh: Float) {
        guard let model = coreMLModel else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let srcSize = ciImage.extent.size

        // Update aspect ratio if changed
        let aspect = srcSize.width / srcSize.height
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if abs(self.videoAspectRatio - aspect) > 0.01 {
                self.videoAspectRatio = aspect
                self.videoFrameSize = srcSize
            }
        }

        // Letterbox: scale to fit modelInputSize preserving aspect, pad with black
        let mSize = modelInputSize
        let scale = min(mSize / srcSize.width, mSize / srcSize.height)
        let scaledW = srcSize.width * scale
        let scaledH = srcSize.height * scale
        let padX = (mSize - scaledW) / 2
        let padY = (mSize - scaledH) / 2

        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(translationX: padX, y: padY))

        // Composite over black background to ensure model input size
        let blackBg = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: mSize, height: mSize))
        let composited = translated.composited(over: blackBg)

        let context = CIContext()
        let mInt = Int(mSize)
        guard let cgImage = context.createCGImage(composited, from: CGRect(x: 0, y: 0, width: mSize, height: mSize)),
              let inputBuffer = makePixelBuffer(from: cgImage, width: mInt, height: mInt) else { return }

        do {
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: inputBuffer)])
            let result = try model.prediction(from: provider)

            let (newDetections, maskCG) = parseResult(
                result: result, padX: padX, padY: padY, scaledW: scaledW, scaledH: scaledH,
                threshold: threshold, doMasks: doMasks, iouThresh: iouThresh
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

    /// Raw detection record in 640-space (xyxy pixels), used for NMS
    private struct RawDet {
        let cls: Int
        let conf: Float
        let bbox640: CGRect
        let coeffs: [Float]?
    }

    /// Parse YOLO output. Returns detections in 0..1 image space (relative to actual video frame, top-left origin)
    /// padX/padY/scaledW/scaledH describe the letterbox region inside model input space
    private func parseResult(result: MLFeatureProvider, padX: CGFloat, padY: CGFloat, scaledW: CGFloat, scaledH: CGFloat, threshold: Float, doMasks: Bool, iouThresh: Float) -> ([DetectedObject], CGImage?) {
        let mSize = modelInputSize
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

        // Use MLMultiArray subscript via raw pointer with stride awareness
        let numDetections = det.shape[1].intValue
        let numFeatures = det.shape[2].intValue
        guard let ptr = try? UnsafeBufferPointer<Float>(start: det.dataPointer.bindMemory(to: Float.self, capacity: det.count), count: det.count) else {
            return ([], nil)
        }

        // First pass: collect raw candidates above threshold
        var raws: [RawDet] = []
        raws.reserveCapacity(64)
        for i in 0..<numDetections {
            let base = i * numFeatures
            let conf = ptr[base + 4]
            // Skip empty/below threshold rows
            if conf < threshold { continue }
            let cls = Int(ptr[base + 5])
            if cls < 0 || cls >= cocoLabels.count { continue }

            let x1 = CGFloat(ptr[base + 0])
            let y1 = CGFloat(ptr[base + 1])
            let x2 = CGFloat(ptr[base + 2])
            let y2 = CGFloat(ptr[base + 3])

            // Sanity check: clamp to 0..modelInputSize
            let cx1 = max(0, min(mSize, x1))
            let cy1 = max(0, min(mSize, y1))
            let cx2 = max(0, min(mSize, x2))
            let cy2 = max(0, min(mSize, y2))
            if cx2 - cx1 < 2 || cy2 - cy1 < 2 { continue }

            var coeffs: [Float]? = nil
            if doMasks {
                coeffs = Array(ptr[(base + 6)..<(base + 6 + 32)])
            }

            raws.append(RawDet(
                cls: cls, conf: conf,
                bbox640: CGRect(x: cx1, y: cy1, width: cx2 - cx1, height: cy2 - cy1),
                coeffs: coeffs
            ))
        }

        // NMS — remove duplicates
        let kept = nonMaxSuppression(raws, iouThreshold: iouThresh, maxKeep: maxDetections)

        // Convert from model-space (letterboxed) to 0..1 image space and feed to tracker
        var trackerDets: [ObjectTracker.Detection] = []
        for r in kept {
            let bx1 = max(0, min(1, (r.bbox640.minX - padX) / scaledW))
            let by1 = max(0, min(1, (r.bbox640.minY - padY) / scaledH))
            let bx2 = max(0, min(1, (r.bbox640.maxX - padX) / scaledW))
            let by2 = max(0, min(1, (r.bbox640.maxY - padY) / scaledH))

            if bx2 - bx1 < 0.01 || by2 - by1 < 0.01 { continue }

            let bbox = CGRect(x: bx1, y: by1, width: bx2 - bx1, height: by2 - by1)
            trackerDets.append(ObjectTracker.Detection(
                cls: r.cls,
                label: cocoLabels[r.cls],
                bbox: bbox,
                confidence: r.conf,
                maskCoeffs: r.coeffs,
                bbox640: r.bbox640
            ))
        }

        // Run tracker for persistent IDs
        let tracks = tracker.update(detections: trackerDets)

        // Build DetectedObject from confirmed tracks
        var detections: [DetectedObject] = []
        for t in tracks {
            detections.append(DetectedObject(
                trackId: t.id,
                label: t.label,
                confidence: t.confidence,
                boundingBox: t.bbox,
                color: swiftUIColor(classRGB[t.cls])
            ))
        }

        // Build mask from tracked objects (uses their last known mask coeffs)
        var maskCG: CGImage?
        if doMasks, let proto = protoTensor, !tracks.isEmpty {
            let detsForMask = tracks.compactMap { t -> (CGRect, [Float], (UInt8, UInt8, UInt8))? in
                guard let coeffs = t.maskCoeffs, let bbox640 = t.bbox640 else { return nil }
                return (bbox640, coeffs, classRGB[t.cls])
            }
            if let fullMask = buildMask(detections: detsForMask, proto: proto) {
                // Crop the inner region (where actual video is) so it aligns with displayed frame
                let pW = CGFloat(proto.shape[3].intValue)
                let pH = CGFloat(proto.shape[2].intValue)
                let cropX = padX / mSize * pW
                let cropY = padY / mSize * pH
                let cropW = scaledW / mSize * pW
                let cropH = scaledH / mSize * pH
                let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                if let cropped = fullMask.cropping(to: cropRect) {
                    maskCG = cropped
                } else {
                    maskCG = fullMask
                }
            }
        }

        return (detections, maskCG)
    }

    /// Class-aware NMS
    private func nonMaxSuppression(_ raws: [RawDet], iouThreshold: Float, maxKeep: Int) -> [RawDet] {
        // Sort by confidence descending
        let sorted = raws.sorted { $0.conf > $1.conf }
        var kept: [RawDet] = []
        var suppressed = Set<Int>()

        for (i, det) in sorted.enumerated() {
            if suppressed.contains(i) { continue }
            kept.append(det)
            if kept.count >= maxKeep { break }
            for j in (i + 1)..<sorted.count {
                if suppressed.contains(j) { continue }
                let other = sorted[j]
                if other.cls != det.cls { continue }  // class-aware NMS
                if iou(det.bbox640, other.bbox640) > iouThreshold {
                    suppressed.insert(j)
                }
            }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = Float(inter.width * inter.height)
        let unionArea = Float(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// Build mask from detections with bbox in model input space
    private func buildMask(detections: [(CGRect, [Float], (UInt8, UInt8, UInt8))], proto: MLMultiArray) -> CGImage? {
        guard !detections.isEmpty else { return nil }

        let pH = proto.shape[2].intValue
        let pW = proto.shape[3].intValue
        let pC = proto.shape[1].intValue
        let protoPtr = proto.dataPointer.bindMemory(to: Float.self, capacity: proto.count)

        var pixels = [UInt8](repeating: 0, count: pW * pH * 4)

        // Mask coordinates: bbox in model space → scale to proto space
        let scale = Float(pW) / Float(modelInputSize)

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

        // Drop frame if still processing previous one OR not enough time elapsed
        processingQueue.async { [weak self] in
            guard let self else { return }
            if self.processingLock { return }

            // Snapshot UI settings on main thread synchronously
            let semaphore = DispatchSemaphore(value: 0)
            var threshold: Float = 0.5
            var iouThresh: Float = 0.45
            var doMasks: Bool = true
            var minInterval: Double = 0.15
            DispatchQueue.main.async {
                threshold = self.confidenceThreshold
                iouThresh = self.iouThreshold
                doMasks = self.showMasks
                minInterval = self.inferenceInterval
                semaphore.signal()
            }
            semaphore.wait()

            // Throttle: skip if last inference was too recent
            let now = Date()
            if now.timeIntervalSince(self.lastInferenceTime) < minInterval { return }

            self.processingLock = true
            self.lastInferenceTime = now
            self.runInference(pixelBuffer: pixelBuffer, threshold: threshold, doMasks: doMasks, iouThresh: iouThresh)
            self.processingLock = false
        }
    }
}
