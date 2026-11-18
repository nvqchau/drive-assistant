import AVFoundation
import CoreImage
import Foundation
import SwiftUI
import Vision

/// Lightweight Vietnam speed limit sign recognition using Vision OCR + red-ring color verification.
/// Also detects DP.134 (End of Speed Limit) and DP.135 (End of All Restrictions) signs
/// via pixel/contour analysis — no second CoreML model, runs at 2 Hz.
final class TrafficSignDetector: ObservableObject {
    // MARK: - Published
    @Published private(set) var detectedSpeedLimit: Int?
    @Published private(set) var isProcessing = false
    @Published private(set) var didClearSpeedLimitEvent: Date?  // fires when DP.134/DP.135 clears limit

    // MARK: - Configuration
    private let validSpeedLimits: Set<Int> = [30, 40, 50, 60, 70, 80, 90, 100, 120]
    private let roiRect = CGRect(x: 0.48, y: 0.05, width: 0.50, height: 0.50)  // upper-right roadside/gantry
    private let minimumTextHeight: Float = 0.018  // 1.8% of crop height for distant/medium signs
    private let processInterval: TimeInterval = 0.5  // 2 Hz
    private let requiredConsecutiveMatches = 2
    private let aspectRatioRange: ClosedRange<Double> = 0.45...2.0  // widened for tall/narrow digits (e.g., "60" ar≈0.62)
    private let redBorderThreshold: Float = 0.35  // R channel dominance ratio

    // DP.134 / DP.135 detection thresholds
    private let endSignRequiredConsecutive = 2
    private let expandedBoxScale: CGFloat = 4.0   // square-normalized: side = max(w,h) * 4.0 (encompasses full sign; red ring at ~1.5x digit height)
    private let redRingStrongThreshold: Float = 0.03  // very low for screen photo
    private let darkDiagonalThreshold: Float = 0.35
    private let contourAspectRatioRange: ClosedRange<Double> = 0.75...1.30
    private let darkLumaThreshold: UInt8 = 90

    // Circular annulus sampling for red ring (normalized radius from center of square)
    private let redRingInnerRadius: Float = 0.25
    private let redRingOuterRadius: Float = 0.85
    private let redPixelThreshold: UInt8 = 60   // very low for screen photo glare
    private let redDominanceRatio: Float = 1.0  // minimal dominance (R >= G, R >= B)

    // MARK: - State
    private var lastProcessTime: TimeInterval = 0
    private var consecutiveMatchCount = 0
    private var lastMatchedLimit: Int?
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let textRequest = VNRecognizeTextRequest()
    private let contourRequest = VNDetectContoursRequest()

    // Diagnostics
    private weak var diagnostics: DiagnosticsLogStore?
    private var visionOrientation: CGImagePropertyOrientation = .up
    private var lastTSRLogTime: TimeInterval = 0

    // End-sign consecutive detection state
    private var endSignConsecutiveCount = 0
    private var lastEndSignType: EndSignType?

    enum EndSignType {
        case dp134  // End of Speed Limit (has digits + diagonal slash)
        case dp135  // End of All Restrictions (no digits, circular with diagonal)
    }

    init() {
        configureTextRequest()
        configureContourRequest()
    }

    /// Attach diagnostics store for TSR event logging
    func attachDiagnostics(_ diagnostics: DiagnosticsLogStore) {
        self.diagnostics = diagnostics
    }

