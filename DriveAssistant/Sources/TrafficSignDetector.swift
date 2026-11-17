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
    private let minimumTextHeight: Float = 0.04
    private let processInterval: TimeInterval = 0.5  // 2 Hz
    private let requiredConsecutiveMatches = 2
    private let aspectRatioRange: ClosedRange<Double> = 0.65...1.45
    private let redBorderThreshold: Float = 0.35  // R channel dominance ratio

    // DP.134 / DP.135 detection thresholds
    private let endSignRequiredConsecutive = 2
    private let expandedBoxScale: CGFloat = 1.35
    private let redRingStrongThreshold: Float = 0.30
    private let darkDiagonalThreshold: Float = 0.35
    private let contourAspectRatioRange: ClosedRange<Double> = 0.75...1.30
    private let darkLumaThreshold: UInt8 = 90

    // MARK: - State
    private var lastProcessTime: TimeInterval = 0
    private var consecutiveMatchCount = 0
    private var lastMatchedLimit: Int?
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let textRequest = VNRecognizeTextRequest()
    private let contourRequest = VNDetectContoursRequest()

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

        // Crop ROI (normalized coordinates → pixel coordinates)
        let cropRect = CGRect(
            x: roiRect.minX * extent.width,
            y: roiRect.minY * extent.height,
            width: roiRect.width * extent.width,
            height: roiRect.height * extent.height
        )
        let croppedImage = ciImage.cropped(to: cropRect)

        // Run Vision OCR for speed limit digits
        let ocrHandler = VNImageRequestHandler(ciImage: croppedImage, orientation: .up, options: [:])
        var textObservations: [VNRecognizedTextObservation] = []
        do {
            try ocrHandler.perform([textRequest])
            textObservations = textRequest.results as? [VNRecognizedTextObservation] ?? []
        } catch {
            print("TrafficSignDetector: OCR error: \(error)")
        }

        var foundActiveSpeedLimit: Int?
        var foundEndOfSpeedLimit = false

        // Process OCR results for speed limit signs (P.127) and end-of-speed-limit (DP.134)
        for observation in textObservations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)

            // Must be purely numeric (speed limit)
            guard let speedValue = Int(text), validSpeedLimits.contains(speedValue) else { continue }

            let boundingBox = observation.boundingBox  // normalized to cropped image (origin bottom-left)

            // Verify near-square aspect ratio
            let aspectRatio = boundingBox.width / boundingBox.height
            guard aspectRatioRange.contains(aspectRatio) else { continue }

            // Classify: check red ring strength on expanded box (1.35x)
            let redRingRatio = measureRedRingRatio(in: croppedImage, normalizedBox: boundingBox, scale: expandedBoxScale)

            if redRingRatio >= redRingStrongThreshold {
                // Strong red ring → active speed limit P.127
                foundActiveSpeedLimit = speedValue
            } else {
                // Weak/absent red ring → check for dark diagonal slash (DP.134)
                let darkDiagonalRatio = measureDarkDiagonalRatio(in: croppedImage, normalizedBox: boundingBox, scale: expandedBoxScale)
                if darkDiagonalRatio >= darkDiagonalThreshold {
                    foundEndOfSpeedLimit = true
                }
            }
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
                    // VNContour has normalizedPoints - compute bounding box from points
                    let points = contour.normalizedPoints
                    guard !points.isEmpty else { continue }
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
                    let boundingBox = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
                    let aspectRatio = boundingBox.width / boundingBox.height
                    guard contourAspectRatioRange.contains(aspectRatio) else { continue }
                    guard boundingBox.width >= 0.04 && boundingBox.height >= 0.04 else { continue }

                    // Check for dark diagonal slash inside this near-circular contour
                    let darkDiagonalRatio = measureDarkDiagonalRatio(in: croppedImage, normalizedBox: boundingBox, scale: 1.0)
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
            endSignConsecutiveCount = 0
            lastEndSignType = nil
            lastMatchedLimit = nil
            consecutiveMatchCount = 0
        }
    }

    /// Measure red ring strength on expanded bounding box.
    /// Returns ratio of border pixels where R > 145 && R > G*1.4 && R > B*1.4
    private func measureRedRingRatio(in image: CIImage, normalizedBox: CGRect, scale: CGFloat) -> Float {
        let extent = image.extent
        let pixelBox = CGRect(
            x: normalizedBox.minX * extent.width,
            y: (1 - normalizedBox.maxY) * extent.height,
            width: normalizedBox.width * extent.width,
            height: normalizedBox.height * extent.height
        )

        let expandedBox = pixelBox.insetBy(dx: -pixelBox.width * (scale - 1.0) / 2.0,
                                           dy: -pixelBox.height * (scale - 1.0) / 2.0)
        let clampedBox = expandedBox.intersection(extent)
        guard !clampedBox.isEmpty, clampedBox.width > 4, clampedBox.height > 4 else { return 0 }

        let ringRegion = image.cropped(to: clampedBox)
        let scaleFactor = min(32.0 / clampedBox.width, 32.0 / clampedBox.height, 1.0)
        let scaledImage = ringRegion.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))

        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else { return 0 }
        guard let data = cgImage.dataProvider?.data else { return 0 }
        let bytes = CFDataGetBytePtr(data)
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow

        var redStrongCount = 0
        var totalSampled = 0

        // Sample border pixels only
        for y in 0..<height {
            for x in [0, width - 1] {
                let offset = y * bytesPerRow + x * 4
                let r = bytes?[offset] ?? 0
                let g = bytes?[offset + 1] ?? 0
                let b = bytes?[offset + 2] ?? 0
                if r >= 145, Float(r) > Float(g) * 1.4, Float(r) > Float(b) * 1.4 {
                    redStrongCount += 1
                }
                totalSampled += 1
            }
        }
        for x in 0..<width {
            for y in [0, height - 1] {
                let offset = y * bytesPerRow + x * 4
                let r = bytes?[offset] ?? 0
                let g = bytes?[offset + 1] ?? 0
                let b = bytes?[offset + 2] ?? 0
                if r >= 145, Float(r) > Float(g) * 1.4, Float(r) > Float(b) * 1.4 {
                    redStrongCount += 1
                }
                totalSampled += 1
            }
        }

        guard totalSampled > 0 else { return 0 }
        return Float(redStrongCount) / Float(totalSampled)
    }

    /// Measure dark diagonal slash ratio (top-right to bottom-left anti-diagonal).
    /// Samples band where |(1 - u) - v| < 0.14 in normalized box coordinates.
    private func measureDarkDiagonalRatio(in image: CIImage, normalizedBox: CGRect, scale: CGFloat) -> Float {
        let extent = image.extent
        let pixelBox = CGRect(
            x: normalizedBox.minX * extent.width,
            y: (1 - normalizedBox.maxY) * extent.height,
            width: normalizedBox.width * extent.width,
            height: normalizedBox.height * extent.height
        )

        let expandedBox = pixelBox.insetBy(dx: -pixelBox.width * (scale - 1.0) / 2.0,
                                           dy: -pixelBox.height * (scale - 1.0) / 2.0)
        let clampedBox = expandedBox.intersection(extent)
        guard !clampedBox.isEmpty, clampedBox.width > 4, clampedBox.height > 4 else { return 0 }

        let ringRegion = image.cropped(to: clampedBox)
        let scaleFactor = min(48.0 / clampedBox.width, 48.0 / clampedBox.height, 1.0)
        let scaledImage = ringRegion.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))

        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else { return 0 }
        guard let data = cgImage.dataProvider?.data else { return 0 }
        let bytes = CFDataGetBytePtr(data)
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow

        var darkDiagonalCount = 0
        var totalSampled = 0

        // Sample pixels along anti-diagonal band: |(1 - u) - v| < 0.14
        // where u = x/width, v = y/height (both 0..1 from top-left)
        for y in 0..<height {
            let v = Float(y) / Float(height)
            for x in 0..<width {
                let u = Float(x) / Float(width)
                let antiDiagDist = abs((1.0 - u) - v)
                if antiDiagDist < 0.14 {
                    let offset = y * bytesPerRow + x * 4
                    let r = Float(bytes?[offset] ?? 0)
                    let g = Float(bytes?[offset + 1] ?? 0)
                    let b = Float(bytes?[offset + 2] ?? 0)
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