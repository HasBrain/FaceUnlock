//
//  FaceEnrollmentService.swift
//  FaceUnlock
//

import Foundation
import Vision
import CoreVideo
import CoreImage
import CoreGraphics

enum FaceEnrollmentError: LocalizedError {
    case noFrameAvailable
    case noFaceDetected
    case multipleFacesDetected
    case faceTooSmall
    case lowQuality(Float)
    case wrongPose(expected: FacePose)
    case poseTimeout(FacePose)
    case croppingFailed
    case notEnrolled
    case modelUnavailable(String)
    case embeddingFailed(underlying: Error)
    case storageFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noFrameAvailable:
            return "No camera frame available yet. Try again in a moment."
        case .noFaceDetected:
            return "No face detected. Center your face in the camera."
        case .multipleFacesDetected:
            return "More than one face detected. Only your face should be in view."
        case .faceTooSmall:
            return "Face is too small or far from the camera. Move closer."
        case .lowQuality(let q):
            return String(format: "Face capture quality too low (%.2f). Improve lighting or face the camera squarely.", q)
        case .wrongPose(let expected):
            return "Pose doesn't match. Expected: \(expected.prompt)."
        case .poseTimeout(let pose):
            return "Couldn't capture pose '\(pose.prompt)' in time. Try again, holding the pose steady."
        case .croppingFailed:
            return "Couldn't crop the detected face from the frame."
        case .notEnrolled:
            return "No enrolled face yet. Press Capture first to enroll."
        case .modelUnavailable(let reason):
            return reason
        case .embeddingFailed(let error):
            return "Embedding failed: \(error.localizedDescription)"
        case .storageFailed(let underlying):
            return "Couldn't read or write the saved face: \(underlying.localizedDescription)"
        }
    }
}

enum FacePose: CaseIterable {
    case straight
    case turnLeft
    case turnRight
    case rollLeft
    case rollRight
    case closer
    case farther

    var prompt: String {
        switch self {
        case .straight:  return "Look straight at the camera"
        case .turnLeft:  return "Turn your head to the LEFT"
        case .turnRight: return "Turn your head to the RIGHT"
        case .rollLeft:  return "Tilt head - LEFT ear toward shoulder"
        case .rollRight: return "Tilt head - RIGHT ear toward shoulder"
        case .closer:    return "Move CLOSER to the camera"
        case .farther:   return "Move FARTHER from the camera (arm's length)"
        }
    }

    /// Pose thresholds. Yaw and roll are radians; `faceWidth` is the normalized
    /// face bounding-box width (0..1), used as a distance proxy. Vision's pitch
    /// estimate isn't consistent enough to gate on, so it's not in the check.
    func matches(yaw: Float, roll: Float, faceWidth: CGFloat) -> Bool {
        switch self {
        case .straight:
            return abs(yaw) < 0.12 && abs(roll) < 0.10
        case .turnLeft:  return yaw   < -0.15
        case .turnRight: return yaw   >  0.15
        case .rollLeft:  return roll  < -0.15
        case .rollRight: return roll  >  0.15
        case .closer:    return faceWidth > 0.32
        case .farther:   return faceWidth < 0.22
        }
    }
}

struct FrameAnalysis {
    let face: VNFaceObservation
    let yaw: Float
    let roll: Float
    let quality: Float
    let embedding: [Float]
}

struct VerificationResult {
    let matched: Bool
    let similarity: Float
    let threshold: Float
    let centroidSimilarity: Float
    let maxIndividualSimilarity: Float
    let enrolledCount: Int
}

struct EnrollmentReport {
    let savedURL: URL
    let savedEmbeddings: Int
}

final class FaceEnrollmentService {
    /// Current on-disk name — AES-GCM ciphertext, no useful info without the session key.
    static let enrolledFilename = "embeddings.enc"
    /// Legacy plaintext JSON from pre-encryption versions; readable for auto-migration.
    static let legacyEnrolledFilename = "embeddings.json"
    nonisolated static let defaultMatchThreshold: Float = 0.70
    // Face bbox width must be at least this fraction of the frame width to be
    // considered valid. 0.10 corresponds to a distance of roughly 93 cm on a typical
    // laptop camera (78° FOV, ~15 cm face) — well past the 70 cm working target.
    nonisolated static let minimumFaceWidthFraction: CGFloat = 0.10
    nonisolated static let minimumCaptureQuality: Float = 0.35

