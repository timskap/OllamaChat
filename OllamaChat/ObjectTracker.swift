import Foundation
import CoreGraphics

/// Lightweight multi-object tracker (ByteTrack-style)
/// - Persistent IDs across frames via IoU matching
/// - Constant-velocity motion prediction
/// - Two-stage association (high-conf first, then low-conf)
/// - Lost track grace period (objects can disappear briefly without losing ID)
final class ObjectTracker {

    /// A single tracked object
    final class Track {
        let id: Int
        var cls: Int
        var label: String
        var bbox: CGRect       // current/predicted bbox in 0..1 image space
        var confidence: Float
        var velocity: CGVector  // px/frame in normalized coords
        var age: Int = 0        // frames since first detection
        var hits: Int = 0       // total times matched to a detection
        var timeSinceUpdate: Int = 0  // frames since last match
        var maskCoeffs: [Float]?  // updated each frame from latest detection
        var bbox640: CGRect?    // last known bbox in model space (for mask building)
        var lastSeen: Date = Date()

        init(id: Int, cls: Int, label: String, bbox: CGRect, confidence: Float, maskCoeffs: [Float]?, bbox640: CGRect?) {
            self.id = id
            self.cls = cls
            self.label = label
            self.bbox = bbox
            self.confidence = confidence
            self.velocity = .zero
            self.maskCoeffs = maskCoeffs
            self.bbox640 = bbox640
        }

        /// Predict next position using constant velocity model
        func predict() {
            bbox = CGRect(
                x: bbox.minX + velocity.dx,
                y: bbox.minY + velocity.dy,
                width: bbox.width,
                height: bbox.height
            )
            age += 1
            timeSinceUpdate += 1
        }

        /// Update with a matched detection
        func update(bbox: CGRect, confidence: Float, maskCoeffs: [Float]?, bbox640: CGRect?) {
            // Estimate velocity (smoothed)
            let dx = bbox.minX - self.bbox.minX
            let dy = bbox.minY - self.bbox.minY
            velocity = CGVector(
                dx: 0.7 * velocity.dx + 0.3 * dx,
                dy: 0.7 * velocity.dy + 0.3 * dy
            )
            self.bbox = bbox
            self.confidence = confidence
            self.maskCoeffs = maskCoeffs
            self.bbox640 = bbox640
            self.hits += 1
            self.timeSinceUpdate = 0
            self.lastSeen = Date()
        }
    }

    /// New detection input
    struct Detection {
        let cls: Int
        let label: String
        let bbox: CGRect       // 0..1 image space
        let confidence: Float
        let maskCoeffs: [Float]?
        let bbox640: CGRect?
    }

    // MARK: - Configuration

    /// IoU threshold for matching detections to tracks
    var matchIoUThreshold: Float = 0.3
    /// Minimum hits before a track is "confirmed" (visible to user)
    var minHitsToConfirm: Int = 2
    /// Maximum frames a track can go without detection before being deleted
    var maxAge: Int = 30
    /// Confidence threshold to split high vs low detections (ByteTrack 2-stage)
    var highConfidence: Float = 0.6
    /// Maximum number of confirmed tracks to return
    var maxConfirmed: Int = 100

    // MARK: - State

    private var tracks: [Track] = []
    private var nextId: Int = 1

    /// All currently tracked objects (confirmed only), sorted by confidence
    var confirmedTracks: [Track] {
        tracks
            .filter { $0.hits >= minHitsToConfirm && $0.timeSinceUpdate < 5 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxConfirmed)
            .map { $0 }
    }

    /// Process a new frame's detections, return matched tracks
    func update(detections: [Detection]) -> [Track] {
        // Step 1: Predict next position for all tracks
        for track in tracks { track.predict() }

        // Step 2: Split detections by confidence
        let highDets = detections.enumerated().filter { $0.element.confidence >= highConfidence }
        let lowDets = detections.enumerated().filter { $0.element.confidence < highConfidence }

        var unmatchedTrackIdx = Set(tracks.indices)
        var unmatchedHighDetIdx = Set(highDets.map { $0.offset })

        // Step 3: First association (high-conf detections, IoU + class match)
        let highMatches = associate(
            tracks: tracks,
            trackIdxs: Array(unmatchedTrackIdx),
            dets: detections,
            detIdxs: Array(unmatchedHighDetIdx),
            iouThreshold: matchIoUThreshold
        )

        for (trackIdx, detIdx) in highMatches {
            let det = detections[detIdx]
            tracks[trackIdx].update(bbox: det.bbox, confidence: det.confidence, maskCoeffs: det.maskCoeffs, bbox640: det.bbox640)
            unmatchedTrackIdx.remove(trackIdx)
            unmatchedHighDetIdx.remove(detIdx)
        }

        // Step 4: Second association (low-conf detections to remaining tracks)
        let lowMatches = associate(
            tracks: tracks,
            trackIdxs: Array(unmatchedTrackIdx),
            dets: detections,
            detIdxs: lowDets.map { $0.offset },
            iouThreshold: 0.5  // stricter for low-conf
        )

        for (trackIdx, detIdx) in lowMatches {
            let det = detections[detIdx]
            tracks[trackIdx].update(bbox: det.bbox, confidence: det.confidence, maskCoeffs: det.maskCoeffs, bbox640: det.bbox640)
            unmatchedTrackIdx.remove(trackIdx)
        }

        // Step 5: Create new tracks for unmatched high-confidence detections
        for detIdx in unmatchedHighDetIdx {
            let det = detections[detIdx]
            let id = nextId
            nextId += 1
            let track = Track(
                id: id,
                cls: det.cls,
                label: det.label,
                bbox: det.bbox,
                confidence: det.confidence,
                maskCoeffs: det.maskCoeffs,
                bbox640: det.bbox640
            )
            track.hits = 1
            tracks.append(track)
        }

        // Step 6: Remove old/lost tracks
        tracks.removeAll { $0.timeSinceUpdate > maxAge }

        return confirmedTracks
    }

    /// Reset all tracks (e.g. when camera changes)
    func reset() {
        tracks.removeAll()
        nextId = 1
    }

    // MARK: - Association via greedy IoU matching

    /// Greedy bipartite matching: best IoU first, class-aware
    private func associate(tracks: [Track], trackIdxs: [Int], dets: [Detection], detIdxs: [Int], iouThreshold: Float) -> [(Int, Int)] {
        guard !trackIdxs.isEmpty, !detIdxs.isEmpty else { return [] }

        // Build all valid pairs (same class) with their IoU
        var pairs: [(track: Int, det: Int, iou: Float)] = []
        for ti in trackIdxs {
            for di in detIdxs {
                let track = tracks[ti]
                let det = dets[di]
                if track.cls != det.cls { continue }
                let iouValue = iou(track.bbox, det.bbox)
                if iouValue >= iouThreshold {
                    pairs.append((ti, di, iouValue))
                }
            }
        }

        // Sort by IoU descending — greedy match best first
        pairs.sort { $0.iou > $1.iou }

        var usedTracks = Set<Int>()
        var usedDets = Set<Int>()
        var matches: [(Int, Int)] = []

        for pair in pairs {
            if usedTracks.contains(pair.track) || usedDets.contains(pair.det) { continue }
            usedTracks.insert(pair.track)
            usedDets.insert(pair.det)
            matches.append((pair.track, pair.det))
        }
        return matches
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = Float(inter.width * inter.height)
        let unionArea = Float(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
