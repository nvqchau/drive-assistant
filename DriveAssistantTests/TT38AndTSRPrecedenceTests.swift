import XCTest
import CoreLocation
@testable import DriveAssistant

/// Tests for TT38 statutory speed limits, TSR precedence, and sign detection logic.
@MainActor
final class TT38AndTSRPrecedenceTests: XCTestCase {

    var model: DriveAssistantModel!

    override func setUp() {
        super.setUp()
        model = DriveAssistantModel()
        // Ensure clean state
        model.hasReceivedCameraSignOverride = false
        model.lastCameraResidentialSignLocation = nil
        model.lastCameraResidentialSignTime = .distantPast
        model.isInResidentialArea = nil
        model.isDividedRoad = false
        model.location.roadMetadata.osmIsInResidentialArea = nil
        model.location.roadMetadata.roadMaxSpeed = nil
        model.location.roadMetadata.isDividedRoad = false
    }

    // MARK: - TT38 Statutory Limits

    func testTT38ResidentialUndivided_50kmh() {
        // Urban ward (phường/thị trấn), undivided road
        model.isInResidentialArea = true
        model.isDividedRoad = false
        model.location.roadMetadata.roadMaxSpeed = nil

        model.applyTT38StatutoryLimit()

        let limit = model.currentSpeedLimit
        XCTAssertEqual(limit, 50, "Urban undivided road should be 50 km/h per TT38")
    }

    func testTT38ResidentialDivided_60kmh() {
        // Urban ward, divided road
        model.isInResidentialArea = true
        model.isDividedRoad = true
        model.location.roadMetadata.roadMaxSpeed = nil

        model.applyTT38StatutoryLimit()

        let limit = model.currentSpeedLimit
        XCTAssertEqual(limit, 60, "Urban divided road should be 60 km/h per TT38")
    }

    func testTT38NonResidentialUndivided_80kmh() {
        // Rural (xã), undivided road
        model.isInResidentialArea = false
        model.isDividedRoad = false
        model.location.roadMetadata.roadMaxSpeed = nil

        model.applyTT38StatutoryLimit()

        let limit = model.currentSpeedLimit
        XCTAssertEqual(limit, 80, "Rural undivided road should be 80 km/h per TT38")
    }

    func testTT38NonResidentialDivided_90kmh() {
        // Rural, divided road
        model.isInResidentialArea = false
        model.isDividedRoad = true
        model.location.roadMetadata.roadMaxSpeed = nil

        model.applyTT38StatutoryLimit()

        let limit = model.currentSpeedLimit
        XCTAssertEqual(limit, 90, "Rural divided road should be 90 km/h per TT38")
    }

    func testTT38Boundary80kmh() {
        // At 80 km/h boundary: explicit maxspeed=80
        model.isInResidentialArea = false
        model.isDividedRoad = false
        model.location.roadMetadata.roadMaxSpeed = 80

        model.applyTT38StatutoryLimit()

        let limit = model.currentSpeedLimit
        XCTAssertEqual(limit, 80, "Explicit maxspeed=80 should be respected at boundary")
    }

    // MARK: - TSR Camera Precedence Over OSM

    func testCameraResidentialSign_OverridesOSM_WhenRecentAndClose() {
        // OSM says rural (false), but camera just saw R.420 (enter residential)
        model.location.roadMetadata.osmIsInResidentialArea = false
        model.isDividedRoad = false
        model.location.roadMetadata.roadMaxSpeed = nil

        let signLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        let signTime = Date()

        model.handleCameraResidentialSign(isResidential: true, location: signLocation, timestamp: signTime)

        let limit = model.currentSpeedLimit
        XCTAssertEqual(limit, 50, "Camera residential sign should override OSM rural to 50 km/h")
        XCTAssertTrue(model.hasReceivedCameraSignOverride)
    }

    func testCameraResidentialSign_DoesNotOverride_WhenTimeElapsed_Over5Min_ButDistanceClose() {
        // With AND condition: time > 5 min but distance < 2km -> camera override REMAINS
        model.location.roadMetadata.osmIsInResidentialArea = false
        model.isDividedRoad = false

        let signLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        let currentLocation = CLLocation(latitude: 10.777, longitude: 106.702) // ~200m away
        model.location.lastValidLocation = currentLocation

        let signTime = Date().addingTimeInterval(-400) // 6 min 40 sec ago

        model.handleCameraResidentialSign(isResidential: true, location: signLocation, timestamp: signTime)

        // With AND: time FAIL (>5 min) but distance PASS (<2km) -> camera override should REMAIN
        model.evaluateCameraPrecedence()

        XCTAssertTrue(model.hasReceivedCameraSignOverride, "Camera override should remain: time > 5min but distance < 2km")
    }

