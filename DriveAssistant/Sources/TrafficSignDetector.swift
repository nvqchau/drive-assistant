import AVFoundation
import CoreImage
import CoreML
import Foundation
import SwiftUI
import Vision

/// Vietnam traffic sign recognition using custom CoreML model (vn_signs_ios16.mlpackage compiled to .mlmodelc).
/// Runs VNCoreMLRequest at 2 Hz on Neural Engine, maps class labels (Count strings from data.yaml) to Vietnamese sign labels.
final class TrafficSignDetector: ObservableObject {
    // MARK: - Published
    @Published private(set) var detectedSpeedLimit: Int?
    @Published private(set) var isProcessing = false
    @Published private(set) var didClearSpeedLimitEvent: Date?
    @Published private(set) var detectedEndOfAllRestrictions: Bool = false
    @Published private(set) var activeAdvisorySignText: String?  // e.g., "No Overtaking", "No Cars", "Residential Area"

    // MARK: - Configuration
    private let processInterval: TimeInterval = 0.5  // 2 Hz
    private let requiredConsecutiveMatches = 2
    private let confidenceThreshold: Float = 0.35
    private let minBoxWidth: CGFloat = 0.018
    // For diagnostic logging: include raw labels at lower confidence to see what model emits
    private let diagnosticConfidenceThreshold: Float = 0.25
    // Tolerate 1 transient missed frame during consecutive confirmation
    private let maxMissedMatchFrames = 1

    // MARK: - Label to Sign mapping (ONLY true Count strings from vn_signs_ios16.mlpackage data.yaml)
    // Speed limits: "124"=ID57->10, "360"=ID2->40, "402"=ID39->50, "750"=ID12->60,
    // "105"=ID40->70, "441"=ID41->80, "101"=ID59->110
    // Residential area (sets 50 km/h + advisory): "164"=ID79
    // Clear speed limit (DP.134/DP.135): "190"=ID48, "141"=ID78, "117"=ID80
    // Prohibitory advisory: "572"=ID0->no_entry, "279"=ID6->no_cars, "123"=ID45->no_overtaking
    private let labelToSign: [String: SignInfo] = [
        // Speed limits (Count string -> speed value)
        "124": .speedLimit(10),   // ID 57: Speed limit 10km/h
        "360": .speedLimit(40),   // ID 2: Speed limit 40km/h
        "402": .speedLimit(50),   // ID 39: Speed limit 50km/h
        "750": .speedLimit(60),   // ID 12: Speed limit 60km/h
        "105": .speedLimit(70),   // ID 40: Speed limit 70km/h
        "441": .speedLimit(80),   // ID 41: Speed limit 80km/h
        "101": .speedLimit(110),  // ID 59: Speed limit 110km/h
        // Residential area (sets 50 km/h speed limit + advisory key)
        "164": .residential50,    // ID 79: Residential area (50 km/h)
        // Clear speed limit (DP.134 / DP.135)
        "190": .clearLimit,       // ID 48: End of all prohibition
        "141": .clearLimit,       // ID 78: End of 50km/h speed limit
        "117": .clearLimit,       // ID 80: Sparsely populated area
        // Prohibitory advisory (canonical keys for localization)
        "572": .advisory("no_entry"),      // ID 0: No Entry
        "279": .advisory("no_cars"),       // ID 6: No Cars
        "123": .advisory("no_overtaking"), // ID 45: No Overtaking
    ]

    private enum SignInfo: Equatable {
        case speedLimit(Int)
        case residential50  // sets detectedSpeedLimit = 50 AND activeAdvisorySignText = "residential_area"
        case clearLimit
        case advisory(String)  // canonical key: "no_entry", "no_cars", "no_overtaking"

        var isSpeedLimit: Bool { if case .speedLimit = self { return true } else { return false } }
        var isResidential50: Bool { if case .residential50 = self { return true } else { return false } }
        var isClearLimit: Bool { if case .clearLimit = self { return true } else { return false } }
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
    private var coreMLModel: VNCoreMLModel?
    private var modelLoaded = false
    private var loadTask: Task<Void, Never>?

    // Confirmation state
    private var endSignConsecutiveCount = 0
    private var lastEndSignType: EndSignType?
    private var advisoryConsecutiveCount = 0
    private var lastAdvisoryText: String?

    private enum EndSignType { case dp134, dp135 }

    // Diagnostics
    private weak var diagnostics: DiagnosticsLogStore?
    private var lastTSRLogTime: TimeInterval = 0

    init() {
        loadCoreMLModelAsync()
    }

    deinit {
        loadTask?.cancel()
    }

