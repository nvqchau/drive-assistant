import AVFoundation
import CoreImage
import Foundation
import SwiftUI
import Vision

/// Lightweight Vietnam speed limit sign recognition using Vision OCR + red-ring color verification.
/// No second CoreML model — runs at 2 Hz to avoid thermal throttling.
final class TrafficSignDetector: ObservableObject {
    // MARK: - Published
    @Published private(set) var detectedSpeedLimit: Int?
    @Published private(set) var isProcessing = false

    // MARK: - Configuration
    private let validSpeedLimits: Set<Int> = [30, 40, 50, 60, 70, 80, 90, 100, 120]
    private let roiRect = CGRect(x: 0.48, y: 0.05, width: 0.50, height: 0.50)  // upper-right roadside/gantry
    private let minimumTextHeight: Float = 0.04
    private let processInterval: TimeInterval = 0.5  // 2 Hz
    private let requiredConsecutiveMatches = 2
    private let aspectRatioRange: ClosedRange<Double> = 0.65...1.45
    private let redBorderThreshold: Float = 0.35  // R channel dominance ratio

    // MARK: - State
    private var lastProcessTime: TimeInterval = 0
    private var consecutiveMatchCount = 0
    private var lastMatchedLimit: Int?
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let textRequest = VNRecognizeTextRequest()

    init() {
        configureTextRequest()
    }

    private func configureTextRequest() {
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        textRequest.minimumTextHeight = minimumTextHeight
        textRequest.recognitionLanguages = ["vi-VN", "en-US"]
    }

    /// Call from CameraManager.captureOutput for each frame.
    func processFrameIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard !isProcessing else { return }
        let now = CACurrentMediaTime()
        guard now - lastProcessTime >= processInterval else { return }
        guard thermalState != .critical else { return }

        lastProcessTime = now
        isProcessing = true

        // Run on background queue
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

        // Run Vision OCR
        let handler = VNImageRequestHandler(ciImage: croppedImage, orientation: .up, options: [:])
        do {
            try handler.perform([textRequest])
        } catch {
            print("TrafficSignDetector: OCR error: \(error)")
            return
        }

        guard let observations = textRequest.results as? [VNRecognizedTextObservation] else { return }

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)

            // Must be purely numeric (speed limit)
            guard let speedValue = Int(text), validSpeedLimits.contains(speedValue) else { continue }

            // Verify red ring around the bounding box
            let boundingBox = observation.boundingBox  // normalized to cropped image (origin bottom-left)
            guard verifyRedRing(in: croppedImage, normalizedBox: boundingBox) else { continue }

            // Verify near-square aspect ratio
            let aspectRatio = boundingBox.width / boundingBox.height
            guard aspectRatioRange.contains(aspectRatio) else { continue }

            // Consecutive match logic
            if speedValue == lastMatchedLimit {
                consecutiveMatchCount += 1
            } else {
                consecutiveMatchCount = 1
                lastMatchedLimit = speedValue
            }

            if consecutiveMatchCount >= requiredConsecutiveMatches {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedSpeedLimit = speedValue
                }
                break  // Found valid sign, stop processing this frame
            }
        }
    }

    /// Verify red border pixels around the detected text bounding box.
    /// Expands the box by ~20% and checks for red-ring dominance (R > G and R > B by threshold).
    private func verifyRedRing(in image: CIImage, normalizedBox: CGRect) -> Bool {
        let extent = image.extent
        let pixelBox = CGRect(
            x: normalizedBox.minX * extent.width,
            y: (1 - normalizedBox.maxY) * extent.height,  // Vision origin is bottom-left, CIImage is top-left
            width: normalizedBox.width * extent.width,
            height: normalizedBox.height * extent.height
        )

        // Expand box by 20% to capture the red ring
        let expandFactor: CGFloat = 0.2
        let expandedBox = pixelBox.insetBy(dx: -pixelBox.width * expandFactor, dy: -pixelBox.height * expandFactor)
        let clampedBox = expandedBox.intersection(extent)
        guard !clampedBox.isEmpty, clampedBox.width > 4, clampedBox.height > 4 else { return false }

        // Crop to expanded region
        let ringRegion = image.cropped(to: clampedBox)

        // Render to small buffer for pixel analysis (downsample to ~32x32 max)
        let scale = min(32.0 / clampedBox.width, 32.0 / clampedBox.height, 1.0)
        let scaledImage = ringRegion.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else { return false }
        guard let data = cgImage.dataProvider?.data else { return false }
        let bytes = CFDataGetBytePtr(data)
        let bytesPerPixel = 4
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow

        var redDominantCount = 0
        var totalSampled = 0

        // Sample border pixels only (top, bottom, left, right edges)
        for y in 0..<height {
            for x in [0, width - 1] {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Float(bytes?[offset] ?? 0)
                let g = Float(bytes?[offset + 1] ?? 0)
                let b = Float(bytes?[offset + 2] ?? 0)
                let maxVal = max(r, g, b)
                if maxVal > 30, r > g * (1 + redBorderThreshold), r > b * (1 + redBorderThreshold) {
                    redDominantCount += 1
                }
                totalSampled += 1
            }
        }
        for x in 0..<width {
            for y in [0, height - 1] {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = Float(bytes?[offset] ?? 0)
                let g = Float(bytes?[offset + 1] ?? 0)
                let b = Float(bytes?[offset + 2] ?? 0)
                let maxVal = max(r, g, b)
                if maxVal > 30, r > g * (1 + redBorderThreshold), r > b * (1 + redBorderThreshold) {
                    redDominantCount += 1
                }
                totalSampled += 1
            }
        }

        guard totalSampled > 0 else { return false }
        let ratio = Float(redDominantCount) / Float(totalSampled)
        return ratio > 0.25  // At least 25% of border pixels show red dominance
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
    }
}