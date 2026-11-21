import CoreImage
import SwiftUI
import CoreML
import Foundation
import os
import Vision
import UIKit

/// Lightweight lane detection using CoreImage + Vision contours (no second CoreML model)
/// Detects white/yellow lane markings in the lower road ROI, fits left/right boundaries with EMA
final class LaneDetector: ObservableObject {
    // MARK: - Published State
    @Published private(set) var leftLanePoints: [CGPoint] = []
    @Published private(set) var rightLanePoints: [CGPoint] = []
    @Published private(set) var isLaneDetectionActive = false
    @Published private(set) var leftLaneConfidence: Float = 0
    @Published private(set) var rightLaneConfidence: Float = 0
    @Published private(set) var departureState: DepartureState = .none
    @Published private(set) var departureAlertActive = false
    @Published private(set) var isSpeedGated = false  // true when GPS speed < ldwsMinSpeedKmh

    // MARK: - Departure State Machine
    enum DepartureState: Equatable {
        case none
        case driftingLeft
        case driftingRight

        var color: Color {
            switch self {
            case .none: return .cyan
            case .driftingLeft, .driftingRight: return .orange
            }
        }
    }

    // MARK: - Private Properties
    private let queue = DispatchQueue(label: "drive-assistant.lane-detector", qos: .userInitiated)
    private let logger = Logger(subsystem: "vn.ai.driveassistant", category: "LaneDetector")
    private let ciContext = CIContext()
    private weak var diagnostics: DiagnosticsLogStore?
    private var lastDepartureAlertActive = false
    private var lastDynamicMode = false
    private var lastModeChangeTime: TimeInterval = 0

    // Thread-safety lock for config accessed from main thread (setROIOffset, setLDWSEnabled, setMinSpeedForDepartureAlert)
    // and background queue (detectLanes, checkLaneDeparture)
    private let configLock = NSLock()

    // EMA smoothing for lane boundaries (α = 0.25 for steady rails over dashed lines)
    private var emaLeftLane: [CGPoint]?
    private var emaRightLane: [CGPoint]?
    private let emaAlpha: CGFloat = 0.25

    // Grace window: hold last confident fit for 0.5s (~15 frames at 30fps) before fading
    private var framesSinceConfidentLeft = 0
    private var framesSinceConfidentRight = 0
    private let graceFrames = 15

    // Lane departure state machine
    private var leftDepartureStartTime: TimeInterval?
    private var rightDepartureStartTime: TimeInterval?
    private var lastDepartureAlertTime: TimeInterval = 0
    private let departurePersistenceThreshold: TimeInterval = 0.4  // 0.4s debounce
    private let departureCooldown: TimeInterval = 3.0               // 3s cooldown
    private var minSpeedForDepartureAlert: Double = 50.0            // km/h (configurable, default 50)
    private let departureThresholdRatio: CGFloat = 0.08             // 8% of lane width

    // ROI trapezoid params (matching CameraManager static ROI)
    private let roiTopY: CGFloat = 0.38
    private let roiBottomY: CGFloat = 0.95
    private let roiTopWidth: CGFloat = 0.16
    private let roiBottomWidth: CGFloat = 0.54  // widened from 0.42 to match real road markings
    private var roiCenterOffsetX: CGFloat = -0.03

    // LDWS enabled flag
    private var isLDWSEnabled = true
    
    func setROIOffset(_ offset: Double) {
        configLock.lock()
        roiCenterOffsetX = CGFloat(offset)
        configLock.unlock()
    }

    func setLDWSEnabled(_ enabled: Bool) {
        configLock.lock()
        isLDWSEnabled = enabled
        configLock.unlock()
    }

    func setMinSpeedForDepartureAlert(_ speedKmh: Double) {
        configLock.lock()
        minSpeedForDepartureAlert = speedKmh
        configLock.unlock()
    }

    func attachDiagnostics(_ diagnostics: DiagnosticsLogStore) {
        self.diagnostics = diagnostics
    }

    func processFrame(pixelBuffer: CVPixelBuffer, speedKMPH: Double) {
        queue.async { [weak self] in
            self?.detectLanes(pixelBuffer: pixelBuffer, speedKMPH: speedKMPH)
        }
    }
    
    private func detectLanes(pixelBuffer: CVPixelBuffer, speedKMPH: Double) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Crop to lower road region (ROI trapezoid area)
        let cropRect = calculateROICropRect(imageExtent: image.extent)
        let croppedImage = image.cropped(to: cropRect)
        
        // Enhance lane markings: white + yellow color filter
        let enhancedImage = enhanceLaneMarkings(croppedImage)
        
