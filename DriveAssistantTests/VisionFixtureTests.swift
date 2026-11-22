import XCTest
import CoreImage
import CoreML
import Vision
import CoreVideo
@testable import DriveAssistant

/// End-to-end vision & OCR fixture tests using real images from the test bundle.
/// Loads images, converts to CVPixelBuffer, runs through unified model (vn_adas_unified_ios16),
/// TrafficSignDetector (2 consecutive frame passes), and LaneDetector.
/// These tests verify the pipeline executes without crashing; specific detection results
/// depend on the test image content and are not asserted.
@MainActor
final class VisionFixtureTests: XCTestCase {

    var cameraManager: CameraManager!
    var trafficSignDetector: TrafficSignDetector!
    var laneDetector: LaneDetector!
    var visionModel: VNCoreMLModel!

    override func setUp() async throws {
        try await super.setUp()

        // Load the unified model with CPU-only compute units for Simulator/CI reliability
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly

        guard let modelURL = Bundle(for: Self.self).url(forResource: "vn_adas_unified_ios16", withExtension: "mlmodelc") ??
                Bundle(for: Self.self).url(forResource: "vn_adas_unified_ios16", withExtension: "mlpackage") else {
            throw XCTSkip("Unified model not found in test bundle")
        }

        let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        visionModel = try VNCoreMLModel(for: mlModel)

        cameraManager = CameraManager()
        trafficSignDetector = cameraManager.trafficSignDetector
        laneDetector = LaneDetector()
    }

    override func tearDown() {
        cameraManager = nil
        trafficSignDetector = nil
        laneDetector = nil
        visionModel = nil
        super.tearDown()
    }

    // MARK: - urban_sign_60.jpg

    /// Tests that urban_sign_60.jpg runs through the full vision pipeline:
    /// - Unified model inference produces observations
    /// - TrafficSignDetector processes 2 consecutive frames without error
    /// - LaneDetector processes frame without error
    func testUrbanSign60_PipelineExecutes() async throws {
        // Load test image from bundle
        guard let imageURL = Bundle(for: Self.self).url(forResource: "urban_sign_60", withExtension: "jpg") else {
            throw XCTSkip("urban_sign_60.jpg not found in test bundle")
        }

        let ciImage = CIImage(contentsOf: imageURL)!
        let pixelBuffer = try createPixelBuffer(from: ciImage, width: 1280, height: 720)

        // Run through unified model (VNCoreMLRequest)
        let observations = try await runUnifiedModel(pixelBuffer: pixelBuffer)

        // Verify model produces some observations (vehicle or sign detections)
        XCTAssertFalse(observations.isEmpty, "Unified model should produce at least one observation")

        // Run through TrafficSignDetector - requires 2 consecutive frame passes
        trafficSignDetector.setVisionOrientation(.up)
        trafficSignDetector.setThermalState(.nominal)

        // First pass - starts confirmation
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        // Second pass - continues confirmation
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)
        try await Task.sleep(nanoseconds: 200_000_000)

        // TrafficSignDetector should not crash; detectedSpeedLimit may be nil depending on image content
        _ = await trafficSignDetector.detectedSpeedLimit
        _ = await trafficSignDetector.detectedEndOfAllRestrictions

        // Run through LaneDetector
        laneDetector.processFrame(pixelBuffer: pixelBuffer, speedKMPH: 60)
        try await Task.sleep(nanoseconds: 200_000_000)

        // LaneDetector should not crash; confidences may be low depending on image
        await MainActor.run {
            let leftConf = laneDetector.leftLaneConfidence
            let rightConf = laneDetector.rightLaneConfidence
            // Just verify properties are accessible (not NaN)
            XCTAssertFalse(leftConf.isNaN, "Left lane confidence should be valid")
            XCTAssertFalse(rightConf.isNaN, "Right lane confidence should be valid")
        }
    }

    // MARK: - highway_sign_40_dp135.jpg

    /// Tests that highway_sign_40_dp135.jpg runs through the full vision pipeline:
    /// - Unified model inference produces observations
    /// - TrafficSignDetector processes 2 consecutive frames without error
    /// - LaneDetector processes frame without error
    func testHighwaySign40DP135_PipelineExecutes() async throws {
        // Load test image from bundle
        guard let imageURL = Bundle(for: Self.self).url(forResource: "highway_sign_40_dp135", withExtension: "jpg") else {
            throw XCTSkip("highway_sign_40_dp135.jpg not found in test bundle")
        }

        let ciImage = CIImage(contentsOf: imageURL)!
        let pixelBuffer = try createPixelBuffer(from: ciImage, width: 1280, height: 720)

        // Run through unified model
        let observations = try await runUnifiedModel(pixelBuffer: pixelBuffer)

        // Verify model produces some observations
        XCTAssertFalse(observations.isEmpty, "Unified model should produce at least one observation")

        // Verify no large detection at bottom of frame (hood exclusion test)
        let largeBottomDetections = observations.filter { obs in
            guard let label = obs.labels.first else { return false }
            let box = obs.boundingBox
            let boxBottomYFromTop = 1.0 - box.minY
            return label.identifier == "car" && boxBottomYFromTop >= 0.88 && box.width > 0.55
        }
        XCTAssertTrue(largeBottomDetections.isEmpty, "Should exclude hood detection at bottom of frame")

        // Run through TrafficSignDetector - 2 frame passes for confirmation
        trafficSignDetector.setVisionOrientation(.up)
        trafficSignDetector.setThermalState(.nominal)

        // First pass
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Second pass
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)
        try await Task.sleep(nanoseconds: 200_000_000)

        // TrafficSignDetector should not crash
        _ = await trafficSignDetector.detectedSpeedLimit
        _ = await trafficSignDetector.detectedEndOfAllRestrictions

        // Run through LaneDetector
        laneDetector.processFrame(pixelBuffer: pixelBuffer, speedKMPH: 80)
        try await Task.sleep(nanoseconds: 200_000_000)

        // LaneDetector should not crash
        await MainActor.run {
            let leftConf = laneDetector.leftLaneConfidence
            let rightConf = laneDetector.rightLaneConfidence
            XCTAssertFalse(leftConf.isNaN, "Left lane confidence should be valid")
            XCTAssertFalse(rightConf.isNaN, "Right lane confidence should be valid")
        }
    }

    // MARK: - Helper Methods

    private func createPixelBuffer(from ciImage: CIImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "VisionFixtureTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CVPixelBuffer"])
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CIContext()
        context.render(ciImage, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())

        return buffer
    }

    private func runUnifiedModel(pixelBuffer: CVPixelBuffer) async throws -> [VNRecognizedObjectObservation] {
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        return request.results as? [VNRecognizedObjectObservation] ?? []
    }
}