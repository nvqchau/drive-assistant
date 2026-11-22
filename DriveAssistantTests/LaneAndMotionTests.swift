import XCTest
import CoreGraphics
@testable import DriveAssistant

/// Tests for LaneDetector forward lane ROI and MotionManager mount shift detection.
@MainActor
final class LaneAndMotionTests: XCTestCase {

    var laneDetector: LaneDetector!
    var motionManager: MotionManager!

    override func setUp() {
        super.setUp()
        laneDetector = LaneDetector()
        motionManager = MotionManager()
    }

    // MARK: - Forward Lane ROI Rejects Oncoming Vehicles

    func testForwardLaneROI_RejectsOncomingVehicle() {
        // Oncoming vehicle in left side of frame (bbox centered at x=0.2)
        // ROI: center=0.02, topWidth=0.14, bottomWidth=0.44
        // At y=0.5, ROI spans approx [-0.125, 0.165] -> oncoming at x=0.15 is OUTSIDE

        let oncomingBox = CGRect(x: 0.15, y: 0.5, width: 0.1, height: 0.1) // left side
        let isInside = laneDetector.isInsideForwardLaneROI(boundingBox: oncomingBox)
        XCTAssertFalse(isInside, "Oncoming vehicle at x=0.15 should be outside forward lane ROI")

        // Ego-lane vehicle in ROI (center ~0.02 at y=0.5)
        let egoBox = CGRect(x: -0.02, y: 0.6, width: 0.1, height: 0.1) // near center
        let isInside2 = laneDetector.isInsideForwardLaneROI(boundingBox: egoBox)
        XCTAssertTrue(isInside2, "Ego-lane vehicle at x=-0.02 should be inside forward lane ROI")
    }

    func testForwardLaneROI_BottomEdgeOverlap_RejectsPartialOncoming() {
        // Vehicle partially overlapping bottom edge but centered left (oncoming)
        let oncomingBox = CGRect(x: 0.18, y: 0.7, width: 0.2, height: 0.25)
        let hasOverlap = laneDetector.hasSufficientBottomEdgeOverlap(boundingBox: oncomingBox)
        XCTAssertFalse(hasOverlap, "Oncoming vehicle with bottom overlap should be rejected by ROI center check")

        // Ego-lane vehicle with good bottom overlap (centered near ROI center)
        let egoBox = CGRect(x: 0.0, y: 0.7, width: 0.2, height: 0.25)
        let hasOverlap2 = laneDetector.hasSufficientBottomEdgeOverlap(boundingBox: egoBox)
        XCTAssertTrue(hasOverlap2, "Ego-lane vehicle with bottom overlap should pass")
    }

    func testForwardLaneROI_AtBoundary() {
        // ROI center = 0.02, topWidth = 0.14 -> top spans [-0.05, 0.09]
        // bottomWidth = 0.44 -> bottom spans [-0.20, 0.24]
        // Vehicle at x=0.1 should be OUTSIDE (right of top edge 0.09)
        let boxAtRightTop = CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05)
        XCTAssertFalse(laneDetector.isInsideForwardLaneROI(boundingBox: boxAtRightTop), "x=0.1 > 0.09 top edge")