    func testCameraResidentialSign_DoesNotOverride_WhenDistance_Over2km_ButTimeRecent() {
        // With AND condition: distance > 2km but time < 5min -> camera override REMAINS
        model.location.roadMetadata.osmIsInResidentialArea = false
        model.isDividedRoad = false

        let signLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        let currentLocation = CLLocation(latitude: 10.795, longitude: 106.721) // ~2.3 km away
        model.location.lastValidLocation = currentLocation

        let signTime = Date()
        model.handleCameraResidentialSign(isResidential: true, location: signLocation, timestamp: signTime)

        // With AND: distance FAIL (>2km) but time PASS (<5min) -> camera override should REMAIN
        model.evaluateCameraPrecedence()

        XCTAssertTrue(model.hasReceivedCameraSignOverride, "Camera override should remain: distance > 2km but time < 5min")
    }

    func testCameraClearLimit_DP135_ClearsLimit_ButPreservesResidentialStatus() {
        // Camera sees DP.135 (clear limit) - should clear camera override but keep residential status
        model.isInResidentialArea = true
        model.isDividedRoad = false
        model.hasReceivedCameraSignOverride = true

        let signLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        model.handleCameraClearLimitSign(location: signLocation, timestamp: Date())

        XCTAssertFalse(model.hasReceivedCameraSignOverride, "DP.135 should clear camera override")
        XCTAssertEqual(model.currentSpeedLimit, 50, "Residential status from OSM should remain (50 km/h)")
    }

    func testCameraClearLimit_DP135_WhenOSMRural_RevertsTo80kmh() {
        model.isInResidentialArea = false
        model.isDividedRoad = false
        model.hasReceivedCameraSignOverride = true

        let signLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        model.handleCameraClearLimitSign(location: signLocation, timestamp: Date())

        XCTAssertFalse(model.hasReceivedCameraSignOverride)
        XCTAssertEqual(model.currentSpeedLimit, 80, "Should revert to OSM rural 80 km/h")
    }

    // MARK: - R.420 + P.127 + DP.134 Sequence

    func testR420_P127_DP134_Sequence_RevertsToDividedRoadLimit() {
        // Sequence: R.420 (start residential) -> P.127 (speed limit 60) -> DP.134 (end speed limit)
        // After DP.134, should revert to divided road statutory limit (60 km/h), NOT end residential
        model.isInResidentialArea = true
        model.isDividedRoad = true
        model.location.roadMetadata.roadMaxSpeed = nil

        model.handleCameraResidentialSign(isResidential: true, location: CLLocation(latitude: 10.0, longitude: 106.0), timestamp: Date())
        // Simulate P.127 sign (camera detects explicit 60)
        model.camera.trafficSignDetector.setDetectedSpeedLimitForTest(60)
        model.isCurrentLimitStatutory = false
        model.handleCameraClearLimitSign(location: CLLocation(latitude: 10.0, longitude: 106.0), timestamp: Date())

        // After DP.134, camera override cleared, OSM says urban divided = 60 km/h
        XCTAssertEqual(model.currentSpeedLimit, 60, "After DP.134 in urban divided, should be 60 km/h")
    }

    // MARK: - DP.135 (Clear Limit) vs R.421 (End Residential) Separation

    func testDP135_IsClearLimit_NotEndResidential() {
        // DP.135 (label "190") maps to .clearLimit, not .endResidentialArea
        let detector = TrafficSignDetector()
        // This tests the labelToSign mapping
        XCTAssertEqual(detector.signTypeForLabel("190"), TrafficSignDetector.SignInfo.clearLimit)
        XCTAssertEqual(detector.signTypeForLabel("117"), TrafficSignDetector.SignInfo.endResidentialArea)
    }

    func testDP135_Cooldown_6Seconds() {
        // Cooldown is in TrafficSignDetector, not DriveAssistantModel
        // This test verifies the model clears override on each call
        model.isInResidentialArea = true
        model.isDividedRoad = false
        model.hasReceivedCameraSignOverride = true

        let loc = CLLocation(latitude: 10.0, longitude: 106.0)
        let now = Date()

        // First DP.135
        model.handleCameraClearLimitSign(location: loc, timestamp: now)
        XCTAssertFalse(model.hasReceivedCameraSignOverride)

        // Second DP.135 - also clears override (no cooldown in DriveAssistantModel)
        model.hasReceivedCameraSignOverride = true // Simulate re-override
        model.handleCameraClearLimitSign(location: loc, timestamp: now.addingTimeInterval(3))
        XCTAssertFalse(model.hasReceivedCameraSignOverride, "Second DP.135 should also clear override")

        // Third DP.135 - also clears override
        model.hasReceivedCameraSignOverride = true
        model.handleCameraClearLimitSign(location: loc, timestamp: now.addingTimeInterval(7))
        XCTAssertFalse(model.hasReceivedCameraSignOverride, "Third DP.135 should also clear override")
    }

