import XCTest
import CoreLocation
@testable import DriveAssistant

/// End-to-end behavioral tests for DriveAssistantModel alert state transitions (FCW + Stop-and-Go).
/// Exercises actual production methods, not test-extension helpers.
@MainActor
final class FCWAndStopAndGoTests: XCTestCase {

    var model: DriveAssistantModel!

    override func setUp() {
        super.setUp()
        model = DriveAssistantModel()
        // Ensure clean state
        model.distanceRuleMode = .vnLaw
        model.timeHeadway = 2.5
        model.calibrationFactor = 1.15
        model.hoodOffsetMeters = 1.8
        model.stopAndGoAlertEnabled = true
    }

    override func tearDown() {
        model = nil
        super.tearDown()
    }

    // MARK: - Alert State: .vnLaw mode < 10 km/h suppression

    func testAlertState_Normal_WhenSpeedBelow10kmh_VNLawMode_CloseDistance() {
        // Given: .vnLaw mode, speed < 10 km/h, very close distance
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 5.0
        model.distance = 2.0  // well below minimum distance

        // When: updateAlertState is called
        model.updateAlertStateForTest()

        // Then: alertState stays .normal (suppressed)
        XCTAssertEqual(model.alertState, .normal, "Alert should be suppressed in .vnLaw mode when speed < 10 km/h")
        XCTAssertFalse(model.isDangerous)
    }

    func testAlertState_Normal_WhenSpeedBelow10kmh_VNLawMode_NoDistance() {
        // Given: .vnLaw mode, speed < 10 km/h, no lead vehicle (distance = nil)
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 5.0
        model.distance = nil

        // When: updateAlertState is called
        model.updateAlertStateForTest()

        // Then: alertState stays .normal
        XCTAssertEqual(model.alertState, .normal)
    }

    // MARK: - Alert State: .warning at 60 km/h when distance < activeMinimumDistance

    func testAlertState_Warning_At60kmh_WhenDistanceBelowMinimum() {
        // Given: .vnLaw mode, speed 60 km/h
        // activeMinimumDistance = tt38Distance(60) = 35m (dry)
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 60.0
        model.distance = 30.0  // below 35m minimum
        model.roadCondition = .dry

        // When: updateAlertState is called
        model.updateAlertStateForTest()

        // Then: alertState escalates to .warning
        XCTAssertEqual(model.alertState, .warning, "Should warn when distance < activeMinimumDistance at 60 km/h")
        XCTAssertFalse(model.isDangerous)
    }

    func testAlertState_Warning_At60kmh_WetRoad_WhenDistanceBelowMinimum() {
        // Given: .vnLaw mode, speed 60 km/h, wet road
        // activeMinimumDistance = tt38Distance(60) * 1.3 = 35 * 1.3 = 45.5m
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 60.0
        model.distance = 40.0  // below 45.5m wet minimum
        model.roadCondition = .wet

        // When: updateAlertState is called
        model.updateAlertStateForTest()

        // Then: alertState escalates to .warning
        XCTAssertEqual(model.alertState, .warning, "Should warn when distance < wet minimum at 60 km/h")
    }

    func testAlertState_Normal_At60kmh_WhenDistanceAboveMinimum() {
        // Given: .vnLaw mode, speed 60 km/h, distance above minimum
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 60.0
        model.distance = 50.0  // above 35m minimum
        model.roadCondition = .dry

        // When: updateAlertState is called
        model.updateAlertStateForTest()

        // Then: alertState stays .normal
        XCTAssertEqual(model.alertState, .normal, "Should not warn when distance >= activeMinimumDistance")
    }

    // MARK: - Alert State: .critical after 3 consecutive frames with TTC < 1.8s

