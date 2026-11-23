import XCTest
import CoreImage
import CoreML
import Vision
import CoreVideo
@testable import DriveAssistant

/// End-to-end vision & OCR fixture tests using real images from the test bundle.
/// Loads images, converts to CVPixelBuffer, runs through unified model (vn_adas_unified_ios16),
/// TrafficSignDetector (2 consecutive frame passes), and LaneDetector.
/// Tests assert actual detections: lead vehicle in ego lane, speed limit 60/40/50, DP.135.
@MainActor
final class VisionFixtureTests: XCTestCase {

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

        // Use standalone TrafficSignDetector (no CameraManager) for deterministic unit testing
        trafficSignDetector = TrafficSignDetector()
        laneDetector = LaneDetector()
    }

    override func tearDown() {
        trafficSignDetector = nil
        laneDetector = nil
        visionModel = nil
        super.tearDown()
    }

    // MARK: - urban_sign_60.jpg

    /// Tests that urban_sign_60.jpg produces:
    /// - Unified model detects a lead vehicle in ego lane (car, midX in 0.35...0.65)
    /// - TrafficSignDetector confirms speed limit 60 via CoreML + cropped Vision OCR (2-frame confirmation)
    func testUrbanSign60_DetectsLeadVehicleAndSpeedLimit() async throws {
        // Load test image from bundle
        guard let imageURL = Bundle(for: Self.self).url(forResource: "urban_sign_60", withExtension: "jpg") else {
            throw XCTSkip("urban_sign_60.jpg not found in test bundle")
        }

        let ciImage = CIImage(contentsOf: imageURL)!
        let pixelBuffer = try createPixelBuffer(from: ciImage, width: 1280, height: 720)

        // Run through unified model (VNCoreMLRequest)
        let observations = try await runUnifiedModel(pixelBuffer: pixelBuffer)

        // Verify vehicle detection: at least one "car" in ego lane (midX in 0.35...0.65)
        let carInEgoLane = observations.filter { obs in
            guard let label = obs.labels.first else { return false }
            let midX = obs.boundingBox.midX
            return label.identifier == "car" && label.confidence >= 0.34 && midX >= 0.35 && midX <= 0.65
        }
        XCTAssertFalse(carInEgoLane.isEmpty, "Unified model should detect at least one car in ego lane (midX 0.35...0.65)")

        // Run through TrafficSignDetector - requires 2 consecutive frame passes
        trafficSignDetector.setVisionOrientation(.up)
        trafficSignDetector.setThermalState(.nominal)

        // First pass - starts confirmation
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        // Second pass - should confirm
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)

        // Poll for detectedSpeedLimit (.fast on Simulator completes quickly)
        var detectedLimit: Int? = nil
        let startTime = CACurrentMediaTime()
        let timeout: TimeInterval = 4.0
        let pollInterval: TimeInterval = 0.05

        while CACurrentMediaTime() - startTime < timeout {
            detectedLimit = trafficSignDetector.detectedSpeedLimit
            if detectedLimit != nil { break }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // Diagnostic logging on failure
        if detectedLimit == nil {
            print("=== VisionFixtureTests DIAGNOSTIC: testUrbanSign60_DetectsLeadVehicleAndSpeedLimit ===")
            print("Timeout waiting for detectedSpeedLimit after \(timeout)s")
            print("Observations count: \(observations.count)")
            for (idx, obs) in observations.enumerated() {
                if let label = obs.labels.first {
                    print("  [\(idx)] label=\(label.identifier) confidence=\(label.confidence) bbox=\(obs.boundingBox)")
                }
            }
        }

        // Verify speed limit 60 was detected and confirmed
        XCTAssertEqual(detectedLimit, 60, "Should detect and confirm 60 km/h speed limit")

        // Run through LaneDetector
        laneDetector.processFrame(pixelBuffer: pixelBuffer, speedKMPH: 60)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify lane detection is active
        await MainActor.run {
            let leftConf = laneDetector.leftLaneConfidence
            let rightConf = laneDetector.rightLaneConfidence
            XCTAssertFalse(leftConf.isNaN, "Left lane confidence should be valid")
            XCTAssertFalse(rightConf.isNaN, "Right lane confidence should be valid")
        }
    }

    // MARK: - highway_sign_40_dp135.jpg

    /// Tests that highway_sign_40_dp135.jpg runs through the full vision pipeline:
    /// - Unified model detects a lead vehicle in ego lane (car, midX in 0.35...0.65)
    /// - TrafficSignDetector with pre-seeded 40 km/h limit confirms DP.135 clears it (detectedEndOfAllRestrictions == true)
    /// - LaneDetector locks onto visible highway road markings (confidence > 0.4)
    func testHighwaySign40DP135_PipelineExecutes() async throws {
        // Load test image from bundle
        guard let imageURL = Bundle(for: Self.self).url(forResource: "highway_sign_40_dp135", withExtension: "jpg") else {
            throw XCTSkip("highway_sign_40_dp135.jpg not found in test bundle")
        }

        let ciImage = CIImage(contentsOf: imageURL)!
        let pixelBuffer = try createPixelBuffer(from: ciImage, width: 1280, height: 720)

        // Run through unified model
        let observations = try await runUnifiedModel(pixelBuffer: pixelBuffer)

        // Verify vehicle detection: at least one "car" in ego lane (midX in 0.35...0.65)
        let carInEgoLane = observations.filter { obs in
            guard let label = obs.labels.first else { return false }
            let midX = obs.boundingBox.midX
            return label.identifier == "car" && label.confidence >= 0.34 && midX >= 0.35 && midX <= 0.65
        }
        XCTAssertFalse(carInEgoLane.isEmpty, "Unified model should detect at least one car in ego lane (midX 0.35...0.65)")

        // Verify no large detection at bottom of frame (hood exclusion)
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

        // Seed active speed limit (40 km/h) so DP.135 (label "190") triggers clear limit event
        trafficSignDetector.setDetectedSpeedLimitForTest(40)
        trafficSignDetector.setDetectedEndOfAllRestrictionsForTest(false)

        // First pass
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Second pass
        trafficSignDetector.processObservations(observations, pixelBuffer: pixelBuffer, orientation: .up)

        // Poll for detectedEndOfAllRestrictions (DP.135 clear limit confirmation)
        var detectedEndAll: Bool = false
        let startTime = CACurrentMediaTime()
        let timeout: TimeInterval = 2.5  // increased for clear limit confirmation
        let pollInterval: TimeInterval = 0.05

        while CACurrentMediaTime() - startTime < timeout {
            detectedEndAll = trafficSignDetector.detectedEndOfAllRestrictions
            if detectedEndAll { break }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // Diagnostic logging on failure
        if !detectedEndAll {
            print("=== VisionFixtureTests DIAGNOSTIC: testHighwaySign40DP135_PipelineExecutes ===")
            print("Timeout waiting for DP.135 clear limit after \(timeout)s")
            print("Observations count: \(observations.count)")
            for (idx, obs) in observations.enumerated() {
                if let label = obs.labels.first {
                    print("  [\(idx)] label=\(label.identifier) confidence=\(label.confidence) bbox=\(obs.boundingBox)")
                }
            }
        }

        // Assert: DP.135 cleared the pre-seeded 40 km/h limit
        XCTAssertTrue(detectedEndAll, "DP.135 should clear the pre-seeded 40 km/h limit (detectedEndOfAllRestrictions == true)")
        XCTAssertNil(trafficSignDetector.detectedSpeedLimit, "Speed limit should be cleared after DP.135 confirmation")

        // Run through LaneDetector
        laneDetector.processFrame(pixelBuffer: pixelBuffer, speedKMPH: 80)

        // Poll for lane confidence > 0.4 (headless CI CPU runners need more time)
        var leftConf: Float = 0
        var rightConf: Float = 0
        let lanePollStart = CACurrentMediaTime()
        let lanePollTimeout: TimeInterval = 1.5
        let lanePollInterval: TimeInterval = 0.05

        while CACurrentMediaTime() - lanePollStart < lanePollTimeout {
            await MainActor.run {
                leftConf = laneDetector.leftLaneConfidence
                rightConf = laneDetector.rightLaneConfidence
            }
            if leftConf > 0.4 && rightConf > 0.4 { break }
            try await Task.sleep(nanoseconds: UInt64(lanePollInterval * 1_000_000_000))
        }

        // Verify lane detection locks onto highway markings (confidence > 0.4)
        await MainActor.run {
            XCTAssertGreaterThan(leftConf, 0.4, "Left lane confidence should be > 0.4 on highway markings")
            XCTAssertGreaterThan(rightConf, 0.4, "Right lane confidence should be > 0.4 on highway markings")
        }
    }

    // MARK: - night_rain_urban.jpg

    /// Tests that night_rain_urban.jpg produces:
    /// - Unified model detects lead SUV ("car") in ego lane (midX in 0.30...0.60, confidence >= 0.34), hood excluded
    /// - TrafficSignDetector confirms speed limit 30 via CoreML label "114" + cropped Vision OCR under low-light/wet reflections (2-frame confirmation + polling)
    /// - DriveAssistantModel with roadCondition = .wet at 30 km/h yields activeMinimumDistance = 19.5m (15m * 1.3 wet multiplier)
    func testNightRainUrban_DetectsLeadVehicleSignAndWetTT38() async throws {
        // Load test image from bundle (in TestFixtures subdirectory)
        guard let imageURL = Bundle(for: Self.self).url(forResource: "night_rain_urban", withExtension: "jpg", subdirectory: "TestFixtures") else {
            throw XCTSkip("night_rain_urban.jpg not found in test bundle")
        }

        let ciImage = CIImage(contentsOf: imageURL)!
        let pixelBuffer = try createPixelBuffer(from: ciImage, width: 1280, height: 720)

        // Run through unified model (VNCoreMLRequest)
        let observations = try await runUnifiedModel(pixelBuffer: pixelBuffer)

        // Verify vehicle detection: lead SUV ("car") in ego lane (midX in 0.30...0.60)
        let carInEgoLane = observations.filter { obs in
            guard let label = obs.labels.first else { return false }
            let midX = obs.boundingBox.midX
            return label.identifier == "car" && label.confidence >= 0.34 && midX >= 0.30 && midX <= 0.60
        }
        XCTAssertFalse(carInEgoLane.isEmpty, "Unified model should detect lead SUV in ego lane (midX 0.30...0.60)")

        // Verify no large detection at bottom of frame (hood exclusion)
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

        // Poll for detectedSpeedLimit (.fast on Simulator completes quickly)
        // Night/rain with illuminated 30 km/h sign - CoreML label "114" (20 km/h class) + OCR reads "30"
        var detectedLimit: Int? = nil
        let startTime = CACurrentMediaTime()
        let timeout: TimeInterval = 4.0
        let pollInterval: TimeInterval = 0.05

        while CACurrentMediaTime() - startTime < timeout {
            detectedLimit = trafficSignDetector.detectedSpeedLimit
            if detectedLimit != nil { break }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // Diagnostic logging
        if detectedLimit == nil {
            print("=== VisionFixtureTests DIAGNOSTIC: testNightRainUrban_DetectsLeadVehicleSignAndWetTT38 ===")
            print("No speed limit detected in night/rain image after \(timeout)s")
            print("Observations count: \(observations.count)")
            for (idx, obs) in observations.enumerated() {
                if let label = obs.labels.first {
                    print("  [\(idx)] label=\(label.identifier) confidence=\(label.confidence) bbox=\(obs.boundingBox)")
                }
            }
        }

        // Verify speed limit 30 detected via CoreML label "114" + cropped Vision OCR
        XCTAssertEqual(detectedLimit, 30, "Should detect and confirm 30 km/h speed limit under night/rain")

        // Run through LaneDetector
        laneDetector.processFrame(pixelBuffer: pixelBuffer, speedKMPH: 30)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify lane detection is active
        await MainActor.run {
            let leftConf = laneDetector.leftLaneConfidence
            let rightConf = laneDetector.rightLaneConfidence
            XCTAssertFalse(leftConf.isNaN, "Left lane confidence should be valid")
            XCTAssertFalse(rightConf.isNaN, "Right lane confidence should be valid")
        }

        // Verify DriveAssistantModel wet TT38 calculation: 30 km/h -> base 15m * 1.3 = 19.5m
        let model = DriveAssistantModel()
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 30.0
        model.roadCondition = .wet
        // activeMinimumDistance = tt38Distance(30) * 1.3 = 15 * 1.3 = 19.5
        let activeMinDistance = model.activeMinimumDistance
        XCTAssertEqual(activeMinDistance, 19.5, accuracy: 0.1, "Wet TT38 at 30 km/h should be 19.5m (15 * 1.3)")
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
        // Scale ciImage to fill the target CVPixelBuffer (1280x720) so right-edge
        // signs (e.g., 30 km/h in night_rain_urban.jpg at x=0.814) are not clipped
        let scaleX = CGFloat(width) / ciImage.extent.width
        let scaleY = CGFloat(height) / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        context.render(scaledImage, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())

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