    /// Set vision orientation (matches CameraManager's visionOrientation)
    func setVisionOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation = orientation
    }

    private func configureTextRequest() {
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        textRequest.minimumTextHeight = minimumTextHeight
        textRequest.recognitionLanguages = ["vi-VN", "en-US"]
    }

    private func configureContourRequest() {
        contourRequest.contrastAdjustment = 1.2
        contourRequest.detectDarkOnLight = true
        contourRequest.maximumImageDimension = 512
    }

    /// Call from CameraManager.captureOutput for each frame.
    func processFrameIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard !isProcessing else { return }
        let now = CACurrentMediaTime()
        guard now - lastProcessTime >= processInterval else { return }
        guard thermalState != .critical else { return }

        lastProcessTime = now
        isProcessing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processFrame(pixelBuffer)
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        defer { isProcessing = false }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent

        // Crop ROI: roiRect uses top-left origin (0,0 = top-left), CIImage uses bottom-left origin
        // Convert: CIImage y = (1 - topLeftY - height) * extent.height
        let cropRect = CGRect(
            x: roiRect.minX * extent.width,
            y: (1.0 - roiRect.maxY) * extent.height,
            width: roiRect.width * extent.width,
            height: roiRect.height * extent.height
        )
        let croppedImage = ciImage.cropped(to: cropRect)

        // Run Vision OCR for speed limit digits
        let ocrHandler = VNImageRequestHandler(ciImage: croppedImage, orientation: visionOrientation, options: [:])
        var textObservations: [VNRecognizedTextObservation] = []
        do {
            try ocrHandler.perform([textRequest])
            textObservations = textRequest.results as? [VNRecognizedTextObservation] ?? []
        } catch {
            print("TrafficSignDetector: OCR error: \(error)")
        }

        var foundActiveSpeedLimit: Int?
        var foundEndOfSpeedLimit = false

        // For diagnostics: collect all candidate details
        struct TSRCandidate {
            let rawText: String
            let speedValue: Int?
            let boundingBox: CGRect
            let aspectRatio: Double
            let redRingRatio: Float
            let darkDiagonalRatio: Float
            let accepted: Bool
            let reason: String
        }
        var candidates: [TSRCandidate] = []

        // Process OCR results for speed limit signs (P.127) and end-of-speed-limit (DP.134)
        for observation in textObservations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract numeric tokens from text (handles "P.127 60", "60 km/h", etc.)
            let tokens = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }
                .filter { validSpeedLimits.contains($0) }
            let speedValue = tokens.first

            let cropBox = observation.boundingBox  // normalized to cropped image (origin bottom-left)

            // Convert crop-normalized bbox to full-image normalized bbox
            // roiRect uses top-left origin; Vision/CIImage use bottom-left.
            // Crop starts at bottom-left y = (1 - roiRect.maxY)
            let cropOriginY = 1.0 - roiRect.maxY
            let boundingBox = CGRect(
                x: roiRect.minX + cropBox.minX * roiRect.width,
                y: cropOriginY + cropBox.minY * roiRect.height,
                width: cropBox.width * roiRect.width,
                height: cropBox.height * roiRect.height
            )

            // Verify near-square aspect ratio (use crop box for aspect since sign is upright in crop)
            let aspectRatio = cropBox.width / cropBox.height
            let aspectOK = aspectRatioRange.contains(aspectRatio)

            // Classify: check red ring strength on expanded box using FULL image (avoids crop-edge clamping)
            let redRingRatio = measureRedRingRatio(in: ciImage, normalizedBox: boundingBox, scale: expandedBoxScale)
            let darkDiagonalRatio = measureDarkDiagonalRatio(in: ciImage, normalizedBox: boundingBox, scale: expandedBoxScale)

            var accepted = false
            var reason = ""

            if speedValue != nil && aspectOK {
                if redRingRatio >= redRingStrongThreshold {
                    accepted = true
                    reason = "P127_active"
                } else if darkDiagonalRatio >= darkDiagonalThreshold {
                    accepted = true
                    reason = "DP134_end"
                } else {
                    reason = "aspectOK_redRing=\(String(format: "%.2f", redRingRatio))_darkDiag=\(String(format: "%.2f", darkDiagonalRatio))"
                }
            } else if speedValue == nil {
                reason = "no_valid_speed_token"
            } else {
                reason = "aspect_fail=\(String(format: "%.2f", aspectRatio))"
            }

            if let sv = speedValue, accepted {
                if reason == "P127_active" {
                    foundActiveSpeedLimit = sv
                } else if reason == "DP134_end" {
                    foundEndOfSpeedLimit = true
                }
            }

            candidates.append(TSRCandidate(
                rawText: text,
                speedValue: speedValue,
                boundingBox: boundingBox,
                aspectRatio: aspectRatio,
                redRingRatio: redRingRatio,
                darkDiagonalRatio: darkDiagonalRatio,
                accepted: accepted && speedValue != nil,
                reason: reason
            ))
        }

        // Diagnostic logging: every 1.0s record all raw OCR candidates with analysis
        let now = CACurrentMediaTime()
        if now - lastTSRLogTime >= 1.0 {
            lastTSRLogTime = now
            let details = candidates.map { c in
                "txt=\(c.rawText) spd=\(c.speedValue?.description ?? "nil") box=(\(String(format: "%.3f", c.boundingBox.minX)),\(String(format: "%.3f", c.boundingBox.minY)),\(String(format: "%.3f", c.boundingBox.width)),\(String(format: "%.3f", c.boundingBox.height))) ar=\(String(format: "%.2f", c.aspectRatio)) rr=\(String(format: "%.2f", c.redRingRatio)) dd=\(String(format: "%.2f", c.darkDiagonalRatio)) acc=\(c.accepted) reason=\(c.reason)"
            }.joined(separator: "; ")
            diagnostics?.record(type: "tsr_scan", details: details.isEmpty ? "no_candidates" : details)
        }

        // Also run contour detection for DP.135 (End of All Restrictions - no digits)
        let contourHandler = VNImageRequestHandler(ciImage: croppedImage, orientation: .up, options: [:])
        do {
            try contourHandler.perform([contourRequest])
        } catch {
            print("TrafficSignDetector: Contour error: \(error)")
        }

        var foundEndOfAllRestrictions = false
        if let contours = contourRequest.results as? [VNContoursObservation] {
            for contourObs in contours {
                for contour in contourObs.topLevelContours {
                    // VNContour has normalizedPoints - compute bounding box from points (crop-normalized)
                    let points = contour.normalizedPoints
                    guard !points.isEmpty, points.count >= 3 else { continue } // Need at least 3 points for a shape
                    var minX: Float = points[0].x
                    var maxX: Float = points[0].x
                    var minY: Float = points[0].y
                    var maxY: Float = points[0].y
                    for pt in points {
                        minX = Swift.min(minX, pt.x)
                        maxX = Swift.max(maxX, pt.x)
                        minY = Swift.min(minY, pt.y)
                        maxY = Swift.max(maxY, pt.y)
                    }
                    let cropBox = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
                    guard cropBox.width > 0, cropBox.height > 0 else { continue }
                    let aspectRatio = cropBox.width / cropBox.height
                    guard contourAspectRatioRange.contains(aspectRatio) else { continue }
                    guard cropBox.width >= 0.04 && cropBox.height >= 0.04 else { continue }

                    // Convert crop-normalized bbox to full-image normalized bbox
                    // roiRect uses top-left origin; Vision/CIImage use bottom-left.
                    let cropOriginY = 1.0 - roiRect.maxY
                    let boundingBox = CGRect(
                        x: roiRect.minX + cropBox.minX * roiRect.width,
                        y: cropOriginY + cropBox.minY * roiRect.height,
                        width: cropBox.width * roiRect.width,
                        height: cropBox.height * roiRect.height
                    )

                    // Check for dark diagonal slash using FULL image
                    let darkDiagonalRatio = measureDarkDiagonalRatio(in: ciImage, normalizedBox: boundingBox, scale: 1.0)
                    if darkDiagonalRatio >= 0.40 {
                        foundEndOfAllRestrictions = true
                        break
                    }
                }
                if foundEndOfAllRestrictions { break }
            }
        }

        // Handle active speed limit detection (P.127)
        if let limit = foundActiveSpeedLimit {
            endSignConsecutiveCount = 0
            lastEndSignType = nil

            if limit == lastMatchedLimit {
                consecutiveMatchCount += 1
            } else {
                consecutiveMatchCount = 1
                lastMatchedLimit = limit
            }

            if consecutiveMatchCount >= requiredConsecutiveMatches {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedSpeedLimit = limit
                }
                diagnostics?.record(type: "tsr_state", details: "action=P127_confirmed limit=\(limit) consecutive=\(consecutiveMatchCount)")
            }
        }
        // Handle end-of-speed-limit detection (DP.134)
        else if foundEndOfSpeedLimit && detectedSpeedLimit != nil {
            handleEndSignDetection(.dp134)
        }
        // Handle end-of-all-restrictions detection (DP.135)
        else if foundEndOfAllRestrictions && detectedSpeedLimit != nil {
            handleEndSignDetection(.dp135)
        }
        // No relevant sign detected - reset end-sign counter
        else {
            endSignConsecutiveCount = 0
            lastEndSignType = nil
        }
    }

    private func handleEndSignDetection(_ type: EndSignType) {
        if type == lastEndSignType {
            endSignConsecutiveCount += 1
        } else {
            endSignConsecutiveCount = 1
            lastEndSignType = type
        }

        if endSignConsecutiveCount >= endSignRequiredConsecutive {
            DispatchQueue.main.async { [weak self] in
                self?.detectedSpeedLimit = nil
                self?.didClearSpeedLimitEvent = Date()
            }
            diagnostics?.record(type: "tsr_state", details: "action=\(type)_confirmed cleared_limit=\(lastMatchedLimit?.description ?? "nil")")
            endSignConsecutiveCount = 0
            lastEndSignType = nil
            lastMatchedLimit = nil
            consecutiveMatchCount = 0
        }
    }

    /// Measure red ring strength using square-normalized bbox around digits.
    /// OCR bbox wraps tall/narrow digits (e.g., 0.065×0.100). We center a square of
    /// side = max(w,h) * expandedBoxScale (≈2.1) on the digit center — this encompasses
    /// the full sign's red ring. Annulus sampled at normalized radius [0.35, 0.75].
    private func measureRedRingRatio(in image: CIImage, normalizedBox: CGRect, scale: CGFloat) -> Float {
        return autoreleasepool {
            let extent = image.extent
            // Vision boundingBox uses bottom-left origin, matching CIImage
            let digitBox = CGRect(
                x: normalizedBox.minX * extent.width,
                y: normalizedBox.minY * extent.height,
                width: normalizedBox.width * extent.width,
                height: normalizedBox.height * extent.height
            )

            // Guard against degenerate digit boxes
            guard digitBox.width > 0, digitBox.height > 0 else { return 0 }

            // Square box centered on digits, sized to encompass sign's red ring
            let side = max(digitBox.width, digitBox.height) * scale
            // Cap max square side to 200px (we scale down to 48px anyway) to limit memory
            let cappedSide = min(side, 200.0)
            let squareBox = CGRect(
                x: digitBox.midX - cappedSide / 2.0,
                y: digitBox.midY - cappedSide / 2.0,
                width: cappedSide,
                height: cappedSide
            )
            let clampedBox = squareBox.intersection(extent)
            guard !clampedBox.isEmpty, clampedBox.width > 4, clampedBox.height > 4 else { return 0 }

            let ringRegion = image.cropped(to: clampedBox)
            let scaleFactor = min(48.0 / clampedBox.width, 48.0 / clampedBox.height, 1.0)
            let scaledImage = ringRegion.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))

            // Render with explicit RGBA8 format to guarantee R=bytes[0], G=bytes[1], B=bytes[2]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent, format: .RGBA8, colorSpace: colorSpace) else { return 0 }
            guard let data = cgImage.dataProvider?.data else { return 0 }
            let bytes = CFDataGetBytePtr(data)
            guard let bytes = bytes else { return 0 }
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerRow = cgImage.bytesPerRow
            guard width > 0, height > 0, bytesPerRow >= width * 4 else { return 0 }
            // Ensure we have enough data bytes
            let expectedBytes = height * bytesPerRow
            guard CFDataGetLength(data) >= expectedBytes else { return 0 }

            var redStrongCount = 0
            var totalSampled = 0

            // Sample pixels in circular annulus: center (0.5, 0.5), radius in [0.35, 0.75]
            for y in 0..<height {
                let v = Float(y) / Float(height)
                let dy = v - 0.5
                for x in 0..<width {
                    let u = Float(x) / Float(width)
                    let dx = u - 0.5
                    let r = hypotf(dx, dy)
                    guard r >= redRingInnerRadius, r <= redRingOuterRadius else { continue }

                    let offset = y * bytesPerRow + x * 4
                    // Bounds check
                    guard offset + 2 < expectedBytes else { continue }
                    let rVal = bytes[offset]
                    let gVal = bytes[offset + 1]
                    let bVal = bytes[offset + 2]
                    if rVal >= redPixelThreshold,
                       Float(rVal) > Float(gVal) * redDominanceRatio,
                       Float(rVal) > Float(bVal) * redDominanceRatio {
                        redStrongCount += 1
                    }
                    totalSampled += 1
                }
            }

            guard totalSampled > 0 else { return 0 }
            return Float(redStrongCount) / Float(totalSampled)
        }
    }

    /// Measure dark diagonal slash ratio using square-normalized bbox around digits.
    /// Same square expansion as red ring. Samples anti-diagonal band |(1-u)-v| < 0.14.
    private func measureDarkDiagonalRatio(in image: CIImage, normalizedBox: CGRect, scale: CGFloat) -> Float {
        return autoreleasepool {
            let extent = image.extent
            let digitBox = CGRect(
                x: normalizedBox.minX * extent.width,
                y: normalizedBox.minY * extent.height,
                width: normalizedBox.width * extent.width,
                height: normalizedBox.height * extent.height
            )

            // Guard against degenerate digit boxes
            guard digitBox.width > 0, digitBox.height > 0 else { return 0 }

            // Square box centered on digits, sized to encompass sign
            let side = max(digitBox.width, digitBox.height) * scale
            // Cap max square side to 200px (we scale down to 48px anyway) to limit memory
            let cappedSide = min(side, 200.0)
            let squareBox = CGRect(
                x: digitBox.midX - cappedSide / 2.0,
                y: digitBox.midY - cappedSide / 2.0,
                width: cappedSide,
                height: cappedSide
            )
            let clampedBox = squareBox.intersection(extent)
            guard !clampedBox.isEmpty, clampedBox.width > 4, clampedBox.height > 4 else { return 0 }

            let ringRegion = image.cropped(to: clampedBox)
            let scaleFactor = min(48.0 / clampedBox.width, 48.0 / clampedBox.height, 1.0)
            let scaledImage = ringRegion.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent, format: .RGBA8, colorSpace: colorSpace) else { return 0 }
            guard let data = cgImage.dataProvider?.data else { return 0 }
            let bytes = CFDataGetBytePtr(data)
            guard let bytes = bytes else { return 0 }
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerRow = cgImage.bytesPerRow
            guard width > 0, height > 0, bytesPerRow >= width * 4 else { return 0 }
            let expectedBytes = height * bytesPerRow
            guard CFDataGetLength(data) >= expectedBytes else { return 0 }

            var darkDiagonalCount = 0
            var totalSampled = 0

            // Sample pixels along anti-diagonal band: |(1 - u) - v| < 0.14
            for y in 0..<height {
                let v = Float(y) / Float(height)
                for x in 0..<width {
                    let u = Float(x) / Float(width)
                    let antiDiagDist = abs((1.0 - u) - v)
                    if antiDiagDist < 0.14 {
                        let offset = y * bytesPerRow + x * 4
                        // Bounds check
                        guard offset + 2 < expectedBytes else { continue }
                        let r = Float(bytes[offset])
                        let g = Float(bytes[offset + 1])
                        let b = Float(bytes[offset + 2])
                        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        if luma < Float(darkLumaThreshold) {
                            darkDiagonalCount += 1
                        }
                        totalSampled += 1
                    }
                }
            }

            guard totalSampled > 0 else { return 0 }
            return Float(darkDiagonalCount) / Float(totalSampled)
        }
    }

    /// Update thermal state (called from CameraManager)
    func setThermalState(_ state: ProcessInfo.ThermalState) {
        thermalState = state
    }

    /// Manual clear — tap action on HUD badge
    func clearDetectedLimit() {
        detectedSpeedLimit = nil
        lastMatchedLimit = nil
        consecutiveMatchCount = 0
        endSignConsecutiveCount = 0
        lastEndSignType = nil
        didClearSpeedLimitEvent = nil
    }
}