    private func loadCoreMLModelAsync() {
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Xcode compiles .mlpackage resources to .mlmodelc in the app bundle
                let modelURL = Bundle.main.url(forResource: "vn_signs_ios16", withExtension: "mlmodelc")
                guard let modelURL else {
                    print("TrafficSignDetector: vn_signs_ios16.mlmodelc not found in bundle")
                    return
                }
                let mlModel = try MLModel(contentsOf: modelURL, configuration: {
                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine
                    return config
                }())
                let vnModel = try VNCoreMLModel(for: mlModel)
                await MainActor.run {
                    self.coreMLModel = vnModel
                    self.modelLoaded = true
                    print("TrafficSignDetector: CoreML model loaded successfully from \(modelURL.lastPathComponent)")
                }
            } catch {
                print("TrafficSignDetector: Failed to load CoreML model: \(error)")
            }
        }
    }

    /// Attach diagnostics store for TSR event logging
    func attachDiagnostics(_ diagnostics: DiagnosticsLogStore) {
        self.diagnostics = diagnostics
    }

    /// Set vision orientation (matches CameraManager's visionOrientation)
    func setVisionOrientation(_ orientation: CGImagePropertyOrientation) {
        visionOrientation = orientation
    }

    /// Call from CameraManager.captureOutput for each frame.
    func processFrameIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard !isProcessing else { return }
        let now = CACurrentMediaTime()
        guard now - lastProcessTime >= processInterval else { return }
        guard thermalState != .critical else { return }
        guard modelLoaded, coreMLModel != nil else { return }

        lastProcessTime = now
        isProcessing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processFrame(pixelBuffer)
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        defer { isProcessing = false }

        guard let request = makeCoreMLRequest() else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: visionOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("TrafficSignDetector: VNCoreMLRequest error: \(error)")
            return
        }

        guard let results = request.results as? [VNRecognizedObjectObservation] else { return }

        // Filter detections at normal threshold for state updates
        var speedLimitDetections: [(Int, Float, CGRect)] = []  // (speedValue, confidence, bbox)
        var clearLimitDetections: [(Float, CGRect)] = []        // (confidence, bbox)
        var advisoryDetections: [(String, Float, CGRect)] = []  // (key, confidence, bbox)
        var residential50Detected = false

        // For diagnostic logging: collect ALL raw labels at lower threshold
        var allRawDetections: [(String, Float, CGRect)] = []    // (rawLabel, confidence, bbox)

        for obs in results {
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
                speedLimitDetections.append((speed, obs.confidence, bbox))
            } else if signInfo.isResidential50 {
                residential50Detected = true
                speedLimitDetections.append((50, obs.confidence, bbox))
            } else if signInfo.isClearLimit {
                clearLimitDetections.append((obs.confidence, bbox))
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
            let details = "raw=\(rawDetails.isEmpty ? "none" : rawDetails); speedDetections=\(speedLimitDetections.map { "(\($0.0),\(String(format: "%.2f", $0.1)),\(String(format: "%.3f", $0.2.minX)))\($0.2.width)" }.joined(separator: ";")) clearDetections=\(clearLimitDetections.count) advisoryDetections=\(advisoryDetections.map { "(\($0.0),\(String(format: "%.2f", $0.1)))" }.joined(separator: ";")) residential50=\(residential50Detected)"
            diagnostics?.record(type: "tsr_yolo_detect", details: details)
        }

        // Handle speed limit detection (including residential50 which sets 50 km/h)
        if let bestSpeed = speedLimitDetections.max(by: { $0.1 < $1.1 }) {
            let speedValue = bestSpeed.0
            endSignConsecutiveCount = 0
            lastEndSignType = nil
            missedMatchFrames = 0  // reset miss tolerance on detection

            if speedValue == lastMatchedLimit {
                consecutiveMatchCount += 1
            } else {
                consecutiveMatchCount = 1
                lastMatchedLimit = speedValue
            }

            if consecutiveMatchCount >= requiredConsecutiveMatches {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedSpeedLimit = speedValue
                    self?.detectedEndOfAllRestrictions = false
                    // If residential50 was detected, also set advisory
                    if residential50Detected {
                        self?.activeAdvisorySignText = "residential_area"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                            if self?.activeAdvisorySignText == "residential_area" {
                                self?.activeAdvisorySignText = nil
                            }
                        }
                    }
                }
                diagnostics?.record(type: "tsr_state", details: "action=P127_confirmed limit=\(speedValue) consecutive=\(consecutiveMatchCount) residential50=\(residential50Detected)")
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
            if advisoryKey == lastAdvisoryText {
                advisoryConsecutiveCount += 1
            } else {
                advisoryConsecutiveCount = 1
                lastAdvisoryText = advisoryKey
            }

            if advisoryConsecutiveCount >= requiredConsecutiveMatches {
                DispatchQueue.main.async { [weak self] in
                    self?.activeAdvisorySignText = advisoryKey
                    // Auto-clear after 3.5s
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                        if self?.activeAdvisorySignText == advisoryKey {
                            self?.activeAdvisorySignText = nil
                        }
                    }
                }
                diagnostics?.record(type: "tsr_state", details: "action=advisory_confirmed key=\(advisoryKey)")
            }
        } else {
            advisoryConsecutiveCount = 0
            lastAdvisoryText = nil
        }
    }

    private func makeCoreMLRequest() -> VNCoreMLRequest? {
        guard let model = coreMLModel else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        return request
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
    }
}