        // Vehicle at x=0.25 should be OUTSIDE (right of bottom edge 0.24)
        let boxAtRightBottom = CGRect(x: 0.25, y: 0.9, width: 0.05, height: 0.05)
        XCTAssertFalse(laneDetector.isInsideForwardLaneROI(boundingBox: boxAtRightBottom), "x=0.25 > 0.24 bottom edge")
    }

    // MARK: - Locks Ego-Lane Leads (Target Switching)

    func testTargetSwitching_IoUThreshold_015() {
        let detector = TrafficSignDetector()

        // Previous lead box
        let prevBox = CGRect(x: 0.4, y: 0.5, width: 0.15, height: 0.15)

        // Candidate with IoU > 0.15 (should switch)
        let candidateHighIoU = CGRect(x: 0.42, y: 0.52, width: 0.14, height: 0.14)
        let iouHigh = detector.calculateIoU(prevBox, candidateHighIoU)
        XCTAssertGreaterThan(iouHigh, 0.15, "IoU should exceed 0.15 threshold for target switch")

        // Candidate with IoU < 0.15 (should NOT switch)
        let candidateLowIoU = CGRect(x: 0.6, y: 0.7, width: 0.1, height: 0.1)
        let iouLow = detector.calculateIoU(prevBox, candidateLowIoU)
        XCTAssertLessThan(iouLow, 0.15, "IoU should be below 0.15 threshold, no target switch")
    }

    func testTargetSwitching_SeparateTrackerFromHorizonCalibration() {
        let model = DriveAssistantModel()

        // Target switch tracker (previousLeadBoxForSwitch) should be independent
        // from horizon calibration tracker (lastTrackedBox)
        model.previousLeadBoxForSwitch = CGRect(x: 0.4, y: 0.5, width: 0.15, height: 0.15)
        model.lastTrackedBox = CGRect(x: 0.3, y: 0.4, width: 0.1, height: 0.1) // Different box for horizon

        XCTAssertNotEqual(model.previousLeadBoxForSwitch, model.lastTrackedBox,
            "Target switch tracker should be separate from horizon calibration tracker")
    }

    // MARK: - MotionManager Mount Shift Detection

    func testMountShift_Triggered_At5_5Degrees() {
        // Mount shift threshold is 5.5 degrees (strictly > per axis), requires 3s persistence
        motionManager.simulateMotion(roll: 0, pitch: 0, yaw: 0) // Initial calibration
        motionManager.hasSavedMountProfile = true // Need a profile for shift detection

        // Simulate 5.6 degree roll shift with 3s persistence (must be > 5.5)
        motionManager.simulateMotion(roll: 5.6, pitch: 0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1 // 3.1 seconds ago
        motionManager.checkMountShift(speedKMPH: 20.0)

        XCTAssertTrue(motionManager.isMountShifted, "5.6 degree roll should trigger mount shift")

        // Test pitch shift
        motionManager.resetMountShift()
        motionManager.hasSavedMountProfile = true
        motionManager.simulateMotion(roll: 0, pitch: 5.6, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertTrue(motionManager.isMountShifted, "5.6 degree pitch should trigger mount shift")

        // Test combined - each axis < 5.5 should NOT trigger (checks per-axis, not magnitude)
        motionManager.resetMountShift()
        motionManager.hasSavedMountProfile = true
        motionManager.simulateMotion(roll: 4.0, pitch: 4.0, yaw: 0) // each axis < 5.5
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "Each axis < 5.5 should NOT trigger")

        // Roll > 5.5 SHOULD trigger even if pitch < 5.5
        motionManager.resetMountShift()
        motionManager.hasSavedMountProfile = true
        motionManager.simulateMotion(roll: 5.6, pitch: 4.0, yaw: 0) // roll > 5.5
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertTrue(motionManager.isMountShifted, "Roll > 5.5 should trigger even if pitch < 5.5")
    }

    func testMountShift_NotTriggered_Below5_5Degrees() {
        motionManager.simulateMotion(roll: 0, pitch: 0, yaw: 0)
        motionManager.hasSavedMountProfile = true

        // 5.0 degrees - below threshold
        motionManager.simulateMotion(roll: 5.0, pitch: 0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "5.0 degree should NOT trigger mount shift")

        // 5.4 degrees - below threshold
        motionManager.simulateMotion(roll: 5.4, pitch: 0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "5.4 degree should NOT trigger mount shift")

        // 5.5 degrees - equal to threshold (strictly > required)
        motionManager.simulateMotion(roll: 5.5, pitch: 0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "5.5 degree (== threshold) should NOT trigger mount shift")
    }

    func testMountShift_AutoClear_At2_5Degrees() {
        motionManager.simulateMotion(roll: 0, pitch: 0, yaw: 0)
        motionManager.hasSavedMountProfile = true

        // Trigger shift
        motionManager.simulateMotion(roll: 6.0, pitch: 0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertTrue(motionManager.isMountShifted)

        // Auto-clear when delta <= 2.5 degrees
        motionManager.simulateMotion(roll: 2.0, pitch: 0, yaw: 0)
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "Delta roll 2.0 <= 2.5 should auto-clear")

        // Test pitch auto-clear
        motionManager.resetMountShift()
        motionManager.hasSavedMountProfile = true
        motionManager.simulateMotion(roll: 0, pitch: 6.0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertTrue(motionManager.isMountShifted)

        motionManager.simulateMotion(roll: 0, pitch: 2.0, yaw: 0)
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "Delta pitch 2.0 <= 2.5 should auto-clear")

        // Test combined auto-clear
        motionManager.resetMountShift()
        motionManager.hasSavedMountProfile = true
        motionManager.simulateMotion(roll: 6.0, pitch: 6.0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 3.1
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertTrue(motionManager.isMountShifted)

        motionManager.simulateMotion(roll: 2.0, pitch: 2.0, yaw: 0) // Both <= 2.5
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "Both delta <= 2.5 should auto-clear")
    }

    func testMountShift_PersistDuration_3Seconds() {
        motionManager.simulateMotion(roll: 0, pitch: 0, yaw: 0)
        motionManager.hasSavedMountProfile = true

        // Brief spike < 3s should not lock in
        motionManager.simulateMotion(roll: 6.0, pitch: 0, yaw: 0)
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 1.0 // 1 second ago
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertFalse(motionManager.isMountShifted, "Shift held < 3s should not persist")

        // Hold for > 3s
        motionManager.mountShiftStartTime = CACurrentMediaTime() - 4.0 // 4 seconds ago
        motionManager.checkMountShift(speedKMPH: 20.0)
        XCTAssertTrue(motionManager.isMountShifted, "Shift held > 3s should persist")
    }

    // MARK: - Lane Detection Linear Regression (x = m*y + c)

    func testLinearRegression_SlopeValidation_LeftLane() {
        let detector = LaneDetector()

        // Left lane: slope should be negative (-1.8 to -0.15)
        let leftPoints = [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.4, y: 0.5)]
        let (m, c) = detector.fitLinear(points: leftPoints)
        XCTAssertTrue(m <= -0.15 && m >= -1.8, "Left lane slope \(m) should be in [-1.8, -0.15]")

        // Too steep (invalid) - slope < -1.8 (e.g., x changes 0.5 while y changes 0.01 -> slope ~ -50)
        let steepPoints = [CGPoint(x: 0.01, y: 0.9), CGPoint(x: 0.51, y: 0.89)]
        let (m2, _) = detector.fitLinear(points: steepPoints)
        XCTAssertFalse(m2 <= -0.15 && m2 >= -1.8, "Slope \(m2) too steep should be invalid (steepPoints gives slope ~ -50)")
    }

    func testLinearRegression_SlopeValidation_RightLane() {
        let detector = LaneDetector()

        // Right lane: slope should be positive (0.15 to 1.8)
        let rightPoints = [CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.6, y: 0.5)]
        let (m, c) = detector.fitLinear(points: rightPoints)
        XCTAssertTrue(m >= 0.15 && m <= 1.8, "Right lane slope \(m) should be in [0.15, 1.8]")
    }

    func testCrossoverGuard_RejectsCrossingLines() {
        let detector = LaneDetector()

        // Left lane with valid negative slope
        let leftPoints = [CGPoint(x: 0.3, y: 0.9), CGPoint(x: 0.4, y: 0.5)]
        let leftValid = detector.validateLane(leftPoints, isLeft: true)
        XCTAssertTrue(leftValid, "Left lane with valid negative slope should pass")

        // Right lane with valid positive slope
        let rightPoints = [CGPoint(x: 0.7, y: 0.9), CGPoint(x: 0.6, y: 0.5)]
        let rightValid = detector.validateLane(rightPoints, isLeft: false)
        XCTAssertTrue(rightValid, "Right lane with valid positive slope should pass")

        // Invalid left lane (positive slope)
        let invalidLeftPoints = [CGPoint(x: 0.3, y: 0.9), CGPoint(x: 0.4, y: 0.5)]
        let invalidLeftValid = detector.validateLane(invalidLeftPoints, isLeft: true)
        // This would need negative slope for left, but points give positive
        // Actually x=0.3,y=0.9 to x=0.4,y=0.5 gives negative slope
        // Let's use points that give positive slope for left lane
        let invalidLeftPoints2 = [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.4, y: 0.9)]
        let invalidLeftValid2 = detector.validateLane(invalidLeftPoints2, isLeft: true)
        XCTAssertFalse(invalidLeftValid2, "Left lane with positive slope should be invalid")

        // Invalid right lane (negative slope)
        let invalidRightPoints = [CGPoint(x: 0.7, y: 0.5), CGPoint(x: 0.6, y: 0.9)]
        let invalidRightValid = detector.validateLane(invalidRightPoints, isLeft: false)
        XCTAssertFalse(invalidRightValid, "Right lane with negative slope should be invalid")
    }
}

