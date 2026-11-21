import AVFoundation
import CoreImage
import CoreML
import Foundation
import SwiftUI
import Vision

/// Vietnam traffic sign recognition using shared observations from unified CoreML model (vn_adas_unified_ios16.mlpackage).
/// Consumes VNRecognizedObjectObservation from CameraManager's single-pass inference, runs hybrid cropped Vision OCR for speed limit number verification.
final class TrafficSignDetector: ObservableObject {
    // MARK: - Published
    @Published private(set) var detectedSpeedLimit: Int?
    @Published private(set) var isProcessing = false
    @Published private(set) var didClearSpeedLimitEvent: Date?
    @Published private(set) var detectedEndOfAllRestrictions: Bool = false
    @Published private(set) var activeAdvisorySignText: String?  // e.g., "No Overtaking", "No Cars", "Residential Area"
    @Published private(set) var isInResidentialArea: Bool? = nil  // true = R.420 seen, false = R.421/DP.135 seen
    @Published private(set) var isDividedRoadFromSign: Bool = false  // set when class "142" (dual carriageway) detected

    // MARK: - Configuration
    private var processInterval: TimeInterval = 0.25  // 4 Hz (adjusted by thermal state)
    private let baseProcessInterval: TimeInterval = 0.25
    private let thermalProcessInterval: TimeInterval = 0.5  // fallback when thermal >= .fair
    private let requiredConsecutiveMatches = 2
    private let confidenceThreshold: Float = 0.28
    private let minBoxWidth: CGFloat = 0.018
    // For diagnostic logging: include raw labels at lower confidence to see what model emits
    private let diagnosticConfidenceThreshold: Float = 0.20
    // Tolerate 1 transient missed frame during consecutive confirmation
    private let maxMissedMatchFrames = 3

