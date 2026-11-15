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
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "drive-assistant.session", qos: .userInitiated)
    private let queue = DispatchQueue(label: "drive-assistant.camera", qos: .userInitiated)
    private var visionModel: VNCoreMLModel?
    private var isConfigured = false
    private var lastInference = CACurrentMediaTime()
    private let normalInferenceInterval = 1.0 / 10.0
    private let seriousInferenceInterval = 1.0 / 5.0
    private let calibrationLock = NSLock()
    private var calibrationFactor: Double = 1.40
    private var orientationObserver: NSObjectProtocol?
    private var runtimeErrorObserver: NSObjectProtocol?
    private let orientationLock = NSLock()
    private var diagnostics: DiagnosticsLogStore?
    private var hasLoggedFrameFormat = false
    private var thermalObserver: NSObjectProtocol?
    private let thermalLock = NSLock()
    private var currentThermalState = ProcessInfo.processInfo.thermalState
    // Landscape right interface orientation places the notch on the left.
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
        if let modelURL = Bundle.main.url(forResource: "YOLOv3TinyInt8LUT", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: modelURL),
           let visionModel = try? VNCoreMLModel(for: model) {
            self.visionModel = visionModel
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
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
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
        let thermalState = thermalStateForInference()
        if thermalState == .critical {
            return
        }
        let now = CACurrentMediaTime()
        let interval = thermalState == .serious ? seriousInferenceInterval : normalInferenceInterval
        guard now - lastInference >= interval, let visionModel else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.error("Capture frame has no pixel buffer")
            return
        }
        if !hasLoggedFrameFormat {
            hasLoggedFrameFormat = true
            diagnostics?.record(type: "camera_frame_format", details: "width=\(CVPixelBufferGetWidth(pixelBuffer)), height=\(CVPixelBufferGetHeight(pixelBuffer)), videoOrientation=\(videoOrientation)")
        }
        lastInference = now
        autoreleasepool {
            let request = VNCoreMLRequest(model: visionModel) { [weak self] request, error in
                if let error {
                    self?.logger.error("Vision request failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                self?.handle(request: request, pixelBuffer: pixelBuffer)
            }
            request.imageCropAndScaleOption = .scaleFill
            let orientation = visionOrientation
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
            } catch {
                logger.error("Vision handler failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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
              let visionOrientation = Self.visionOrientation(for: deviceOrientation) else { return }
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
        // AVCaptureVideoOrientation is opposite to UIDeviceOrientation.
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return nil
        }
    }

    private static func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation? {
        switch deviceOrientation {
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default: return nil
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
        let observations = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation -> (CGRect, Float, String)? in
            guard let label = observation.labels.first, label.confidence >= 0.5,
                  ["car", "truck", "bus", "motorbike"].contains(label.identifier) else { return nil }
            let box = observation.boundingBox
            let bottomCenterYFromTop = 1 - box.minY
            guard Self.isInsideForwardLaneROI(x: box.midX, yFromTop: bottomCenterYFromTop) else { return nil }
            return (box, label.confidence, label.identifier)
        }
        guard let selected = observations.max(by: {
            let firstBottomY = 1 - $0.0.minY
            let secondBottomY = 1 - $1.0.minY
            if firstBottomY == secondBottomY {
                return $0.0.width < $1.0.width
            }
            return firstBottomY < secondBottomY
        }) else {
            DispatchQueue.main.async { self.leadVehicleDistance = nil; self.leadVehicleBox = nil }
            return
        }
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
        let normalizedBoxWidth = Double(selected.0.width)
        guard normalizedBoxWidth > 0 else { return }
        let distance = (realWidth * factor) / normalizedBoxWidth
        DispatchQueue.main.async { self.leadVehicleDistance = distance; self.leadVehicleBox = selected.0 }
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
