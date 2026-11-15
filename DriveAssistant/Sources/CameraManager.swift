import AVFoundation
import CoreML
import ImageIO
import os
import Vision
import UIKit

struct VehicleObservation: Identifiable {
    let id = UUID()
    let boundingBox: CGRect
    let distance: Double
}

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var leadVehicleDistance: Double?
    @Published private(set) var leadVehicleBox: CGRect?
    @Published private(set) var cameraFrameSize = CGSize(width: 1280, height: 720)
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published var cameraAuthorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published var isModelReady: Bool = false

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "drive-assistant.session", qos: .userInitiated)
    private let queue = DispatchQueue(label: "drive-assistant.camera", qos: .userInitiated)
    private var visionModel: VNCoreMLModel?
    private var isConfigured = false
    private var lastInference = CACurrentMediaTime()
    private let fairInferenceInterval = 1.0 / 6.0
    private let seriousInferenceInterval = 1.0 / 3.0
    private var baselineInferenceFPS = 10.0
    private var warmupFrameCount = 0
    private var warmupTotalDuration: TimeInterval = 0
    private var warmupComplete = false
    private let calibrationLock = NSLock()
    private var calibrationFactor: Double = 1.40
    private var orientationObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?
    private let orientationLock = NSLock()
    private var diagnostics: DiagnosticsLogStore?
    private var hasLoggedFrameFormat = false
    private var trackedBox: CGRect?
    private var trackedBoxTimestamp = CACurrentMediaTime()
    private var pendingBox: CGRect?
    private var pendingBoxFrames = 0
    private var lastDetectionLogTime = CACurrentMediaTime()
    private var frameCount = 0
    private var inferenceCount = 0
    private var performanceWindowStart = CACurrentMediaTime()
    private var thermalObserver: NSObjectProtocol?
    private let thermalLock = NSLock()
    private var currentThermalState = ProcessInfo.processInfo.thermalState
    private var cachedVideoOrientation: AVCaptureVideoOrientation = .landscapeRight
    private var cachedVisionOrientation: CGImagePropertyOrientation = .up
    private let logger = Logger(subsystem: "vn.ai.driveassistant", category: "Camera")

    override init() {
        super.init()
        updateCachedOrientation(for: UIDevice.current.orientation)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateVideoOrientation()
            }
        }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.logger.error("Capture session runtime error: domain=\(error?.domain ?? "unknown", privacy: .public) code=\(error?.code ?? -1, privacy: .public)")
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateThermalState()
        }
        updateThermalState()
        loadModelAsync()
    }

    private func loadModelAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = .cpuAndNeuralEngine
            if let modelURL = Bundle.main.url(forResource: "YOLOv3TinyInt8LUT", withExtension: "mlmodelc"),
               let model = try? MLModel(contentsOf: modelURL, configuration: modelConfiguration),
               let visionModel = try? VNCoreMLModel(for: model) {
                DispatchQueue.main.async {
                    self.visionModel = visionModel
                    self.isModelReady = true
                    self.logger.info("Vision model loaded and ready")
                }
            } else {
                DispatchQueue.main.async {
                    self.logger.error("Failed to load Vision model")
                }
            }
        }
    }

    func attachDiagnostics(_ diagnostics: DiagnosticsLogStore) {
        self.diagnostics = diagnostics
    }

    func setCalibrationFactor(_ factor: Double) {
        calibrationLock.lock()
        calibrationFactor = factor
        calibrationLock.unlock()
    }

    deinit {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func start() {
        logger.info("Camera start requested")
        guard isModelReady else {
            logger.warning("Camera start deferred: model not ready")
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            DispatchQueue.main.async {
                self.cameraAuthorizationStatus = status
            }
            self.logger.info("Camera permission result: \(granted ? "granted" : "denied", privacy: .public)")
            guard granted else { return }
            self.sessionQueue.async {
                self.logger.info("Configuring capture session")
                self.configureIfNeeded()
                self.logger.info("Starting capture session")
                self.session.startRunning()
                self.logger.info("Capture session running: \(self.session.isRunning, privacy: .public)")
                DispatchQueue.main.async {
                    self.updateVideoOrientation()
                }
            }
        }
    }

    func stop() {
        logger.info("Camera stop requested")
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.logger.info("Capture session stopped")
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        defer { session.commitConfiguration(); isConfigured = true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            logger.error("Unable to create or add the rear wide-angle camera input")
            return
        }
        session.addInput(input)
        configureFrameRate(for: device)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            logger.error("Unable to add video data output")
            return
        }
        session.addOutput(output)
        updateVideoOrientation()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        updateVideoOrientation(connection: connection)
        frameCount += 1
        recordPerformanceIfNeeded()
        let thermalState = thermalStateForInference()
        if thermalState == .critical {
            return
        }
        let now = CACurrentMediaTime()
        guard let interval = inferenceInterval(for: thermalState), now - lastInference >= interval, let visionModel else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.error("Capture frame has no pixel buffer")
            return
        }
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if cameraFrameSize != frameSize {
            DispatchQueue.main.async { [weak self] in
                self?.cameraFrameSize = frameSize
            }
        }
        if !hasLoggedFrameFormat {
            hasLoggedFrameFormat = true
            diagnostics?.record(type: "camera_frame_format", details: "width=\(CVPixelBufferGetWidth(pixelBuffer)), height=\(CVPixelBufferGetHeight(pixelBuffer)), videoOrientation=\(videoOrientation)")
        }
        lastInference = now
        inferenceCount += 1
        autoreleasepool {
            let inferenceStart = CACurrentMediaTime()
            let request = VNCoreMLRequest(model: visionModel) { [weak self] request, error in
                if let error {
                    self?.logger.error("Vision request failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                self?.recordInferenceDuration(CACurrentMediaTime() - inferenceStart)
                self?.handle(request: request, pixelBuffer: pixelBuffer)
            }
            request.imageCropAndScaleOption = .scaleFit
            let orientation = visionOrientation
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
            } catch {
                logger.error("Vision handler failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func recordInferenceDuration(_ duration: TimeInterval) {
        recordWarmupDuration(duration)
        guard duration >= 0.25 else { return }
        logger.warning("Slow Vision inference: \(duration, privacy: .public)s")
        diagnostics?.record(type: "slow_inference", details: "durationSeconds=\(duration), thermalState=\(String(describing: thermalStateForInference()))")
    }

    private func recordWarmupDuration(_ duration: TimeInterval) {
        guard !warmupComplete else { return }
        warmupFrameCount += 1
        warmupTotalDuration += duration
        guard warmupFrameCount >= 5 else { return }
        let averageMilliseconds = warmupTotalDuration / Double(warmupFrameCount) * 1000
        baselineInferenceFPS = averageMilliseconds < 40 ? 10 : 6
        warmupComplete = true
        diagnostics?.record(type: "vision_warmup_completed", details: "frames=5, averageLatencyMS=\(averageMilliseconds), baselineFPS=\(baselineInferenceFPS), computeUnits=cpuAndNeuralEngine")
        logger.info("Vision warm-up complete: average latency \(averageMilliseconds, privacy: .public) ms, baseline \(self.baselineInferenceFPS, privacy: .public) FPS")
    }

    private func inferenceInterval(for state: ProcessInfo.ThermalState) -> TimeInterval? {
        switch state {
        case .critical:
            return nil
        case .serious:
            return seriousInferenceInterval
        case .fair:
            return fairInferenceInterval
        case .nominal:
            return 1.0 / baselineInferenceFPS
        @unknown default:
            return 1.0 / baselineInferenceFPS
        }
    }

    private func recordPerformanceIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - performanceWindowStart
        guard elapsed >= 5 else { return }
        let captureFPS = Double(frameCount) / elapsed
        let inferenceFPS = Double(inferenceCount) / elapsed
        diagnostics?.record(type: "camera_performance", details: "captureFPS=\(captureFPS), inferenceFPS=\(inferenceFPS), thermalState=\(String(describing: thermalStateForInference()))")
        frameCount = 0
        inferenceCount = 0
        performanceWindowStart = now
    }

    private func configureFrameRate(for device: AVCaptureDevice) {
        let targetFrameDuration = CMTime(value: 1, timescale: 15)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 15 && $0.maxFrameRate >= 15
        }) else {
            logger.warning("15 FPS not supported by active camera format")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = targetFrameDuration
            device.activeVideoMaxFrameDuration = targetFrameDuration
            device.unlockForConfiguration()
            logger.info("Camera frame rate limited to 15 FPS")
        } catch {
            logger.error("Unable to configure camera frame rate: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        thermalLock.lock()
        let wasCritical = currentThermalState == .critical
        let changed = currentThermalState != state
        currentThermalState = state
        thermalLock.unlock()
        thermalState = state
        guard changed else { return }
        diagnostics?.record(type: "thermal_state_changed", details: "state=\(String(describing: state))")
        logger.warning("Thermal state changed: \(String(describing: state), privacy: .public)")
        if state == .critical {
            DispatchQueue.main.async { [weak self] in
                self?.leadVehicleDistance = nil
                self?.leadVehicleBox = nil
            }
        } else if wasCritical {
            trackedBox = nil
            trackedBoxTimestamp = CACurrentMediaTime()
            diagnostics?.record(type: "thermal_recovery_tracking_reset", details: "state=\(String(describing: state))")
        }
    }

    private func thermalStateForInference() -> ProcessInfo.ThermalState {
        thermalLock.lock()
        defer { thermalLock.unlock() }
        return currentThermalState
    }

    func updateVideoOrientation() {
        updateCachedOrientation(for: UIDevice.current.orientation)
        updateVideoOrientation(connection: output.connection(with: .video))
    }

    private func updateVideoOrientation(connection: AVCaptureConnection?) {
        guard let connection, connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = videoOrientation
    }

    private func updateCachedOrientation(for deviceOrientation: UIDeviceOrientation) {
        guard let videoOrientation = Self.videoOrientation(for: deviceOrientation),
              let visionOrientation = Self.visionOrientation(for: deviceOrientation) else {
            return
        }
        orientationLock.lock()
        let changed = cachedVideoOrientation != videoOrientation || cachedVisionOrientation != visionOrientation
        cachedVideoOrientation = videoOrientation
        cachedVisionOrientation = visionOrientation
        orientationLock.unlock()
        if changed {
            diagnostics?.record(type: "camera_orientation_changed", orientation: String(describing: deviceOrientation), details: "video=\(videoOrientation), vision=\(visionOrientation)")
        }
    }

    private static func videoOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .faceUp, .faceDown, .unknown, .portrait, .portraitUpsideDown:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation? {
        switch deviceOrientation {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .faceUp, .faceDown, .unknown, .portrait, .portraitUpsideDown:
            return nil
        @unknown default:
            return nil
        }
    }

    var videoOrientation: AVCaptureVideoOrientation {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return cachedVideoOrientation
    }

    private var visionOrientation: CGImagePropertyOrientation {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return cachedVisionOrientation
    }

    private func handle(request: VNRequest, pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        let candidates = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation -> (CGRect, Float, String)? in
            guard let label = observation.labels.first, label.confidence >= 0.5,
                  ["car", "truck", "bus", "motorbike"].contains(label.identifier) else { return nil }
            let box = observation.boundingBox
            guard box.width >= 0.06, box.height >= 0.06 else { return nil }
            return (box, label.confidence, label.identifier)
        }
        let observations = mergeOverlappingDetections(candidates).filter { observation in
            let box = observation.0
            return Self.isInsideForwardLaneROI(x: box.midX, yFromTop: 1 - box.minY)
        }
        let selected = selectLeadVehicle(from: observations)
        logDetectionFrame(observations, selected: selected)
        guard let selected else {
            if trackedBox != nil && now - trackedBoxTimestamp < 0.20 {
                return
            }
            self.trackedBox = nil
            DispatchQueue.main.async { self.leadVehicleDistance = nil; self.leadVehicleBox = nil }
            return
        }
        let smoothedBox = smoothTrackedBox(selected.0)
        let realWidth: Double
        switch selected.2 {
        case "car": realWidth = 1.8
        case "truck", "bus": realWidth = 2.5
        case "motorbike": realWidth = 0.75
        default: realWidth = 1.8
        }
        calibrationLock.lock()
        let factor = calibrationFactor
        calibrationLock.unlock()
        let normalizedBoxWidth = Double(smoothedBox.width)
        guard normalizedBoxWidth > 0 else { return }
        let distance = (realWidth * factor) / normalizedBoxWidth
        DispatchQueue.main.async { self.leadVehicleDistance = distance; self.leadVehicleBox = smoothedBox }
    }

    private func selectLeadVehicle(from observations: [(CGRect, Float, String)]) -> (CGRect, Float, String)? {
        guard !observations.isEmpty else {
            pendingBox = nil
            pendingBoxFrames = 0
            return nil
        }
        if let trackedBox {
            let matching = observations.filter { isPlausibleContinuation(from: trackedBox, to: $0.0) }
            if let closestMatch = closestVehicle(in: matching) {
                pendingBox = nil
                pendingBoxFrames = 0
                return closestMatch
            }

            guard let candidate = closestVehicle(in: observations) else { return nil }
            if let pendingBox, isPlausiblePendingMatch(from: pendingBox, to: candidate.0) {
                self.pendingBox = candidate.0
                pendingBoxFrames += 1
            } else {
                pendingBox = candidate.0
                pendingBoxFrames = 1
            }
            guard pendingBoxFrames >= 3 else { return nil }
            self.trackedBox = nil
            pendingBox = nil
            pendingBoxFrames = 0
            diagnostics?.record(type: "target_switched", details: "newBox=\(candidate.0.debugDescription), confidence=\(candidate.1), label=\(candidate.2)")
            return candidate
        }
        pendingBox = nil
        pendingBoxFrames = 0
        return closestVehicle(in: observations)
    }

    private func isPlausibleContinuation(from previous: CGRect, to candidate: CGRect) -> Bool {
        if intersectionOverUnion(previous, candidate) >= 0.10 {
            return true
        }
        let widthRatio = candidate.width / max(previous.width, 0.001)
        let heightRatio = candidate.height / max(previous.height, 0.001)
        return centerDistance(previous, candidate) <= 0.10 &&
            abs(previous.midY - candidate.midY) <= 0.14 &&
            (0.55...1.80).contains(widthRatio) &&
            (0.55...1.80).contains(heightRatio)
    }

    private func isPlausiblePendingMatch(from previous: CGRect, to candidate: CGRect) -> Bool {
        intersectionOverUnion(previous, candidate) >= 0.05 || centerDistance(previous, candidate) <= 0.14
    }

    private func logDetectionFrame(_ observations: [(CGRect, Float, String)], selected: (CGRect, Float, String)?) {
        let now = CACurrentMediaTime()
        guard now - lastDetectionLogTime >= 1 else { return }
        lastDetectionLogTime = now
        let candidates = observations.map {
            String(format: "%@ conf=%.2f box=(%.3f,%.3f,%.3f,%.3f)", $0.2, $0.1, $0.0.minX, $0.0.minY, $0.0.width, $0.0.height)
        }.joined(separator: ";")
        let selectedDetails = selected.map {
            String(format: "%@ conf=%.2f box=(%.3f,%.3f,%.3f,%.3f)", $0.2, $0.1, $0.0.minX, $0.0.minY, $0.0.width, $0.0.height)
        } ?? "none"
        diagnostics?.record(type: "detection_frame", details: "candidateCount=\(observations.count), candidates=[\(candidates)], selected=\(selectedDetails), tracked=\(trackedBox?.debugDescription ?? "none"), pendingFrames=\(pendingBoxFrames)")
    }

    private func closestVehicle(in observations: [(CGRect, Float, String)]) -> (CGRect, Float, String)? {
        observations.max { lhs, rhs in
            let lhsBottom = 1 - lhs.0.minY
            let rhsBottom = 1 - rhs.0.minY
            if abs(lhsBottom - rhsBottom) < 0.01 {
                return lhs.0.width < rhs.0.width
            }
            return lhsBottom < rhsBottom
        }
    }

    private func mergeOverlappingDetections(_ observations: [(CGRect, Float, String)]) -> [(CGRect, Float, String)] {
        var merged: [(CGRect, Float, String)] = []
        for observation in observations {
            guard let index = merged.firstIndex(where: { intersectionOverUnion($0.0, observation.0) > 0.30 }) else {
                merged.append(observation)
                continue
            }
            let existing = merged[index]
            let label = existing.1 >= observation.1 ? existing.2 : observation.2
            merged[index] = (existing.0.union(observation.0), max(existing.1, observation.1), label)
        }
        return merged
    }

    private func smoothTrackedBox(_ box: CGRect) -> CGRect {
        let alpha: CGFloat = 0.35
        let smoothed: CGRect
        if let trackedBox {
            smoothed = CGRect(
                x: trackedBox.minX + (box.minX - trackedBox.minX) * alpha,
                y: trackedBox.minY + (box.minY - trackedBox.minY) * alpha,
                width: trackedBox.width + (box.width - trackedBox.width) * alpha,
                height: trackedBox.height + (box.height - trackedBox.height) * alpha
            )
        } else {
            smoothed = box
        }
        trackedBox = smoothed
        trackedBoxTimestamp = CACurrentMediaTime()
        return smoothed
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let union = lhs.area + rhs.area - intersection.area
        return union > 0 ? intersection.area / union : 0
    }

    private func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }

    private static func isInsideForwardLaneROI(x: CGFloat, yFromTop: CGFloat) -> Bool {
        let topY: CGFloat = 0.38
        let bottomY: CGFloat = 0.95
        guard yFromTop >= topY && yFromTop <= bottomY else { return false }
        let progress = (yFromTop - topY) / (bottomY - topY)
        let left = 0.38 + (0.20 - 0.38) * progress
        let right = 0.62 + (0.80 - 0.62) * progress
        return x >= left && x <= right
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