    /// Centered region of interest (in Vision's normalized frame coordinates) that
    /// approximates the visible viewfinder circle. Faces whose bounding-box center
    /// falls outside this rect are ignored — useful for filtering background people.
    /// 50% width × 60% height, centered.
    nonisolated static let faceROI: CGRect = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)

    /// Decides whether a face is "in the viewfinder" based on its bounding-box center.
    /// Predictable rule, matches the visual affordance, no half-in/half-out ambiguity.
    nonisolated static func isFaceInROI(_ boundingBox: CGRect) -> Bool {
        faceROI.contains(CGPoint(x: boundingBox.midX, y: boundingBox.midY))
    }

    private let embedder: FaceEmbedder?
    private let embedderLoadError: Error?
    private let ciContext = CIContext()

    init() {
        do {
            self.embedder = try FaceEmbedder()
            self.embedderLoadError = nil
        } catch {
            self.embedder = nil
            self.embedderLoadError = error
        }
    }

    var isModelReady: Bool { embedder != nil }
    var modelLoadErrorMessage: String? { embedderLoadError?.localizedDescription }

    // MARK: - Lightweight face position detection (no embedding)

    /// Detects the face bounding box only — no quality scoring, no embedding.
    /// Used by the framing watcher for cheap "is the face centered?" polls.
    /// Faces outside the viewfinder ROI are ignored (background people don't count).
    func detectFacePosition(in pixelBuffer: CVPixelBuffer) throws -> CGRect {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try handler.perform([request])
        let inROI = (request.results ?? []).filter { Self.isFaceInROI($0.boundingBox) }
        guard !inROI.isEmpty else { throw FaceEnrollmentError.noFaceDetected }
        guard inROI.count == 1 else { throw FaceEnrollmentError.multipleFacesDetected }
        return inROI[0].boundingBox
    }

    // MARK: - Single-frame full analysis (used by both enroll & verify)

    /// Detects → optionally scores quality → crops → embeds. Quality scoring is the most
    /// expensive request in the pipeline (~30ms), so callers that don't need it (e.g. the
    /// verify scan loop) should pass `includeQuality: false`.
    func analyzeFrame(_ pixelBuffer: CVPixelBuffer, includeQuality: Bool = true) throws -> FrameAnalysis {
        guard let embedder = embedder else {
            throw FaceEnrollmentError.modelUnavailable(
                embedderLoadError?.localizedDescription ?? "FaceEmbedding model is not loaded."
            )
        }

        // VNDetectFaceLandmarksRequest performs face detection AND landmark localization
        // in one pass. Landmarks power the affine alignment step below — same-person
        // similarity is markedly more stable when the crop is aligned to canonical eye
        // positions instead of the raw axis-aligned bbox.
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        var requests: [VNRequest] = [landmarksRequest]
        if includeQuality { requests.append(qualityRequest) }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try handler.perform(requests)

        // Filter faces to only those inside the viewfinder ROI — background people don't count.
        let inROI = (landmarksRequest.results ?? []).filter { Self.isFaceInROI($0.boundingBox) }
        guard !inROI.isEmpty else { throw FaceEnrollmentError.noFaceDetected }
        guard inROI.count == 1 else { throw FaceEnrollmentError.multipleFacesDetected }
        let face = inROI[0]

        guard face.boundingBox.width >= Self.minimumFaceWidthFraction else {
            throw FaceEnrollmentError.faceTooSmall
        }

        let quality: Float
        if includeQuality {
            quality = (qualityRequest.results ?? []).first?.faceCaptureQuality ?? 0.5
        } else {
            quality = 1.0  // assume good when not measured
        }
        let yaw: Float = face.yaw.map { Float(truncating: $0) } ?? 0
        let roll: Float = face.roll.map { Float(truncating: $0) } ?? 0

        // Prefer landmark-aligned crop; fall back to axis-aligned bbox crop if
        // landmarks are missing or degenerate (extreme pose, occlusion, etc.).
        let cropped = try alignedOrPaddedCrop(pixelBuffer: pixelBuffer, face: face)
        do {
            let embedding = try embedder.embed(faceImage: cropped)
            return FrameAnalysis(face: face, yaw: yaw, roll: roll, quality: quality, embedding: embedding)
        } catch {
            throw FaceEnrollmentError.embeddingFailed(underlying: error)
        }
    }

    // MARK: - Save enrolled embeddings

    func saveEmbeddings(_ embeddings: [[Float]]) throws -> URL {
        do {
            let dir = try Self.storageDirectory()
            let url = dir.appendingPathComponent(Self.enrolledFilename)
            let json = try JSONEncoder().encode(embeddings)
            let encrypted = try PasswordVault.encryptWithSessionKey(json)
            try encrypted.write(to: url, options: .atomic)

            // Migration: if a legacy plaintext file is lying around, remove it.
            let legacyURL = dir.appendingPathComponent(Self.legacyEnrolledFilename)
            try? FileManager.default.removeItem(at: legacyURL)

            return url
        } catch {
            throw FaceEnrollmentError.storageFailed(underlying: error)
        }
    }

    // MARK: - Verify (centroid + max-individual)

    func verify(
        currentEmbedding: [Float],
        threshold: Float = FaceEnrollmentService.defaultMatchThreshold
    ) throws -> VerificationResult {
        guard let saved = try Self.loadEmbeddings(), !saved.isEmpty else {
            throw FaceEnrollmentError.notEnrolled
        }

        let centroid = Self.computeCentroid(saved)
        let centroidSim = FaceEmbedder.cosineSimilarity(currentEmbedding, centroid)

        var maxSim: Float = -1
        for emb in saved {
            let sim = FaceEmbedder.cosineSimilarity(currentEmbedding, emb)
            if sim > maxSim { maxSim = sim }
        }

        // Require BOTH centroid and max-individual to clear the threshold.
        // Centroid alone protects against over-fitting to a single weird enrollment frame;
        // max-individual ensures the live face actually resembles some captured pose.
        let matched = centroidSim >= threshold && maxSim >= threshold
        let reported = min(centroidSim, maxSim)

        return VerificationResult(
            matched: matched,
            similarity: reported,
            threshold: threshold,
            centroidSimilarity: centroidSim,
            maxIndividualSimilarity: maxSim,
            enrolledCount: saved.count
        )
    }

    private static func computeCentroid(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var centroid = [Float](repeating: 0, count: first.count)
        for emb in embeddings {
            for i in 0..<emb.count {
                centroid[i] += emb[i]
            }
        }
        let n = Float(embeddings.count)
        for i in 0..<centroid.count {
            centroid[i] /= n
        }
        return FaceEmbedder.l2Normalize(centroid)
    }

    // MARK: - Alignment + fallback crop

    /// Preferred crop path. Tries landmark-based affine alignment (rotates + scales +
    /// translates the source image so the eyes land at InsightFace's canonical
    /// positions in a 112×112 output). Falls back to the axis-aligned 40%-padded
    /// bbox crop if landmarks aren't available or are degenerate.
    private func alignedOrPaddedCrop(pixelBuffer: CVPixelBuffer, face: VNFaceObservation) throws -> CGImage {
        if let landmarks = face.landmarks,
           let leftEye = landmarks.leftEye,
           let rightEye = landmarks.rightEye,
           leftEye.pointCount > 0,
           rightEye.pointCount > 0,
           let aligned = alignFace(in: pixelBuffer, leftEye: leftEye, rightEye: rightEye)
        {
            return aligned
        }
        return try cropFace(in: pixelBuffer, boundingBox: face.boundingBox)
    }

    /// Compute a similarity transform (rotate + uniform scale + translate) that maps
    /// the detected eye positions to InsightFace's canonical positions in a 112×112
    /// output, apply it to the source frame, and return the resulting aligned crop.
    /// Returns nil if landmarks are degenerate — caller falls back to bbox crop.
    private func alignFace(in pixelBuffer: CVPixelBuffer,
                           leftEye: VNFaceLandmarkRegion2D,
                           rightEye: VNFaceLandmarkRegion2D) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageSize = ciImage.extent.size

        // Eye centers in image-pixel space (bottom-left origin — same as Core Image).
        let leftPts = leftEye.pointsInImage(imageSize: imageSize)
        let rightPts = rightEye.pointsInImage(imageSize: imageSize)
        guard !leftPts.isEmpty, !rightPts.isEmpty else { return nil }
        let leftEyeCenter = Self.averagePoint(leftPts)
        let rightEyeCenter = Self.averagePoint(rightPts)

        // InsightFace's canonical eye positions in the 112×112 output (top-left origin
        // in the training convention). Convert to bottom-left origin so we can compose
        // the transform in Core Image's coordinate system.
        let outputSize: CGFloat = 112
        let canonicalLeft = CGPoint(x: 38.2946, y: outputSize - 51.6963)   // ≈ (38.29, 60.30)
        let canonicalRight = CGPoint(x: 73.5318, y: outputSize - 51.5014)  // ≈ (73.53, 60.50)

        // Similarity transform (source → canonical) solved from 2 point correspondences.
        // Source: (l, r); Dest: (l', r'). We want a matrix [[a, -b, tx], [b, a, ty]]
        // such that transform(l) = l' and transform(r) = r'.
        let dx  = rightEyeCenter.x - leftEyeCenter.x
        let dy  = rightEyeCenter.y - leftEyeCenter.y
        let dxp = canonicalRight.x - canonicalLeft.x
        let dyp = canonicalRight.y - canonicalLeft.y
        let normSq = dx * dx + dy * dy
        guard normSq > 1e-6 else { return nil }

        let a = (dx * dxp + dy * dyp) / normSq
        let b = (dx * dyp - dy * dxp) / normSq
        let tx = canonicalLeft.x - (a * leftEyeCenter.x - b * leftEyeCenter.y)
        let ty = canonicalLeft.y - (b * leftEyeCenter.x + a * leftEyeCenter.y)

        // CGAffineTransform lays the matrix out as x' = a*x + c*y + tx, y' = b*x + d*y + ty.
        // Our similarity has c = -b, d = a.
        let transform = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)

        let transformed = ciImage.transformed(by: transform)
        let outputRect = CGRect(x: 0, y: 0, width: outputSize, height: outputSize)
        return ciContext.createCGImage(transformed, from: outputRect)
    }

    // MARK: - Fallback bbox crop (40% padding, unchanged)

    private func cropFace(in pixelBuffer: CVPixelBuffer, boundingBox: CGRect) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageSize = ciImage.extent.size

        var pixelRect = CGRect(
            x: boundingBox.origin.x * imageSize.width,
            y: boundingBox.origin.y * imageSize.height,
            width: boundingBox.width * imageSize.width,
            height: boundingBox.height * imageSize.height
        )
        let padX = pixelRect.width * 0.2
        let padY = pixelRect.height * 0.2
        pixelRect = pixelRect.insetBy(dx: -padX, dy: -padY)
        pixelRect = pixelRect.intersection(ciImage.extent)
        guard !pixelRect.isEmpty else { throw FaceEnrollmentError.croppingFailed }

        let cropped = ciImage.cropped(to: pixelRect)
        guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent) else {
            throw FaceEnrollmentError.croppingFailed
        }
        return cgImage
    }

    // MARK: - Small math helper

    nonisolated private static func averagePoint(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let n = CGFloat(points.count)
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    // MARK: - Storage helpers

    private static func loadEmbeddings() throws -> [[Float]]? {
        let dir = try storageDirectory()
        let encryptedURL = dir.appendingPathComponent(enrolledFilename)
        let legacyURL = dir.appendingPathComponent(legacyEnrolledFilename)
        let fm = FileManager.default

        // Prefer the encrypted file. Requires the session to be unlocked.
        if fm.fileExists(atPath: encryptedURL.path) {
            do {
                let ciphertext = try Data(contentsOf: encryptedURL)
                let plaintext = try PasswordVault.decryptWithSessionKey(ciphertext)
                return try JSONDecoder().decode([[Float]].self, from: plaintext)
            } catch {
                throw FaceEnrollmentError.storageFailed(underlying: error)
            }
        }

        // Fallback: legacy plaintext JSON from pre-encryption versions.
        // Anything loaded via this path will be re-encrypted on the next save.
        if fm.fileExists(atPath: legacyURL.path) {
            do {
                let data = try Data(contentsOf: legacyURL)
                return try JSONDecoder().decode([[Float]].self, from: data)
            } catch {
                throw FaceEnrollmentError.storageFailed(underlying: error)
            }
        }

        return nil
    }

    static func storageDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("FaceUnlock", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func enrolledEmbeddingsURL() throws -> URL {
        try storageDirectory().appendingPathComponent(enrolledFilename)
    }

    static func hasEnrolledFace() -> Bool {
        guard let dir = try? storageDirectory() else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(enrolledFilename).path)
            || fm.fileExists(atPath: dir.appendingPathComponent(legacyEnrolledFilename).path)
    }

    @discardableResult
    static func deleteEnrolledFace() throws -> [URL] {
        let fm = FileManager.default
        let dir = try storageDirectory()
        let staleNames = [enrolledFilename, legacyEnrolledFilename, "embedding.json", "faceprint.bin"]
        var removed: [URL] = []
        for name in staleNames {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
                removed.append(url)
            }
        }
        return removed
    }
}
