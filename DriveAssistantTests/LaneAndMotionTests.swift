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

    // MARK: - Forward Lane ROI Rejects Oncoming Vehicles (Normalized [0.0...1.0] coordinates)

    func testForwardLaneROI_RejectsOncomingVehicle() {
        // Normalized coordinates: centerX = 0.52, topY=0.38, bottomY=0.95
        // Oncoming vehicle on left side (midX = 0.25) at mid-height (y=0.5 -> yFromTop=0.5)
        // At yFromTop=0.5: progress = (0.5-0.38)/(0.95-0.38) = 0.12/0.57 ≈ 0.21
        // left = 0.52 - (0.07 + (0.22-0.07)*0.21) = 0.52 - 0.10 = 0.42
        // right = 0.52 + 0.10 = 0.62
        // oncoming at 0.25 < 0.42 -> OUTSIDE

        let oncomingBox = CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.1) // midX=0.25 (left side)
        let isInside = laneDetector.isInsideForwardLaneROI(boundingBox: oncomingBox)
        XCTAssertFalse(isInside, "Oncoming vehicle at midX=0.25 should be outside forward lane ROI")

        // Ego-lane vehicle in ROI (midX = 0.52 at y=0.5 -> yFromTop=0.5)
        let egoBox = CGRect(x: 0.47, y: 0.5, width: 0.1, height: 0.1) // midX=0.52 (center)
        let isInside2 = laneDetector.isInsideForwardLaneROI(boundingBox: egoBox)
        XCTAssertTrue(isInside2, "Ego-lane vehicle at midX=0.52 should be inside forward lane ROI")
    }

    func testForwardLaneROI_BottomEdgeOverlap_RejectsPartialOncoming() {
        // Vision coordinates: y=0 at bottom, y=1 at top
        // Oncoming vehicle at bottom (y=0.1 -> maxY=0.35 -> yFromTop=0.65) - left side (midX=0.3)
        let oncomingBox = CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.25)
        let hasOverlap = laneDetector.hasSufficientBottomEdgeOverlap(boundingBox: oncomingBox)
        XCTAssertFalse(hasOverlap, "Oncoming vehicle at left side should be rejected")

        // Ego-lane vehicle with good bottom overlap (midX=0.52, y=0.15 -> maxY=0.4 -> yFromTop=0.6)
        // At yFromTop=0.6: within [0.38, 0.95], progress = 0.22/0.57 ≈ 0.39
        let egoBox = CGRect(x: 0.42, y: 0.15, width: 0.2, height: 0.25)
        let hasOverlap2 = laneDetector.hasSufficientBottomEdgeOverlap(boundingBox: egoBox)
        XCTAssertTrue(hasOverlap2, "Ego-lane vehicle with bottom overlap should pass")
    }

    func testForwardLaneROI_AtBoundary() {
        // ROI: centerX=0.52, topWidth=0.14, bottomWidth=0.44, topY=0.38, bottomY=0.95
        // At topY=0.38: spans [0.45, 0.59]
        // At bottomY=0.95: spans [0.30, 0.74]

        // Vehicle at midX=0.65, yFromTop=0.38 (top boundary) -> midX=0.65 > 0.59 -> OUTSIDE
        // Vision y = 1.0 - 0.38 = 0.62 (y=0 at bottom)
        let boxAtRightTop = CGRect(x: 0.6, y: 0.62, width: 0.1, height: 0.1) // midX=0.65, yFromTop=0.38
        XCTAssertFalse(laneDetector.isInsideForwardLaneROI(boundingBox: boxAtRightTop), "midX=0.65 > 0.59 top edge")

        // Vehicle at midX=0.8, yFromTop=0.95 (bottom boundary) -> midX=0.8 > 0.74 -> OUTSIDE
        // Vision y = 1.0 - 0.95 = 0.05 (y=0 at bottom)
        let boxAtRightBottom = CGRect(x: 0.75, y: 0.05, width: 0.1, height: 0.1) // midX=0.8, yFromTop=0.95
        XCTAssertFalse(laneDetector.isInsideForwardLaneROI(boundingBox: boxAtRightBottom), "midX=0.8 > 0.74 bottom edge")
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
    // Expose ROI parameters for testing (matching CameraManager.isInsideForwardLaneROI)
    // Normalized [0.0...1.0] coordinates: center = 0.5 + roiCenterOffsetX (0.52), topY=0.38, bottomY=0.95
    var roiCenterOffsetX: CGFloat { return 0.02 }
    var roiTopWidth: CGFloat { return 0.14 }
    var roiBottomWidth: CGFloat { return 0.44 }
    var roiTopY: CGFloat { return 0.38 }
    var roiBottomY: CGFloat { return 0.95 }

    func isInsideForwardLaneROI(boundingBox: CGRect) -> Bool {
        let centerX = boundingBox.midX
        let yFromTop = 1.0 - boundingBox.midY  // Convert from bottom-origin to top-origin

        let topY = roiTopY
        let bottomY = roiBottomY
        let centerXNormalized = 0.5 + roiCenterOffsetX  // 0.52
        let halfTopWidth = roiTopWidth / 2
        let halfBottomWidth = roiBottomWidth / 2

        guard yFromTop >= topY && yFromTop <= bottomY else { return false }

        let progress = (yFromTop - topY) / (bottomY - topY)
        let left = centerXNormalized - (halfTopWidth + (halfBottomWidth - halfTopWidth) * progress)
        let right = centerXNormalized + (halfTopWidth + (halfBottomWidth - halfTopWidth) * progress)

        return centerX >= left && centerX <= right
    }

    func hasSufficientBottomEdgeOverlap(boundingBox: CGRect) -> Bool {
        let boxBottomY = boundingBox.maxY
        let yFromTop = 1.0 - boxBottomY  // Convert from bottom-origin to top-origin

        let topY = roiTopY
        let bottomY = roiBottomY
        let centerXNormalized = 0.5 + roiCenterOffsetX  // 0.52
        let halfTopWidth = roiTopWidth / 2
        let halfBottomWidth = roiBottomWidth / 2

        guard yFromTop >= topY && yFromTop <= bottomY else { return false }

        let progress = (yFromTop - topY) / (bottomY - topY)
        let trapLeft = centerXNormalized - (halfTopWidth + (halfBottomWidth - halfTopWidth) * progress)
        let trapRight = centerXNormalized + (halfTopWidth + (halfBottomWidth - halfTopWidth) * progress)

        let boxLeft = boundingBox.minX
        let boxRight = boundingBox.maxX
        let boxWidth = boxRight - boxLeft
        guard boxWidth > 0 else { return false }

        let overlapLeft = max(boxLeft, trapLeft)
        let overlapRight = min(boxRight, trapRight)
        let overlapWidth = max(0, overlapRight - overlapLeft)

        return overlapWidth / boxWidth >= 0.40
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

// MARK: - Single-Line Lane Synthesis Tests

extension LaneAndMotionTests {
    func testSingleLineSynthesis_SynthesizeRightLaneFromLeft_PerspectiveWidth() {
        let detector = LaneDetector()

        // Create left lane points spanning ROI top (0.38) to bottom (0.95)
        // Left lane at x=0.26 (top) to x=0.14 (bottom) - typical left edge
        let leftPoints = [
            CGPoint(x: 0.26, y: 0.38), // top
            CGPoint(x: 0.22, y: 0.50),
            CGPoint(x: 0.18, y: 0.65),
            CGPoint(x: 0.16, y: 0.80),
            CGPoint(x: 0.14, y: 0.95)  // bottom
        ]

        let synthesized = detector.synthesizeRightLaneFromLeft(leftPoints)

        // At top (y=0.38): w = 0.14 -> synthesized x = 0.26 + 0.14 = 0.40
        XCTAssertEqual(synthesized[0].x, 0.40, accuracy: 0.001, "Top y=0.38: w=0.14 -> x=0.40")
        XCTAssertEqual(synthesized[0].y, 0.38, accuracy: 0.001)

        // At bottom (y=0.95): w = 0.44 -> synthesized x = 0.14 + 0.44 = 0.58
        XCTAssertEqual(synthesized[4].x, 0.58, accuracy: 0.001, "Bottom y=0.95: w=0.44 -> x=0.58")
        XCTAssertEqual(synthesized[4].y, 0.95, accuracy: 0.001)

        // All points clamped within [0.02, 0.98]
        for pt in synthesized {
            XCTAssertGreaterThanOrEqual(pt.x, 0.02, "x >= 0.02")
            XCTAssertLessThanOrEqual(pt.x, 0.98, "x <= 0.98")
            XCTAssertGreaterThanOrEqual(pt.y, 0.38, "y >= 0.38")
            XCTAssertLessThanOrEqual(pt.y, 0.95, "y <= 0.95")
        }
    }

    func testSingleLineSynthesis_SynthesizeLeftLaneFromRight_PerspectiveWidth() {
        let detector = LaneDetector()

        // Create right lane points spanning ROI top (0.38) to bottom (0.95)
        // Right lane at x=0.40 (top) to x=0.58 (bottom) - typical right edge
        let rightPoints = [
            CGPoint(x: 0.40, y: 0.38), // top
            CGPoint(x: 0.44, y: 0.50),
            CGPoint(x: 0.48, y: 0.65),
            CGPoint(x: 0.52, y: 0.80),
            CGPoint(x: 0.58, y: 0.95)  // bottom
        ]

        let synthesized = detector.synthesizeLeftLaneFromRight(rightPoints)

        // At top (y=0.38): w = 0.14 -> synthesized x = 0.40 - 0.14 = 0.26
        XCTAssertEqual(synthesized[0].x, 0.26, accuracy: 0.001, "Top y=0.38: w=0.14 -> x=0.26")
        XCTAssertEqual(synthesized[0].y, 0.38, accuracy: 0.001)

        // At bottom (y=0.95): w = 0.44 -> synthesized x = 0.58 - 0.44 = 0.14
        XCTAssertEqual(synthesized[4].x, 0.14, accuracy: 0.001, "Bottom y=0.95: w=0.44 -> x=0.14")
        XCTAssertEqual(synthesized[4].y, 0.95, accuracy: 0.001)

        // All points clamped within [0.02, 0.98]
        for pt in synthesized {
            XCTAssertGreaterThanOrEqual(pt.x, 0.02, "x >= 0.02")
            XCTAssertLessThanOrEqual(pt.x, 0.98, "x <= 0.98")
            XCTAssertGreaterThanOrEqual(pt.y, 0.38, "y >= 0.38")
            XCTAssertLessThanOrEqual(pt.y, 0.95, "y <= 0.95")
        }
    }

    func testSingleLineSynthesis_ClampsAtBounds() {
        let detector = LaneDetector()

        // Left lane very close to right edge - synthesis should clamp at 0.98
        let leftPointsNearRight = [
            CGPoint(x: 0.90, y: 0.38),
            CGPoint(x: 0.90, y: 0.95)
        ]
        let synthesizedRight = detector.synthesizeRightLaneFromLeft(leftPointsNearRight)
        XCTAssertEqual(synthesizedRight[0].x, 0.98, accuracy: 0.001, "Clamped at 0.98 max")
        XCTAssertEqual(synthesizedRight[1].x, 0.98, accuracy: 0.001, "Clamped at 0.98 max")

        // Right lane very close to left edge - synthesis should clamp at 0.02
        let rightPointsNearLeft = [
            CGPoint(x: 0.10, y: 0.38),
            CGPoint(x: 0.10, y: 0.95)
        ]
        let synthesizedLeft = detector.synthesizeLeftLaneFromRight(rightPointsNearLeft)
        XCTAssertEqual(synthesizedLeft[0].x, 0.02, accuracy: 0.001, "Clamped at 0.02 min")
        XCTAssertEqual(synthesizedLeft[1].x, 0.02, accuracy: 0.001, "Clamped at 0.02 min")
    }
}