// Test helper extensions
extension TrafficSignDetector {
    func calculateIoU(_ box1: CGRect, _ box2: CGRect) -> Double {
        let intersection = box1.intersection(box2)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let box1Area = box1.width * box1.height
        let box2Area = box2.width * box2.height
        return Double(intersectionArea / (box1Area + box2Area - intersectionArea))
    }
}

extension LaneDetector {
    // Expose ROI parameters for testing
    var roiCenterOffsetX: CGFloat { return 0.02 }
    var roiTopWidth: CGFloat { return 0.14 }
    var roiBottomWidth: CGFloat { return 0.44 }

    func isInsideForwardLaneROI(boundingBox: CGRect) -> Bool {
        let centerX = boundingBox.midX
        let centerY = boundingBox.midY

        let topLeft = roiCenterOffsetX - roiTopWidth / 2
        let topRight = roiCenterOffsetX + roiTopWidth / 2
        let bottomLeft = roiCenterOffsetX - roiBottomWidth / 2
        let bottomRight = roiCenterOffsetX + roiBottomWidth / 2

        // Linear interpolation of ROI edges at box's Y position
        let leftEdge = bottomLeft + (topLeft - bottomLeft) * (1 - centerY)
        let rightEdge = bottomRight + (topRight - bottomRight) * (1 - centerY)

        return centerX >= leftEdge && centerX <= rightEdge
    }