        // Detect contours on enhanced image
        let contours = detectContours(enhancedImage, extent: cropRect)
        
        // Filter for lane-like line segments (pass cropRect for coordinate mapping)
        let (leftLines, rightLines) = classifyLaneLines(contours, cropRect: cropRect, imageSize: CGSize(width: width, height: height))
        
        // Fit polynomial curves to lane lines
        let (leftFit, rightFit) = fitLaneCurves(leftLines: leftLines, rightLines: rightLines, imageSize: CGSize(width: width, height: height))
        
        // Apply EMA smoothing with grace window
        let (smoothedLeft, smoothedRight, leftConf, rightConf) = applyEMAWithGrace(leftFit: leftFit, rightFit: rightFit)
        
        // Update published properties on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.leftLanePoints = smoothedLeft
            self.rightLanePoints = smoothedRight
            self.leftLaneConfidence = leftConf
            self.rightLaneConfidence = rightConf
            self.isLaneDetectionActive = leftConf > 0.5 || rightConf > 0.5

            // Update speed gating status for HUD
            self.configLock.lock()
            let minSpeed = self.minSpeedForDepartureAlert
            let roiOffset = self.roiCenterOffsetX
            self.configLock.unlock()
            self.isSpeedGated = speedKMPH < minSpeed

            // Lane-mode transition logging (throttled to 5s)
            let dynamicMode = leftConf > 0.5 && rightConf > 0.5
            if dynamicMode != self.lastDynamicMode {
                let now = CACurrentMediaTime()
                if now - self.lastModeChangeTime >= 5.0 {
                    self.lastModeChangeTime = now
                    self.diagnostics?.record(type: "ldws_mode_changed",
                        details: "dynamic=\(dynamicMode), leftConf=\(String(format: "%.2f", leftConf)), rightConf=\(String(format: "%.2f", rightConf)), speedKMPH=\(String(format: "%.1f", speedKMPH))")
                }
                self.lastDynamicMode = dynamicMode
            }