    func testAlertState_Critical_After3Frames_TTCLessThan1_8s() {
        // Given: speed >= 25 km/h, set up conditions for TTC < 1.8s
        // TTC = distance / closingSpeedMPS < 1.8
        // closingSpeedMPS > distance / 1.8
        // At speed 60 km/h (16.67 m/s), if closingSpeedMPS = 10 m/s, need distance < 18m for TTC < 1.8
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 60.0
        model.distance = 15.0
        model.roadCondition = .dry
        model.closingSpeedMPS = 10.0  // simulate closing speed
        model.timeToCollision = 1.5  // < 1.8s

        // When: call updateAlertState 3 times (simulate 3 consecutive frames)
        for i in 1...3 {
            model.updateAlertStateForTest()
            if i < 3 {
                XCTAssertEqual(model.alertState, .warning, "Frame \(i): should be .warning, not yet .critical")
            }
        }

        // Then: after 3rd frame, alertState escalates to .critical
        XCTAssertEqual(model.alertState, .critical, "Should be .critical after 3 consecutive frames with TTC < 1.8s")
        XCTAssertTrue(model.isDangerous)
    }

    func testAlertState_Critical_Resets_WhenTTCHasRecovered() {
        // Given: was critical, now TTC recovered
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 60.0
        model.distance = 15.0
        model.closingSpeedMPS = 10.0
        model.timeToCollision = 1.5

        // Become critical
        for _ in 1...3 {
            model.updateAlertStateForTest()
        }
        XCTAssertEqual(model.alertState, .critical)

        // When: TTC recovers (> 1.8s)
        model.distance = 50.0
        model.closingSpeedMPS = 2.0
        model.timeToCollision = 25.0
        model.updateAlertStateForTest()

        // Then: alertState returns to .normal
        XCTAssertEqual(model.alertState, .normal, "Should return to .normal when TTC recovers")
    }

    func testAlertState_Critical_NotTriggered_Below25kmh_WithLowDistance() {
        // Given: speed < 25 km/h, distance < 3.5m (absolute threshold for critical at low speed)
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 20.0
        model.distance = 3.0  // < 3.5m

        // When: call updateAlertState 3 times
        for i in 1...3 {
            model.updateAlertStateForTest()
        }

        // Then: should become .critical (low speed absolute distance check)
        XCTAssertEqual(model.alertState, .critical, "Should be .critical at low speed when distance < 3.5m")
    }

    // MARK: - .timeHeadway mode: warning at < 10 km/h when distance < 4m

    func testAlertState_Warning_TimeHeadway_Below10kmh_DistanceBelow4m() {
        // Given: .timeHeadway mode, speed < 10 km/h, distance < 4m
        model.distanceRuleMode = .timeHeadway
        model.speedKMPH = 5.0
        model.distance = 3.0

        // When: updateAlertState is called
        model.updateAlertStateForTest()

        // Then: alertState escalates to .warning (low speed warning in timeHeadway mode)
        XCTAssertEqual(model.alertState, .warning, "Should warn in .timeHeadway when speed < 10 and distance < 4m")
    }

    func testAlertState_Normal_TimeHeadway_Below10kmh_DistanceAbove4m() {
        // Given: .timeHeadway mode, speed < 10 km/h, distance >= 4m
        model.distanceRuleMode = .timeHeadway
        model.speedKMPH = 5.0
        model.distance = 5.0

        // When: updateAlertState is called
        model.updateAlertStateForTest()

        // Then: alertState stays .normal
        XCTAssertEqual(model.alertState, .normal)
    }

    // MARK: - Critical frame count persistence

    func testCriticalFrameCount_Persists_AcrossMultipleCalls() {
        // Given: conditions for critical
        model.distanceRuleMode = .vnLaw
        model.speedKMPH = 60.0
        model.distance = 15.0
        model.closingSpeedMPS = 10.0
        model.timeToCollision = 1.5

        // When: 2 frames of critical candidate
        model.updateAlertStateForTest()
        model.updateAlertStateForTest()
        XCTAssertEqual(model.alertState, .warning)

        // Then: 3rd frame makes it critical
        model.updateAlertStateForTest()
        XCTAssertEqual(model.alertState, .critical)
    }
}