    // OCR configuration for speed limit number verification
    private let ocrExpansionFactor: CGFloat = 1.15  // expand YOLO bbox by 15% for OCR crop
    private let validSpeedTokens: Set<Int> = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]
    private let speedLimitLabels: Set<String> = ["124", "114", "360", "402", "750", "105", "441", "102", "103", "101"]
    private var textRecognitionRequest: VNRecognizeTextRequest?

    // MARK: - Label to Sign mapping (ONLY true Count strings from vn_signs_ios16.mlpackage data.yaml)
    // Speed limits: "124"=ID57->10, "114"=ID61->20, "360"=ID2->40, "402"=ID39->50,
    // "750"=ID12->60, "105"=ID40->70, "441"=ID41->80, "102"=ID63->90, "103"=ID58->100, "101"=ID59->110
    // Residential area (sets 50 km/h + advisory): "164"=ID79 (R.420)
    // End residential area: "117"=ID80 (R.421), "190"=ID48 (DP.135 end all prohibition)
    // Clear speed limit (DP.134): "141"=ID78 (End of 50km/h speed limit)
    // Dual carriageway (sets divided road): "142"=ID73
    // Prohibitory advisory: "572"=ID0->no_entry, "279"=ID6->no_cars, "123"=ID45->no_overtaking
    private let labelToSign: [String: SignInfo] = [
        // Speed limits (Count string -> speed value)
        "124": .speedLimit(10),   // ID 57: Speed limit 10km/h
        "114": .speedLimit(20),   // ID 61: Speed limit 20km/h
        "360": .speedLimit(40),   // ID 2: Speed limit 40km/h
        "402": .speedLimit(50),   // ID 39: Speed limit 50km/h
        "750": .speedLimit(60),   // ID 12: Speed limit 60km/h
        "105": .speedLimit(70),   // ID 40: Speed limit 70km/h
        "441": .speedLimit(80),   // ID 41: Speed limit 80km/h
        "102": .speedLimit(90),   // ID 63: Speed limit 90km/h
        "103": .speedLimit(100),  // ID 58: Speed limit 100km/h
        "101": .speedLimit(110),  // ID 59: Speed limit 110km/h
        // Residential area (sets 50 km/h speed limit + advisory key)
        "164": .residential50,    // ID 79: Residential area (R.420) - ENTER
        // End residential area / end restrictions
        "117": .endResidentialArea,    // ID 80: Sparsely populated area (R.421) - EXIT
        "190": .endResidentialArea,    // ID 48: End of all prohibition (DP.135) - EXIT
        // Clear speed limit (DP.134)
        "141": .clearLimit,       // ID 78: End of 50km/h speed limit
        // Dual carriageway (sets divided road flag)
        "142": .dualCarriageway,  // ID 73: Dual carriageway
        // Prohibitory advisory (canonical keys for localization)
        "572": .advisory("no_entry"),      // ID 0: No Entry
        "279": .advisory("no_cars"),       // ID 6: No Cars
        "123": .advisory("no_overtaking"), // ID 45: No Overtaking
    ]

    private enum SignInfo: Equatable {
        case speedLimit(Int)
        case residential50  // sets detectedSpeedLimit = 50 AND activeAdvisorySignText = "residential_area"
        case endResidentialArea  // R.421 "117" or DP.135 "190" - exit residential area
        case clearLimit
        case dualCarriageway  // "142" - dual carriageway sign
        case advisory(String)  // canonical key: "no_entry", "no_cars", "no_overtaking"

        var isSpeedLimit: Bool { if case .speedLimit = self { return true } else { return false } }
        var isResidential50: Bool { if case .residential50 = self { return true } else { return false } }
        var isEndResidentialArea: Bool { if case .endResidentialArea = self { return true } else { return false } }
        var isClearLimit: Bool { if case .clearLimit = self { return true } else { return false } }
        var isDualCarriageway: Bool { if case .dualCarriageway = self { return true } else { return false } }
        var isAdvisory: Bool { if case .advisory = self { return true } else { return false } }
        var speedValue: Int? { if case .speedLimit(let v) = self { return v } else { return nil } }
        var advisoryKey: String? { if case .advisory(let k) = self { return k } else { return nil } }
    }

    // MARK: - State
    private var lastProcessTime: TimeInterval = 0
    private var consecutiveMatchCount = 0
    private var lastMatchedLimit: Int?
    private var missedMatchFrames = 0  // tolerance for transient missed frame
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private var visionOrientation: CGImagePropertyOrientation = .up

    // Confirmation state
    private var endSignConsecutiveCount = 0
    private var lastEndSignType: EndSignType?
    private var advisoryConsecutiveCount = 0
    private var lastAdvisoryText: String?
    private var endResidentialConsecutiveCount = 0  // for R.421/DP.135 exit confirmation
    private var lastEndResidentialTriggerTime: TimeInterval = 0  // 6s cooldown for DP.134/135/R.421

    private enum EndSignType { case dp134, dp135 }

    // Diagnostics
    private weak var diagnostics: DiagnosticsLogStore?
    private var lastTSRLogTime: TimeInterval = 0

    init() {
        setupOCRRequest()
    }

    private func setupOCRRequest() {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["vi-VN", "en-US"]
        request.minimumTextHeight = 0.02
        self.textRecognitionRequest = request
    }

    /// Attach diagnostics store for TSR event logging
    func attachDiagnostics(_ diagnostics: DiagnosticsLogStore) {
        self.diagnostics = diagnostics
    }

    /// Set vision orientation (matches CameraManager's visionOrientation)
    func setVisionOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation = orientation
    }

    /// Called from CameraManager with shared unified model observations.
    /// Runs on background queue, throttled by thermal state (4 Hz nominal, 2 Hz on .fair/.serious).
    func processObservations(_ observations: [VNRecognizedObjectObservation], pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard !isProcessing else { return }
        let now = CACurrentMediaTime()
        guard now - lastProcessTime >= processInterval else { return }
        guard thermalState != .critical else { return }

        lastProcessTime = now
        isProcessing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processFrame(observations, pixelBuffer: pixelBuffer, orientation: orientation)
        }
    }

    private func processFrame(_ observations: [VNRecognizedObjectObservation], pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        defer { isProcessing = false }

        // Filter detections at normal threshold for state updates
        var speedLimitDetections: [(Int, Float, CGRect, String)] = []  // (speedValue, confidence, bbox, label)
        var clearLimitDetections: [(Float, CGRect)] = []        // (confidence, bbox)
        var advisoryDetections: [(String, Float, CGRect)] = []  // (key, confidence, bbox)
        var residential50Detected = false
        var endResidentialAreaDetected = false
        var dualCarriagewayDetected = false

        // For diagnostic logging: collect ALL raw labels at lower threshold
        var allRawDetections: [(String, Float, CGRect)] = []    // (rawLabel, confidence, bbox)

        for obs in observations {
            guard obs.confidence >= diagnosticConfidenceThreshold else { continue }
            guard obs.boundingBox.width >= minBoxWidth else { continue }

            // Get the top label - identifier is the class label string (Count from data.yaml)
            guard let topLabel = obs.labels.first else { continue }
            let label = topLabel.identifier
            let bbox = obs.boundingBox  // normalized, bottom-left origin

            // Record ALL raw labels for verification
            allRawDetections.append((label, obs.confidence, bbox))

            // Only process for state updates if above normal confidence threshold
            guard obs.confidence >= confidenceThreshold else { continue }
            guard let signInfo = labelToSign[label] else { continue }

            if signInfo.isSpeedLimit, let speed = signInfo.speedValue {
                speedLimitDetections.append((speed, obs.confidence, bbox, label))
            } else if signInfo.isResidential50 {
                residential50Detected = true
                speedLimitDetections.append((50, obs.confidence, bbox, label))
            } else if signInfo.isEndResidentialArea {
                endResidentialAreaDetected = true
            } else if signInfo.isClearLimit {
                clearLimitDetections.append((obs.confidence, bbox))
            } else if signInfo.isDualCarriageway {
                dualCarriagewayDetected = true
            } else if signInfo.isAdvisory, let key = signInfo.advisoryKey {
                advisoryDetections.append((key, obs.confidence, bbox))
            }
        }

        // Diagnostic logging: every 1.0s - include ALL raw labels
        let now = CACurrentMediaTime()
        if now - lastTSRLogTime >= 1.0 {
            lastTSRLogTime = now
            let rawDetails = allRawDetections.map {
                "(rawLabel=\($0.0), conf=\(String(format: "%.2f", $0.1)), x=\(String(format: "%.2f", $0.2.minX)), w=\(String(format: "%.3f", $0.2.width)))"
            }.joined(separator: ";")
            let details = "raw=\(rawDetails.isEmpty ? "none" : rawDetails); speedDetections=\(speedLimitDetections.map { "(\($0.0),\(String(format: "%.2f", $0.1)),\(String(format: "%.3f", $0.2.minX)))\($0.2.width),\($0.3)" }.joined(separator: ";")) clearDetections=\(clearLimitDetections.count) advisoryDetections=\(advisoryDetections.map { "(\($0.0),\(String(format: "%.2f", $0.1)))" }.joined(separator: ";")) residential50=\(residential50Detected) endResidential=\(endResidentialAreaDetected) dualCarriageway=\(dualCarriagewayDetected)"
            diagnostics?.record(type: "tsr_yolo_detect", details: details)
        }

        // Handle speed limit detection (including residential50 which sets 50 km/h)
        if let bestSpeed = speedLimitDetections.max(by: { $0.1 < $1.1 }) {
            let yoloSpeedValue = bestSpeed.0
            let bestConfidence = bestSpeed.1
            let bestBBox = bestSpeed.2
            let bestLabel = bestSpeed.3
            endSignConsecutiveCount = 0
            lastEndSignType = nil
            missedMatchFrames = 0  // reset miss tolerance on detection

            // Run OCR on the best speed sign detection for number verification
            var finalSpeedValue = yoloSpeedValue
            var ocrVerified = false
            if speedLimitLabels.contains(bestLabel) {
                if let ocrSpeed = runOCROnSpeedSign(pixelBuffer: pixelBuffer, bbox: bestBBox, orientation: orientation) {
                    finalSpeedValue = ocrSpeed
                    ocrVerified = true
                }
            }

            // High-confidence immediate confirmation (>= 0.45) OR OCR verified bypasses 2-frame requirement
            let shouldConfirmImmediately = bestConfidence >= 0.45 || ocrVerified

            if finalSpeedValue == lastMatchedLimit {
                consecutiveMatchCount += 1
            } else {
                consecutiveMatchCount = 1
                lastMatchedLimit = finalSpeedValue
            }

            if shouldConfirmImmediately || consecutiveMatchCount >= requiredConsecutiveMatches {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedSpeedLimit = finalSpeedValue
                    self?.detectedEndOfAllRestrictions = false
                    // If residential50 was detected, also set advisory and residential area flag
                    if residential50Detected {
                        self?.activeAdvisorySignText = "residential_area"
                        self?.isInResidentialArea = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                            if self?.activeAdvisorySignText == "residential_area" {
                                self?.activeAdvisorySignText = nil
                            }
                        }
                    }
                }
                diagnostics?.record(type: "tsr_state", details: "action=P127_confirmed limit=\(finalSpeedValue) yoloLimit=\(yoloSpeedValue) ocrVerified=\(ocrVerified) conf=\(String(format: "%.2f", bestConfidence)) immediate=\(shouldConfirmImmediately) consecutive=\(consecutiveMatchCount) residential50=\(residential50Detected)")
            }
        } else {
            // Tolerate transient missed frames before resetting confirmation
            if lastMatchedLimit != nil {
                missedMatchFrames += 1
                if missedMatchFrames > maxMissedMatchFrames {
                    consecutiveMatchCount = 0
                    lastMatchedLimit = nil
                    missedMatchFrames = 0
                }
            }
        }

        // Handle clear limit detection (DP.134 / DP.135)
        if !clearLimitDetections.isEmpty && detectedSpeedLimit != nil {
            handleEndSignDetection(.dp134)
        } else {
            endSignConsecutiveCount = 0
            lastEndSignType = nil
        }

        // Handle advisory sign detection
        if let bestAdvisory = advisoryDetections.max(by: { $0.1 < $1.1 }) {
            let advisoryKey = bestAdvisory.0
            let advisoryConfidence = bestAdvisory.1
            if advisoryKey == lastAdvisoryText {
                advisoryConsecutiveCount += 1
            } else {
                advisoryConsecutiveCount = 1
                lastAdvisoryText = advisoryKey
            }

            // High-confidence immediate confirmation (>= 0.45) bypasses 2-frame requirement
            let shouldConfirmImmediately = advisoryConfidence >= 0.45

            if shouldConfirmImmediately || advisoryConsecutiveCount >= requiredConsecutiveMatches {
                DispatchQueue.main.async { [weak self] in
                    self?.activeAdvisorySignText = advisoryKey
                    // Auto-clear after 5.0s for transient prohibitory signs
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        if self?.activeAdvisorySignText == advisoryKey {
                            self?.activeAdvisorySignText = nil
                        }
                    }
                }
                diagnostics?.record(type: "tsr_state", details: "action=advisory_confirmed key=\(advisoryKey) conf=\(String(format: "%.2f", advisoryConfidence)) immediate=\(shouldConfirmImmediately)")
            }
        } else {
            advisoryConsecutiveCount = 0
            lastAdvisoryText = nil
        }

        // Handle end of residential area detection (R.421 "117" or DP.135 "190") — require 2 consecutive matches
        if endResidentialAreaDetected {
            endResidentialConsecutiveCount += 1
            if endResidentialConsecutiveCount >= requiredConsecutiveMatches {
                let now = CACurrentMediaTime()
                if now - lastEndResidentialTriggerTime >= 6.0 {
                    lastEndResidentialTriggerTime = now
                    DispatchQueue.main.async { [weak self] in
                        self?.detectedSpeedLimit = nil
                        self?.didClearSpeedLimitEvent = Date()
                        self?.isInResidentialArea = false
                    }
                    diagnostics?.record(type: "tsr_state", details: "action=end_residential_area_confirmed cleared_limit")
                }
                endResidentialConsecutiveCount = 0
            }
        } else {
            endResidentialConsecutiveCount = 0
        }

        // Handle dual carriageway detection (class "142")
        if dualCarriagewayDetected {
            DispatchQueue.main.async { [weak self] in
                self?.isDividedRoadFromSign = true
            }
            diagnostics?.record(type: "tsr_state", details: "action=dual_carriageway confirmed")
        }
    }

    // MARK: - Hybrid YOLO Localization + Cropped Vision OCR for Speed Limits
    private func runOCROnSpeedSign(pixelBuffer: CVPixelBuffer, bbox: CGRect, orientation: CGImagePropertyOrientation) -> Int? {
        guard let ocrRequest = textRecognitionRequest else { return nil }

        // Expand bbox by 1.15x in normalized coordinates (bottom-left origin from YOLO)
        let expandedBBox = expandBoundingBox(bbox, factor: ocrExpansionFactor)

        // Convert normalized bbox (bottom-left origin) to CIImage crop rect (bottom-left origin)
        // CIImage.extent uses bottom-left origin, matching VNRecognizedObjectObservation.boundingBox
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageWidth = ciImage.extent.width
        let imageHeight = ciImage.extent.height

        // YOLO bbox: origin bottom-left, normalized
        // CIImage crop: origin bottom-left, pixel coordinates (same coordinate system)
        let cropX = expandedBBox.minX * imageWidth
        let cropY = expandedBBox.minY * imageHeight  // bottom-left origin, no Y flip needed
        let cropWidth = expandedBBox.width * imageWidth
        let cropHeight = expandedBBox.height * imageHeight

        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
            .intersection(ciImage.extent)

        guard cropRect.width > 10, cropRect.height > 10 else { return nil }

        let croppedImage = ciImage.cropped(to: cropRect)

        // Pass orientation directly to VNImageRequestHandler (not croppedImage.oriented)
        // so coordinates stay aligned for landscapeRight / down orientations
        var recognizedText: String?
        let handler = VNImageRequestHandler(ciImage: croppedImage, orientation: orientation, options: [:])
        do {
            try handler.perform([ocrRequest])
            recognizedText = ocrRequest.results?.first?.topCandidates(1).first?.string
        } catch {
            diagnostics?.record(type: "tsr_ocr_error", details: "error=\(error.localizedDescription)")
            return nil
        }

        guard let text = recognizedText else { return nil }

        // Parse text for speed number: split by non-digits, pick first token in validSpeedTokens
        // Handles "P.127 60" -> ["", "127", "", "60"] -> picks 60 (127 not in validSpeedTokens)
        let tokens = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
        for token in tokens {
            if let speed = Int(token), validSpeedTokens.contains(speed) {
                return speed
            }
        }
        diagnostics?.record(type: "tsr_ocr_invalid", details: "rawText=\(text), tokens=\(tokens)")
        return nil
    }

    private func expandBoundingBox(_ bbox: CGRect, factor: CGFloat) -> CGRect {
        let centerX = bbox.midX
        let centerY = bbox.midY
        let newWidth = min(bbox.width * factor, 1.0)
        let newHeight = min(bbox.height * factor, 1.0)
        let newMinX = max(0, centerX - newWidth / 2)
        let newMinY = max(0, centerY - newHeight / 2)
        let newMaxX = min(1, newMinX + newWidth)
        let newMaxY = min(1, newMinY + newHeight)
        return CGRect(x: newMinX, y: newMinY, width: newMaxX - newMinX, height: newMaxY - newMinY)
    }

    private func handleEndSignDetection(_ type: EndSignType) {
        if type == lastEndSignType {
            endSignConsecutiveCount += 1
        } else {
            endSignConsecutiveCount = 1
            lastEndSignType = type
        }

        if endSignConsecutiveCount >= requiredConsecutiveMatches {
            DispatchQueue.main.async { [weak self] in
                self?.detectedSpeedLimit = nil
                self?.didClearSpeedLimitEvent = Date()
                self?.detectedEndOfAllRestrictions = true
            }
            diagnostics?.record(type: "tsr_state", details: "action=\(type)_confirmed cleared_limit=\(lastMatchedLimit?.description ?? "nil")")
            endSignConsecutiveCount = 0
            lastEndSignType = nil
            lastMatchedLimit = nil
            consecutiveMatchCount = 0
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
        advisoryConsecutiveCount = 0
        lastAdvisoryText = nil
        didClearSpeedLimitEvent = nil
        detectedEndOfAllRestrictions = false
        activeAdvisorySignText = nil
        isInResidentialArea = nil
        isDividedRoadFromSign = false
        endResidentialConsecutiveCount = 0
    }
}