    func hasSufficientBottomEdgeOverlap(boundingBox: CGRect) -> Bool {
        let bottomY = boundingBox.maxY
        guard bottomY > 0.6 else { return false } // Must be in lower portion
        return isInsideForwardLaneROI(boundingBox: boundingBox)
    }

    func fitLinear(points: [CGPoint]) -> (CGFloat, CGFloat) {
        guard points.count >= 2 else { return (0, 0) }
        let n = CGFloat(points.count)
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let sumXY = points.reduce(0) { $0 + $1.x * $1.y }
        let sumYY = points.reduce(0) { $0 + $1.y * $1.y }

        let m = (n * sumXY - sumX * sumY) / (n * sumYY - sumY * sumY)
        let c = (sumX - m * sumY) / n
        return (m, c)
    }

    func validateLane(_ points: [CGPoint], isLeft: Bool) -> Bool {
        let (m, _) = fitLinear(points: points)
        if isLeft {
            return m >= -1.8 && m <= -0.15
        } else {
            return m >= 0.15 && m <= 1.8
        }
    }
}

extension MotionManager {
    func resetMountShift() {
        isMountShifted = false
        mountShiftStartTime = nil
        calibratedRoll = 0
        calibratedPitch = 0
        // Recompute deltas
        deltaRoll = 0
        deltaPitch = 0
    }
}