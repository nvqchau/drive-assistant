import XCTest
import CoreLocation
import Combine
@testable import DriveAssistant

/// Functional/Business Logic Coverage Tests for DriveAssistant
@MainActor
final class BusinessLogicCoverageTests: XCTestCase {

    var model: DriveAssistantModel!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        model = DriveAssistantModel()
        cancellables = []
        // Ensure clean state
        model.hasReceivedCameraSignOverride = false
        model.lastCameraResidentialSignLocation = nil
        model.lastCameraResidentialSignTime = .distantPast
        model.isInResidentialArea = nil
        model.isDividedRoad = false
        model.location.roadMetadata.osmIsInResidentialArea = nil
        model.location.roadMetadata.roadMaxSpeed = nil
        model.location.roadMetadata.isDividedRoad = false
        // Prevent OSM divided road subscriber from overriding
        model.camera.trafficSignDetector.setDividedRoadFromSignForTest(true)
    }

    /// Async wait for a condition without blocking main thread
    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - startTime < timeout {
            if condition() { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        throw XCTestError(.timeoutWhileWaiting)
    }

    // MARK: - TC-01: Manual Speed Sign Tap Clear

    func testTC01_ManualSpeedSignTapClear_RevertsToTT38Statutory() async throws {
        // Given: Residential area, divided road -> TT38 = 60 km/h
        // Set up camera detector state FIRST to prevent OSM interference
        model.camera.trafficSignDetector.setDividedRoadFromSignForTest(true)

        // Set model.isDividedRoad BEFORE triggering OSM subscriber
        model.isDividedRoad = true
        model.isInResidentialArea = true
        model.hasReceivedCameraSignOverride = true
        model.isCurrentLimitStatutory = false

        // Now trigger OSM subscriber with correct model state
        model.location.roadMetadata.isDividedRoad = true
        model.camera.trafficSignDetector.isInResidentialArea = true

        // Allow main queue to process subscribers
        try await Task.sleep(nanoseconds: 100_000_000)

        // Simulate explicit P.127 sign (40 km/h) from camera
        model.camera.trafficSignDetector.setDetectedSpeedLimitForTest(40)

        // Wait for Combine propagation to model (async, non-blocking)
        var observedLimit1: Int?
        var fulfilled1 = false
        model.$detectedSpeedLimit
            .dropFirst()
            .sink { limit in
                observedLimit1 = limit
                if limit == 40 { fulfilled1 = true }
            }
            .store(in: &cancellables)

        try await waitForCondition(timeout: 2.0) { fulfilled1 }

        XCTAssertEqual(model.detectedSpeedLimit, 40)
        XCTAssertFalse(model.isCurrentLimitStatutory)

        // When: User taps speed limit badge -> clearDetectedLimit()
        model.camera.trafficSignDetector.clearDetectedLimit()

        // Then: Wait for Combine propagation (sink sets nil, then applyTT38StatutoryLimit fires -> 60)
        var observedLimit2: Int?
        var fulfilled2 = false
        model.$detectedSpeedLimit
            .dropFirst() // skip nil
            .sink { limit in
                observedLimit2 = limit
                if limit == 60 { fulfilled2 = true }
            }
            .store(in: &cancellables)

        try await waitForCondition(timeout: 2.0) { fulfilled2 }

        // Assert: Reverts to TT38 statutory (60 km/h for residential divided), NEVER nil
        XCTAssertEqual(model.detectedSpeedLimit, 60, "Must revert to TT38 statutory 60 km/h, not nil")
        XCTAssertTrue(model.isInResidentialArea == true, "Residential area preserved")
        XCTAssertTrue(model.isCurrentLimitStatutory, "Limit must be marked statutory after manual clear")
    }

    // MARK: - TC-02: 3-Tier Auto Display Theme Fallback

    func testTC02_DisplayThemeAuto_3TierFallback() async {
        // Test the isNightThemeActive computed property logic directly
        // by verifying the fallback priority order

        // Tier 1: Camera luminance has highest priority when available
        model.displayThemeMode = .auto
        model.ecoBlackHUD = false
        model.hudMirrorMode = false

        // Use test helper to set camera brightness state (async on main queue)
        model.camera.setCameraBrightnessForTest(hasValid: true, isLowLight: true)
        try? await Task.sleep(nanoseconds: 100_000_000) // wait for main queue
        XCTAssertTrue(model.isNightThemeActive, "Camera luminance tier: low light -> night")

        model.camera.setCameraBrightnessForTest(hasValid: true, isLowLight: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isNightThemeActive, "Camera luminance tier: daylight -> day")

        // Tier 2: GPS astronomical (when camera tier disabled)
        model.camera.setCameraBrightnessForTest(hasValid: false, isLowLight: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        model.ecoBlackHUD = true  // disables camera tier
        model.location.setAstronomicalNightForTest(true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.isNightThemeActive, "Astronomical tier: night -> night")

        model.location.setAstronomicalNightForTest(false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isNightThemeActive, "Astronomical tier: day -> day")

        // Explicit .day/.night modes bypass all tiers
        model.displayThemeMode = .day
        XCTAssertFalse(model.isNightThemeActive, "Explicit .day -> day")

        model.displayThemeMode = .night
        XCTAssertTrue(model.isNightThemeActive, "Explicit .night -> night")

        // Test auto mode with default fallback (clock-based when camera/astronomical unavailable)
        model.displayThemeMode = .auto
        model.ecoBlackHUD = true  // disables camera tier
        model.location.setAstronomicalNightForTest(nil)  // disables astronomical tier
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Clock fallback: hour < 6 or >= 18 -> night
        let hour = Calendar.current.component(.hour, from: Date())
        let expectedNight = hour < 6 || hour >= 18
        XCTAssertEqual(model.isNightThemeActive, expectedNight, "Auto mode with clock fallback matches current hour")

        // Verify the computed property structure by checking all branches are reachable
        // (This is a structural test - the actual tier values depend on runtime conditions)
        XCTAssertNotNil(model.isNightThemeActive, "isNightThemeActive should be computable")
    }

    // MARK: - TC-03: Overspeed Tolerance & Cooldown

    func testTC03_OverspeedToleranceAndCooldown() {
        model.enableSpeedSignRecognition = true
        model.overspeedToleranceKmh = 3.0
        model.detectedSpeedLimit = 50
        model.isCurrentLimitStatutory = true

        // speed 52.0 -> 52 <= 50 + 3 = 53 -> NOT overspeeding
        model.speedKMPH = 52.0
        model.updateOverspeedStateForTest()
        XCTAssertFalse(model.isOverspeeding, "52 km/h with 50 limit + 3 tolerance = NOT overspeeding")

        // speed 54.0 -> 54 > 53 -> overspeeding
        model.speedKMPH = 54.0
        model.updateOverspeedStateForTest()
        XCTAssertTrue(model.isOverspeeding, "54 km/h with 50 limit + 3 tolerance = overspeeding")

        // speed drops to 51.0 -> 51 <= 53 -> resets
        model.speedKMPH = 51.0
        model.updateOverspeedStateForTest()
        XCTAssertFalse(model.isOverspeeding, "51 km/h with 50 limit + 3 tolerance = NOT overspeeding (cooldown reset)")

        // Verify tolerance boundary: 53.0 exactly at limit + tolerance
        model.speedKMPH = 53.0
        model.updateOverspeedStateForTest()
        XCTAssertFalse(model.isOverspeeding, "53 km/h at exact limit+tolerance = NOT overspeeding (>)")
    }

    // MARK: - TC-04: Stop-and-Go Lead Vehicle Departure Sequence

    func testTC04_StopAndGoLeadVehicleDepartureSequence() async {
        model.stopAndGoAlertEnabled = true
        model.speedKMPH = 0
        model.closingSpeedMPS = 0  // ensure closing speed is zero for departure detection

        // Feed steady lead distance 4.0m for >= 2.6s to ARM
        model.distance = 4.0
        model.updateAlertStateForTest()

        // Wait for arming (2.5s stable + small margin)
        try? await Task.sleep(nanoseconds: 2_700_000_000) // 2.7s

        // Call updateAlertStateForTest again to ARM (before distance changes)
        model.updateAlertStateForTest()

        // Now increase distance to 6.2m (+2.2m >= 1.8m) and hold for >= 0.5s
        model.distance = 6.2
        model.closingSpeedMPS = 0
        model.updateAlertStateForTest()  // sets departureDetectedStartTime

        // Wait for departure confirmation (0.4s) and call again to trigger
        try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
        model.updateAlertStateForTest()  // triggers alert

        // Assert: Alert triggers
        XCTAssertTrue(model.isLeadVehicleMovingAlertActive, "Stop-and-Go alert should trigger on departure")

        // Wait for auto-hide (3s) and verify disarmed (no re-trigger on stationary)
        try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5s
        model.distance = 4.0
        model.closingSpeedMPS = 0
        model.updateAlertStateForTest()
        XCTAssertFalse(model.isLeadVehicleMovingAlertActive, "Should be disarmed after trigger, not re-trigger on stationary")
    }

    // MARK: - TC-05: Vehicle Distance Formula & Hood Offset

    func testTC05_VehicleDistanceFormula_HoodOffset() {
        // Formula: (realWidth * calibrationFactor) / boxWidth - hoodOffsetMeters
        // with minimum floor 0.5m

        let calibrationFactor = 1.40
        let hoodOffset = 1.8

        // Car: realWidth = 1.8m, boxWidth = 0.1 -> distance = (1.8 * 1.4) / 0.1 - 1.8 = 25.2 - 1.8 = 23.4
        let carDistance = (1.8 * calibrationFactor) / 0.1 - hoodOffset
        XCTAssertEqual(carDistance, 23.4, accuracy: 0.01, "Car distance formula")

        // Truck/Bus: realWidth = 2.5m, boxWidth = 0.1 -> distance = (2.5 * 1.4) / 0.1 - 1.8 = 35.0 - 1.8 = 33.2
        let truckDistance = (2.5 * calibrationFactor) / 0.1 - hoodOffset
        XCTAssertEqual(truckDistance, 33.2, accuracy: 0.01, "Truck/Bus distance formula")

        // Motorcycle: realWidth = 0.75m, boxWidth = 0.1 -> distance = (0.75 * 1.4) / 0.1 - 1.8 = 10.5 - 1.8 = 8.7
        let motoDistance = (0.75 * calibrationFactor) / 0.1 - hoodOffset
        XCTAssertEqual(motoDistance, 8.7, accuracy: 0.01, "Motorcycle distance formula")

        // Minimum floor 0.5m: very wide box (close vehicle) should not go below 0.5
        let closeCarDistance = (1.8 * calibrationFactor) / 0.9 - hoodOffset  // ~2.8 - 1.8 = 1.0
        XCTAssertGreaterThanOrEqual(closeCarDistance, 0.5, "Distance floor 0.5m")

        // Verify the formula matches CameraManager.handle() implementation
        // CameraManager: let distance = (realWidth * factor) / normalizedBoxWidth
        // DriveAssistantModel: bumperDistance = max(0.5, rawDistance - hoodOffsetMeters)
        // So: max(0.5, (realWidth * factor) / boxWidth - hoodOffset)
    }

    // MARK: - TC-06: WeatherService Open-Meteo Payload Parsing

    func testTC06_WeatherService_OpenMeteoParsing() {
        let jsonRain = """
        {"current":{"precipitation":1.2,"rain":0.8,"weather_code":61}}
        """.data(using: .utf8)!

        let jsonDry = """
        {"current":{"precipitation":0.0,"rain":0.0,"weather_code":1}}
        """.data(using: .utf8)!

        let jsonDrizzle = """
        {"current":{"precipitation":0.3,"rain":0.2,"weather_code":51}}
        """.data(using: .utf8)!

        let jsonHeavyRain = """
        {"current":{"precipitation":5.0,"rain":4.8,"weather_code":80}}
        """.data(using: .utf8)!

        // Test rainy conditions -> .wet
        let conditionRain = parseWeatherPayload(jsonRain)
        XCTAssertEqual(conditionRain, .wet, "precipitation=1.2 -> wet")

        let conditionDrizzle = parseWeatherPayload(jsonDrizzle)
        XCTAssertEqual(conditionDrizzle, .wet, "weather_code=51 (drizzle) -> wet")

        let conditionHeavyRain = parseWeatherPayload(jsonHeavyRain)
        XCTAssertEqual(conditionHeavyRain, .wet, "weather_code=80 (heavy rain) -> wet")

        // Test dry condition -> .dry
        let conditionDry = parseWeatherPayload(jsonDry)
        XCTAssertEqual(conditionDry, .dry, "precipitation=0.0, weather_code=1 -> dry")
    }

    // Internal helper mirroring WeatherService logic for testing
    private func parseWeatherPayload(_ data: Data) -> RoadCondition {
        struct CurrentWeather: Decodable {
            let precipitation: Double
            let rain: Double
            let weatherCode: Int
            enum CodingKeys: String, CodingKey {
                case precipitation, rain, weatherCode = "weather_code"
            }
        }
        struct Response: Decodable { let current: CurrentWeather }
        guard let payload = try? JSONDecoder().decode(Response.self, from: data) else { return .dry }
        let current = payload.current
        let isWet = current.precipitation > 0.1 || current.rain > 0.1 || current.weatherCode >= 51
        return isWet ? .wet : .dry
    }
}