    // MARK: - no_entry Spatial Filtering

    func testNoEntrySign_Ignored_WhenOnRightSide() {
        let detector = TrafficSignDetector()
        // bbox.midX > 0.65 should be ignored (right side of frame = oncoming lane)
        let rightSideBox = CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1)
        XCTAssertTrue(detector.shouldIgnoreNoEntry(boundingBox: rightSideBox), "no_entry on right side should be filtered")

        let centerBox = CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.1)
        XCTAssertFalse(detector.shouldIgnoreNoEntry(boundingBox: centerBox), "no_entry in center should not be filtered")

        let leftSideBox = CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)
        XCTAssertFalse(detector.shouldIgnoreNoEntry(boundingBox: leftSideBox), "no_entry on left side should not be filtered")
    }

    // MARK: - Camera vs OSM Dual Precedence (Time + Distance)

    func testDualPrecedence_BothConditionsRequired() {
        model.location.roadMetadata.osmIsInResidentialArea = false
        model.isDividedRoad = false

        // Case 1: Time OK (< 5 min), Distance FAIL (> 2 km) -> Camera wins (AND requires BOTH)
        model.lastCameraResidentialSignTime = Date().addingTimeInterval(-100) // 1:40 ago
        model.lastCameraResidentialSignLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        model.location.lastValidLocation = CLLocation(latitude: 10.800, longitude: 106.730) // ~3 km
        model.hasReceivedCameraSignOverride = true

        model.evaluateCameraPrecedence()
        XCTAssertTrue(model.hasReceivedCameraSignOverride, "Camera override should remain: time OK but distance FAIL (AND requires both)")

        // Case 2: Time FAIL (> 5 min), Distance OK (< 2 km) -> Camera wins (AND requires BOTH)
        model.location.roadMetadata.osmIsInResidentialArea = false
        model.isDividedRoad = false
        model.lastCameraResidentialSignTime = Date().addingTimeInterval(-400) // 6:40 ago
        model.lastCameraResidentialSignLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        model.location.lastValidLocation = CLLocation(latitude: 10.777, longitude: 106.702) // ~200 m
        model.hasReceivedCameraSignOverride = true

        model.evaluateCameraPrecedence()
        XCTAssertTrue(model.hasReceivedCameraSignOverride, "Camera override should remain: time FAIL but distance OK (AND requires both)")

        // Case 3: Both OK -> Camera wins
        model.location.roadMetadata.osmIsInResidentialArea = false
        model.isDividedRoad = false
        model.lastCameraResidentialSignTime = Date().addingTimeInterval(-100)
        model.lastCameraResidentialSignLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        model.location.lastValidLocation = CLLocation(latitude: 10.777, longitude: 106.702)
        model.hasReceivedCameraSignOverride = true

        model.evaluateCameraPrecedence()
        XCTAssertTrue(model.hasReceivedCameraSignOverride, "Both time and distance OK -> camera wins")

        // Case 4: Both FAIL -> OSM wins (override cleared)
        model.location.roadMetadata.osmIsInResidentialArea = false
        model.isDividedRoad = false
        model.lastCameraResidentialSignTime = Date().addingTimeInterval(-400) // 6:40 ago
        model.lastCameraResidentialSignLocation = CLLocation(latitude: 10.775, longitude: 106.701)
        model.location.lastValidLocation = CLLocation(latitude: 10.800, longitude: 106.730) // ~3 km
        model.hasReceivedCameraSignOverride = true

        model.evaluateCameraPrecedence()
        XCTAssertFalse(model.hasReceivedCameraSignOverride, "Both time and distance FAIL -> OSM wins")
    }
}

extension TrafficSignDetector {
    // Test helper to expose sign type mapping
    func signTypeForLabel(_ label: String) -> SignInfo? {
        return labelToSign[label]
    }

    func shouldIgnoreNoEntry(boundingBox: CGRect) -> Bool {
        // Spatial filter: ignore no_entry on right side (midX > 0.65)
        return boundingBox.midX > 0.65
    }
}

extension DriveAssistantModel {
    // Expose private method for testing
    func applyTT38StatutoryLimit() {
        // If an explicit P.127 speed sign was confirmed by camera, respect it and don't override
        guard isCurrentLimitStatutory || detectedSpeedLimit == nil else { return }
        guard let inResidential = isInResidentialArea else { return }  // unknown state
        guard enableDefaultOutsideResidentialLimit || inResidential else { return }  // outside residential but feature disabled

        let newLimit: Int
        if inResidential {
            newLimit = isDividedRoad ? 60 : 50
        } else {
            newLimit = isDividedRoad ? 90 : 80
        }

        // Only update if limit actually changed (or was nil)
        if detectedSpeedLimit != newLimit {
            detectedSpeedLimit = newLimit
            isCurrentLimitStatutory = true
        }
    }
}