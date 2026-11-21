import AVFoundation
import CoreImage
import CoreML
import Foundation
import SwiftUI
import Vision

/// Vietnam traffic sign recognition using custom CoreML model (vn_signs_ios16.mlpackage).
/// Runs VNCoreMLRequest at 2 Hz on Neural Engine, maps class indices to Vietnamese sign labels.
final class TrafficSignDetector: ObservableObject {
    // MARK: - Published
    @Published private(set) var detectedSpeedLimit: Int?
    @Published private(set) var isProcessing = false
    @Published private(set) var didClearSpeedLimitEvent: Date?
    @Published private(set) var detectedEndOfAllRestrictions: Bool = false
    @Published private(set) var activeAdvisorySignText: String?  // e.g., "Cấm vượt", "Cấm ô tô", "Khu dân cư"

    // MARK: - Configuration
    private let processInterval: TimeInterval = 0.5  // 2 Hz
    private let requiredConsecutiveMatches = 2
    private let confidenceThreshold: Float = 0.48
    private let minBoxWidth: CGFloat = 0.018

    // MARK: - Class index to label mapping (from classid.csv Count strings)
    // Speed limits: 57/"124"->10, 61/"114"->20, 62->30, 2/"360"->40, 39/"402"->50,
    // 12/"750"->60, 40/"105"->70, 41/"441"->80, 63/"102"->90, 58/"103"->100, 59/"101"->110, 60->120
    // Advisory: 79/"164"->50 Residential Area; 48/"190", 78/"141", 80/"117"->Clear Limit
    // Prohibitory: 0/"572"->No Entry, 6/"279"->No Cars, 45/"123"->No Overtaking
    private let classIndexToSign: [Int: SignInfo] = [
        // Speed limits
        57: .speedLimit(10), 61: .speedLimit(20), 62: .speedLimit(30), 2: .speedLimit(40),
        39: .speedLimit(50), 12: .speedLimit(60), 40: .speedLimit(70), 41: .speedLimit(80),
        63: .speedLimit(90), 58: .speedLimit(100), 59: .speedLimit(110), 60: .speedLimit(120),
        // Advisory / informational
        79: .advisory("Khu dân cư"),        // 50 Residential Area
        48: .clearLimit, 78: .clearLimit, 80: .clearLimit,  // End of restriction
        // Prohibitory
        0: .advisory("Cấm ngược chiều"),    // No Entry
        6: .advisory("Cấm ô tô"),           // No Cars
        45: .advisory("Cấm vượt"),          // No Overtaking
    ]

    private enum SignInfo: Equatable {
        case speedLimit(Int)
        case clearLimit
        case advisory(String)

        var isSpeedLimit: Bool { if case .speedLimit = self { return true } else { return false } }
        var isClearLimit: Bool { if case .clearLimit = self { return true } else { return false } }
        var isAdvisory: Bool { if case .advisory = self { return true } else { return false } }
        var speedValue: Int? { if case .speedLimit(let v) = self { return v } else { return nil } }
        var advisoryText: String? { if case .advisory(let t) = self { return t } else { return nil } }
    }

    // MARK: - State
    private var lastProcessTime: TimeInterval = 0
    private var consecutiveMatchCount = 0
    private var lastMatchedLimit: Int?
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
                let modelURL = Bundle.main.url(forResource: "vn_signs_ios16", withExtension: "mlpackage")
                guard let modelURL else {
                    print("TrafficSignDetector: vn_signs_ios16.mlpackage not found in bundle")
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
                    print("TrafficSignDetector: CoreML model loaded successfully")
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

        // Filter detections
        var speedLimitDetections: [(Int, Float, CGRect)] = []  // (speedValue, confidence, bbox)
        var clearLimitDetections: [(Float, CGRect)] = []        // (confidence, bbox)
        var advisoryDetections: [(String, Float, CGRect)] = []  // (text, confidence, bbox)

        for obs in results {
            guard obs.confidence >= confidenceThreshold else { continue }
            guard obs.boundingBox.width >= minBoxWidth else { continue }

            // Get the top label
            guard let topLabel = obs.labels.first else { continue }
            let classIndex = topLabel.identifier
            guard let classIdx = Int(classIndex) else { continue }
            guard let signInfo = classIndexToSign[classIdx] else { continue }

            let bbox = obs.boundingBox  // normalized, bottom-left origin

            if signInfo.isSpeedLimit, let speed = signInfo.speedValue {
                speedLimitDetections.append((speed, obs.confidence, bbox))
            } else if signInfo.isClearLimit {
                clearLimitDetections.append((obs.confidence, bbox))
            } else if signInfo.isAdvisory, let text = signInfo.advisoryText {
                advisoryDetections.append((text, obs.confidence, bbox))
            }
        }

        // Diagnostic logging: every 1.0s
        let now = CACurrentMediaTime()
        if now - lastTSRLogTime >= 1.0 {
            lastTSRLogTime = now
            let details = "speedDetections=\(speedLimitDetections.map { "(\($0.0),\(String(format: "%.2f", $0.1)),\(String(format: "%.3f", $0.2.minX)))\($0.2.width)" }.joined(separator: ";")) clearDetections=\(clearLimitDetections.count) advisoryDetections=\(advisoryDetections.map { "(\($0.0),\(String(format: "%.2f", $0.1)))" }.joined(separator: ";"))"
            diagnostics?.record(type: "tsr_yolo_detect", details: details)
        }

        // Handle speed limit detection
        if let bestSpeed = speedLimitDetections.max(by: { $0.1 < $1.1 }) {
            let speedValue = bestSpeed.0
            endSignConsecutiveCount = 0
            lastEndSignType = nil

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
                }
                diagnostics?.record(type: "tsr_state", details: "action=P127_confirmed limit=\(speedValue) consecutive=\(consecutiveMatchCount)")
            }
        } else {
            consecutiveMatchCount = 0
            lastMatchedLimit = nil
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
            let advisoryText = bestAdvisory.0
            if advisoryText == lastAdvisoryText {
                advisoryConsecutiveCount += 1
            } else {
                advisoryConsecutiveCount = 1
                lastAdvisoryText = advisoryText
            }

            if advisoryConsecutiveCount >= requiredConsecutiveMatches {
                DispatchQueue.main.async { [weak self] in
                    self?.activeAdvisorySignText = advisoryText
                    // Auto-clear after 3.5s
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                        if self?.activeAdvisorySignText == advisoryText {
                            self?.activeAdvisorySignText = nil
                        }
                    }
                }
                diagnostics?.record(type: "tsr_state", details: "action=advisory_confirmed text=\(advisoryText)")
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