            // Check lane departure with anti-false-positive logic
            self.checkLaneDeparture(speedKMPH: speedKMPH, vehicleCenterX: 0.5 + Double(roiOffset))
        }
    }
    
    private func calculateROICropRect(imageExtent: CGRect) -> CGRect {
        let topY = imageExtent.height * roiTopY
        let bottomY = imageExtent.height * roiBottomY
        return CGRect(x: 0, y: topY, width: imageExtent.width, height: bottomY - topY)
    }
    
    private func enhanceLaneMarkings(_ image: CIImage) -> CIImage {
        let gray = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.8,
            kCIInputBrightnessKey: 0.1
        ])

        let whiteMask = gray.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": 0.58
        ])
        
        let yellowMask = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 2.0,
            kCIInputContrastKey: 1.2
        ]).applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": 0.5
        ])
        
        let combined = whiteMask.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: yellowMask
        ])
        
        let cleaned = combined
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2])
        
        return cleaned
    }
    
    private func detectContours(_ image: CIImage, extent: CGRect) -> [VNContour] {
        var contours: [VNContour] = []
        
        let request = VNDetectContoursRequest { request, error in
            if let error = error {
                self.logger.error("Contour detection failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            contours = request.results as? [VNContour] ?? []
        }
        
        request.contrastAdjustment = 1.0
        request.detectDarkOnLight = false
        
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("VN handler failed: \(error.localizedDescription, privacy: .public)")
        }
        
        return contours
    }
    
    private func classifyLaneLines(_ contours: [VNContour], cropRect: CGRect, imageSize: CGSize) -> (left: [VNContour], right: [VNContour]) {
        var leftLines: [VNContour] = []
        var rightLines: [VNContour] = []

        configLock.lock()
        let normalizedRoiCenterX = 0.5 + roiCenterOffsetX
        configLock.unlock()

        for contour in contours {
            let points = contour.normalizedPoints
            guard points.count >= 4 else { continue }

            // Map contour points from cropped image back to full normalized screen coordinates
            // VNContour.normalizedPoints are in 0...1 relative to cropRect
            // Convert to full image normalized coordinates (top-left origin, 0...1)
            let xs = points.map {
                (cropRect.minX + CGFloat($0.x) * cropRect.width) / CGFloat(imageSize.width)
            }
            let ys = points.map {
                1.0 - ((cropRect.minY + CGFloat($0.y) * cropRect.height) / CGFloat(imageSize.height))
            }

            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 1
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? 1
            let width = maxX - minX
            let height = maxY - minY
            let aspectRatio = width / max(height, 1)

            guard aspectRatio > 1.5 || (1/aspectRatio) > 1.5 else { continue }

            let area = width * height
            guard area > 0.0001 && area < 0.15 else { continue }

            let contourCenterX = (minX + maxX) / 2
            if contourCenterX < normalizedRoiCenterX {
                leftLines.append(contour)
            } else {
                rightLines.append(contour)
            }
        }

        return (leftLines, rightLines)
    }
    
    private func fitLaneCurves(leftLines: [VNContour], rightLines: [VNContour], imageSize: CGSize) -> (left: [CGPoint]?, right: [CGPoint]?) {
        let leftPoints = sampleContourPoints(leftLines, cropRect: calculateROICropRect(imageExtent: CGRect(origin: .zero, size: imageSize)), imageSize: imageSize, isLeft: true)
        let rightPoints = sampleContourPoints(rightLines, cropRect: calculateROICropRect(imageExtent: CGRect(origin: .zero, size: imageSize)), imageSize: imageSize, isLeft: false)

        let leftFit = fitLinear(points: leftPoints, imageSize: imageSize, isLeft: true)
        let rightFit = fitLinear(points: rightPoints, imageSize: imageSize, isLeft: false)

        return (leftFit, rightFit)
    }

    private func sampleContourPoints(_ contours: [VNContour], cropRect: CGRect, imageSize: CGSize, isLeft: Bool) -> [CGPoint] {
        var points: [CGPoint] = []

        for contour in contours {
            let normalizedPoints = contour.normalizedPoints
            for normalizedPoint in normalizedPoints {
                // Map from cropRect normalized to full screen normalized (top-left origin)
                let normX = (cropRect.minX + CGFloat(normalizedPoint.x) * cropRect.width) / CGFloat(imageSize.width)
                let normYFromTop = 1.0 - ((cropRect.minY + CGFloat(normalizedPoint.y) * cropRect.height) / CGFloat(imageSize.height))
                points.append(CGPoint(x: normX, y: normYFromTop))
            }
        }

        return points
    }

    /// Fit linear perspective line x = slope * y + intercept using least-squares.
    /// Validate realistic perspective slope: left lane converges right (-1.8 <= m <= -0.15),
    /// right lane converges left (0.15 <= m <= 1.8). Requires >= 4 points.
    /// Also prevent left/right crossover: top X at roiTopY must stay on correct side of centerX.
    private func fitLinear(points: [CGPoint], imageSize: CGSize, isLeft: Bool) -> [CGPoint]? {
        guard points.count >= 4 else { return nil }

        var sumY = 0.0, sumY2 = 0.0
        var sumX = 0.0, sumXY = 0.0

        for point in points {
            let y = point.y
            let x = point.x
            sumY += y
            sumY2 += y * y
            sumX += x
            sumXY += x * y
        }

        let n = Double(points.count)
        let denom = n * sumY2 - sumY * sumY
        guard abs(denom) > 1e-10 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumX * sumY2 - sumY * sumXY) / denom

        // Validate perspective slope
        // Y decreases upward (0=top, 1=bottom), so:
        // Left lane: converges RIGHT toward horizon => x decreases as y decreases => negative slope
        // Right lane: converges LEFT toward horizon => x increases as y decreases => positive slope
        if isLeft {
            guard slope >= -1.8 && slope <= -0.15 else { return nil }
        } else {
            guard slope >= 0.15 && slope <= 1.8 else { return nil }
        }

        var fittedPoints: [CGPoint] = []
        let startY = roiBottomY
        let endY = roiTopY
        let steps = 20

        for i in 0..<steps {
            let y = startY - (startY - endY) * Double(i) / Double(steps - 1)
            let x = slope * y + intercept
            let clampedX = max(0.0, min(1.0, x))
            fittedPoints.append(CGPoint(x: clampedX, y: y))
        }

        // Read config under lock
        configLock.lock()
        let centerX = 0.5 + roiCenterOffsetX
        configLock.unlock()

        let avgX = fittedPoints.map { $0.x }.reduce(0, +) / Double(fittedPoints.count)

        if isLeft && avgX > centerX { return nil }
        if !isLeft && avgX < centerX { return nil }

        // Prevent crossover: verify top X (at roiTopY) stays on correct side with margin
        let topX = slope * roiTopY + intercept
        if isLeft {
            guard topX < centerX - 0.02 else { return nil }
        } else {
            guard topX > centerX + 0.02 else { return nil }
        }

        return fittedPoints
    }
    
    // MARK: - EMA with Grace Window
    private func applyEMAWithGrace(leftFit: [CGPoint]?, rightFit: [CGPoint]?) -> (left: [CGPoint], right: [CGPoint], leftConf: Float, rightConf: Float) {
        var leftConf: Float = 0
        var rightConf: Float = 0
        var smoothedLeft = emaLeftLane ?? []
        var smoothedRight = emaRightLane ?? []
        
        // LEFT lane
        if let leftFit {
            leftConf = 0.8
            framesSinceConfidentLeft = 0
            if emaLeftLane == nil {
                emaLeftLane = leftFit
                smoothedLeft = leftFit
            } else {
                let minCount = min(emaLeftLane!.count, leftFit.count)
                for i in 0..<minCount {
                    emaLeftLane![i].x = emaAlpha * leftFit[i].x + (1 - emaAlpha) * emaLeftLane![i].x
                    emaLeftLane![i].y = emaAlpha * leftFit[i].y + (1 - emaAlpha) * emaLeftLane![i].y
                }
                smoothedLeft = emaLeftLane!
            }
        } else {
            framesSinceConfidentLeft += 1
            if framesSinceConfidentLeft <= graceFrames {
                // Grace period: hold last EMA with decaying confidence
                leftConf = max(0.5 - Float(framesSinceConfidentLeft) * 0.5 / Float(graceFrames), 0.1)
                smoothedLeft = emaLeftLane ?? []
            } else {
                // Fade to static fallback
                leftConf = 0
                emaLeftLane = nil
                smoothedLeft = []
            }
        }
        
        // RIGHT lane
        if let rightFit {
            rightConf = 0.8
            framesSinceConfidentRight = 0
            if emaRightLane == nil {
                emaRightLane = rightFit
                smoothedRight = rightFit
            } else {
                let minCount = min(emaRightLane!.count, rightFit.count)
                for i in 0..<minCount {
                    emaRightLane![i].x = emaAlpha * rightFit[i].x + (1 - emaAlpha) * emaRightLane![i].x
                    emaRightLane![i].y = emaAlpha * rightFit[i].y + (1 - emaAlpha) * emaRightLane![i].y
                }
                smoothedRight = emaRightLane!
            }
        } else {
            framesSinceConfidentRight += 1
            if framesSinceConfidentRight <= graceFrames {
                rightConf = max(0.5 - Float(framesSinceConfidentRight) * 0.5 / Float(graceFrames), 0.1)
                smoothedRight = emaRightLane ?? []
            } else {
                rightConf = 0
                emaRightLane = nil
                smoothedRight = []
            }
        }
        
        return (smoothedLeft, smoothedRight, leftConf, rightConf)
    }
    
    // MARK: - Lane Departure Detection (Anti-False-Positive)
    private func checkLaneDeparture(speedKMPH: Double, vehicleCenterX: Double) {
        let now = CACurrentMediaTime()

        // Reset if LDWS disabled or speed gated
        configLock.lock()
        let ldwsEnabled = isLDWSEnabled
        let minSpeed = minSpeedForDepartureAlert
        configLock.unlock()

        if !ldwsEnabled || speedKMPH < minSpeed {
            leftDepartureStartTime = nil
            rightDepartureStartTime = nil
            departureState = .none
            departureAlertActive = false
            lastDepartureAlertActive = false
            return
        }

        // Require both lanes with good confidence
        guard leftLaneConfidence > 0.5, rightLaneConfidence > 0.5,
              !leftLanePoints.isEmpty, !rightLanePoints.isEmpty else {
            leftDepartureStartTime = nil
            rightDepartureStartTime = nil
            departureState = .none
            return
        }

        // Get lane edges at bottom of ROI (normalized coordinates)
        let bottomLeftX = leftLanePoints.last?.x ?? 0
        let bottomRightX = rightLanePoints.last?.x ?? 1.0
        let laneWidth = bottomRightX - bottomLeftX
        let thresholdRatio = departureThresholdRatio  // 8% of lane width

        // LEFT departure: vehicle within 8% of left edge OR crossing it
        let leftDistance = vehicleCenterX - bottomLeftX
        let isNearLeftEdge = leftDistance < thresholdRatio && leftDistance >= 0
        let hasCrossedLeft = leftDistance < 0

        if hasCrossedLeft || isNearLeftEdge {
            if leftDepartureStartTime == nil { leftDepartureStartTime = now }
            let duration = now - leftDepartureStartTime!

            if hasCrossedLeft {
                departureState = .driftingLeft
            } else if duration >= departurePersistenceThreshold {
                departureState = .driftingLeft
            }

            // Trigger alert only on actual crossing with persistence + cooldown
            if hasCrossedLeft && duration >= departurePersistenceThreshold && now - lastDepartureAlertTime >= departureCooldown {
                departureAlertActive = true
                lastDepartureAlertTime = now
            }
        } else {
            leftDepartureStartTime = nil
            if departureState == .driftingLeft { departureState = .none }
        }

        // RIGHT departure: vehicle within 8% of right edge OR crossing it
        let rightDistance = bottomRightX - vehicleCenterX
        let isNearRightEdge = rightDistance < thresholdRatio && rightDistance >= 0
        let hasCrossedRight = rightDistance < 0

        if hasCrossedRight || isNearRightEdge {
            if rightDepartureStartTime == nil { rightDepartureStartTime = now }
            let duration = now - rightDepartureStartTime!

            if hasCrossedRight {
                departureState = .driftingRight
            } else if duration >= departurePersistenceThreshold {
                departureState = .driftingRight
            }

            if hasCrossedRight && duration >= departurePersistenceThreshold && now - lastDepartureAlertTime >= departureCooldown {
                departureAlertActive = true
                lastDepartureAlertTime = now
            }
        } else {
            rightDepartureStartTime = nil
            if departureState == .driftingRight { departureState = .none }
        }

        // Clear alert after cooldown
        if departureAlertActive && now - lastDepartureAlertTime >= departureCooldown {
            departureAlertActive = false
        }

        // Log departure alert on rising edge
        if departureAlertActive && !lastDepartureAlertActive {
            diagnostics?.record(type: "ldws_departure_alert",
                details: "departureState=\(String(describing: departureState)), speedKMPH=\(String(format: "%.1f", speedKMPH)), leftConf=\(String(format: "%.2f", leftLaneConfidence)), rightConf=\(String(format: "%.2f", rightLaneConfidence))")
        }
        lastDepartureAlertActive = departureAlertActive
    }
    
    /// Get dynamic ROI polygon that snaps to detected lanes (for vehicle filtering)
    func getDynamicROIPolygon(imageSize: CGSize) -> [CGPoint]? {
        guard leftLaneConfidence > 0.5, rightLaneConfidence > 0.5,
              !leftLanePoints.isEmpty, !rightLanePoints.isEmpty else {
            return nil
        }
        
        let topLeft = leftLanePoints.first ?? CGPoint(x: 0.39, y: roiTopY)
        let topRight = rightLanePoints.first ?? CGPoint(x: 0.61, y: roiTopY)
        let bottomLeft = leftLanePoints.last ?? CGPoint(x: 0.26, y: roiBottomY)
        let bottomRight = rightLanePoints.last ?? CGPoint(x: 0.74, y: roiBottomY)
        
        return [topLeft, topRight, bottomRight, bottomLeft]
    }
    
    /// Get normalized lane edges at specific Y (for vehicle filter)
    func getLaneEdgesAtY(_ y: CGFloat, imageSize: CGSize) -> (left: CGFloat, right: CGFloat)? {
        guard leftLaneConfidence > 0.5, rightLaneConfidence > 0.5 else { return nil }
        
        let leftX = interpolateLaneAtY(leftLanePoints, targetY: y)
        let rightX = interpolateLaneAtY(rightLanePoints, targetY: y)
        
        guard let leftX, let rightX, leftX < rightX else { return nil }
        return (leftX, rightX)
    }
    
    private func interpolateLaneAtY(_ points: [CGPoint], targetY: CGFloat) -> CGFloat? {
        guard points.count >= 2 else { return nil }
        
        for i in 1..<points.count {
            let p1 = points[i-1]
            let p2 = points[i]
            
            if (p1.y <= targetY && p2.y >= targetY) || (p1.y >= targetY && p2.y <= targetY) {
                let t = (targetY - p1.y) / (p2.y - p1.y)
                return p1.x + (p2.x - p1.x) * t
            }
        }
        
        if targetY > points.last!.y {
            let p1 = points[points.count-2]
            let p2 = points.last!
            let t = (targetY - p1.y) / (p2.y - p1.y)
            return p1.x + (p2.x - p1.x) * t
        }
        
        return points.first?.x
    }
}

extension LaneDetector {
    func start() {
        isLaneDetectionActive = true
    }
    
    func stop() {
        isLaneDetectionActive = false
        leftLanePoints = []
        rightLanePoints = []
        leftLaneConfidence = 0
        rightLaneConfidence = 0
        emaLeftLane = nil
        emaRightLane = nil
        framesSinceConfidentLeft = 0
        framesSinceConfidentRight = 0
        departureState = .none
        departureAlertActive = false
        isSpeedGated = false
    }
}
