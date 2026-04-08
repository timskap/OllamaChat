import AVFoundation
import SwiftUI

struct LiveVisionView: View {
    @StateObject private var vision = LiveVisionService()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "viewfinder.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                Text("Live Vision (YOLO26-seg)")
                    .font(.title3.bold())
                Spacer()

                if vision.isRunning {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(String(format: "%.0f fps", vision.fps))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider()

            HStack(spacing: 0) {
                // Camera preview with overlays — aligned to actual video aspect ratio
                ZStack {
                    Color.black

                    if vision.isRunning {
                        // Container fitted to video aspect — boxes/mask align perfectly
                        ZStack(alignment: .topLeading) {
                            CameraPreview(session: vision.captureSession)

                            // Mask layer
                            if vision.showMasks, let cg = vision.maskImage {
                                GeometryReader { geo in
                                    Image(decorative: cg, scale: 1.0)
                                        .resizable()
                                        .interpolation(.medium)
                                        .frame(width: geo.size.width, height: geo.size.height)
                                        .allowsHitTesting(false)
                                }
                            }

                            // Box layer
                            if vision.showBoxes {
                                GeometryReader { geo in
                                    ZStack(alignment: .topLeading) {
                                        ForEach(vision.detections) { obj in
                                            DetectionOverlay(object: obj, in: geo.size, showBox: true, showMask: false)
                                        }
                                    }
                                }
                            }
                        }
                        .aspectRatio(vision.videoAspectRatio, contentMode: .fit)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)
                            Text(vision.statusText.isEmpty ? "Camera off" : vision.statusText)
                                .foregroundStyle(.secondary)
                            Button(action: { vision.start() }) {
                                Label("Start Camera", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right panel
                VStack(alignment: .leading, spacing: 0) {
                  ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                    // Model picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MODEL")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Picker("", selection: $vision.selectedYOLOModel) {
                            ForEach(YOLOModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    .padding(12)

                    Divider()

                    // Camera picker
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("CAMERA")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(action: { vision.refreshCameraList() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh cameras")
                        }

                        if vision.availableCameras.isEmpty {
                            Text("No cameras detected")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Picker("", selection: Binding(
                                get: { vision.selectedCameraID },
                                set: { vision.switchCamera(to: $0) }
                            )) {
                                ForEach(vision.availableCameras) { cam in
                                    Text(cam.name).tag(cam.id)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                    .padding(12)

                    Divider()

                    // Toggles
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Bounding Boxes", isOn: $vision.showBoxes)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        Toggle("Masks", isOn: $vision.showMasks)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    .padding(12)

                    Divider()

                    // Tuning
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CONFIDENCE")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                        HStack {
                            Slider(value: $vision.confidenceThreshold, in: 0.1...0.95)
                            Text("\(Int(vision.confidenceThreshold * 100))%")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 30)
                        }

                        Text("NMS IoU")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                        HStack {
                            Slider(value: $vision.iouThreshold, in: 0.1...0.9)
                            Text(String(format: "%.2f", vision.iouThreshold))
                                .font(.caption2.monospacedDigit())
                                .frame(width: 30)
                        }

                        Text("INFERENCE RATE")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                        HStack {
                            Slider(value: $vision.inferenceInterval, in: 0.05...1.0)
                            Text(String(format: "%.0f Hz", 1.0 / vision.inferenceInterval))
                                .font(.caption2.monospacedDigit())
                                .frame(width: 36)
                        }

                        Text("MAX OBJECTS")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                        HStack {
                            Slider(value: Binding(
                                get: { Double(vision.maxDetections) },
                                set: { vision.maxDetections = Int($0) }
                            ), in: 5...300, step: 5)
                            Text("\(vision.maxDetections)")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 30)
                        }
                    }
                    .padding(12)

                    Divider()

                    Text("DETECTED")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    if vision.detections.isEmpty {
                        Text(vision.isRunning ? "Looking..." : "Not running")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(vision.detections) { obj in
                                    HStack(spacing: 6) {
                                        Circle().fill(obj.color).frame(width: 8, height: 8)
                                        Text("#\(obj.trackId)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                        Text(obj.label)
                                            .font(.caption)
                                        Spacer()
                                        Text("\(Int(obj.confidence * 100))%")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(obj.color.opacity(0.05))
                                }
                            }
                        }
                    }
                    } // inner VStack
                  } // ScrollView

                    Divider()

                    // Footer controls
                    HStack {
                        if vision.isRunning {
                            Button(action: { vision.stop() }) {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        } else {
                            Button(action: { vision.start() }) {
                                Label("Start", systemImage: "play.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                }
                .frame(width: 220)
                .background(Color.secondary.opacity(0.06))
            }
        }
        .frame(width: 900, height: 600)
        .onDisappear { vision.stop() }
    }
}

// MARK: - Camera Preview (NSViewRepresentable)

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = view.bounds
        view.layer?.addSublayer(previewLayer)

        // Track resizes
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { _ in
            previewLayer.frame = view.bounds
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let preview = nsView.layer?.sublayers?.first(where: { $0 is AVCaptureVideoPreviewLayer }) {
            preview.frame = nsView.bounds
        }
    }
}

// MARK: - Detection Overlay

struct DetectionOverlay: View {
    let object: DetectedObject
    let size: CGSize
    let showBox: Bool
    let showMask: Bool

    init(object: DetectedObject, in size: CGSize, showBox: Bool, showMask: Bool) {
        self.object = object
        self.size = size
        self.showBox = showBox
        self.showMask = showMask
    }

    var body: some View {
        // bbox is in image space, top-left origin, normalized 0..1
        let bb = object.boundingBox
        let x = bb.minX * size.width
        let y = bb.minY * size.height
        let w = bb.width * size.width
        let h = bb.height * size.height

        ZStack(alignment: .topLeading) {
            if showBox {
                Rectangle()
                    .stroke(object.color, lineWidth: 2)
                    .frame(width: w, height: h)
                    .position(x: x + w/2, y: y + h/2)

                Text("#\(object.trackId) \(object.label) \(Int(object.confidence * 100))%")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(object.color)
                    .offset(x: x, y: max(0, y - 14))
            }
        }
    }
}
