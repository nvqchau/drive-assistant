import AVFoundation
import SwiftUI
import Combine
import CoreLocation
import CoreMotion
import Foundation
import UIKit

enum ADASAlertState: Equatable {
    case normal
    case warning
    case critical
}

enum DistanceRuleMode: String, CaseIterable {
    case vnLaw = "vnLaw"
    case timeHeadway = "timeHeadway"
}

enum RoadCondition: String, CaseIterable {
    case auto = "auto"
    case dry = "dry"
    case wet = "wet"
}

enum DisplayThemeMode: String, CaseIterable {
    case auto = "auto"
    case day = "day"
    case night = "night"
}

@MainActor
final class DriveAssistantModel: ObservableObject {
    @Published var distance: Double?
    @Published var speedKMPH: Double = 0
    @Published private(set) var gpsAccuracy: CLLocationAccuracy = .infinity
    @Published var isDangerous = false
    @Published var alertState: ADASAlertState = .normal
    @Published var closingSpeedMPS: Double = 0
    @Published var timeToCollision: Double?
    @Published var isSettingsPresented = false
    @Published var ecoBlackHUD: Bool {
        didSet { UserDefaults.standard.set(ecoBlackHUD, forKey: "ecoBlackHUD") }
    }
    @Published var glassHUD: Bool {
        didSet { UserDefaults.standard.set(glassHUD, forKey: "glassHUD") }
    }
    @Published var voiceAlertsEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceAlertsEnabled, forKey: "voiceAlertsEnabled") }
    }
    @Published var usesVietnamese = true
    @Published var distanceRuleMode: DistanceRuleMode {
        didSet { UserDefaults.standard.set(distanceRuleMode.rawValue, forKey: "distanceRuleMode") }
    }
    @Published var roadCondition: RoadCondition {
        didSet { UserDefaults.standard.set(roadCondition.rawValue, forKey: "roadCondition") }
    }
    @Published private(set) var detectedRoadCondition: RoadCondition = .dry
    @Published var timeHeadway: Double = 2.5
    @Published var calibrationFactor: Double = 1.15 {
        didSet { UserDefaults.standard.set(calibrationFactor, forKey: "calibrationFactor") }
    }
    @Published var showOutOfROIVehicles: Bool = true {
        didSet { UserDefaults.standard.set(showOutOfROIVehicles, forKey: "showOutOfROIVehicles") }
    }
    @Published var hoodOffsetMeters: Double = 1.8 {
        didSet { UserDefaults.standard.set(hoodOffsetMeters, forKey: "hoodOffsetMeters") }
    }
    @Published var laneCenterOffsetX: Double = 0.02 {
        didSet { 
            UserDefaults.standard.set(laneCenterOffsetX, forKey: "laneCenterOffsetX")
            camera.setLaneCenterOffsetX(laneCenterOffsetX)
            laneDetector.setROIOffset(laneCenterOffsetX)
        }
    }
    @Published var showHorizonGuide: Bool = true {
        didSet { UserDefaults.standard.set(showHorizonGuide, forKey: "showHorizonGuide") }
    }
    @Published var enableLaneDetection: Bool = true {
        didSet { UserDefaults.standard.set(enableLaneDetection, forKey: "enableLaneDetection") }
    }
    @Published var ldwsMinSpeedKmh: Double = 50.0 {
        didSet {
            UserDefaults.standard.set(ldwsMinSpeedKmh, forKey: "ldwsMinSpeedKmh")
            laneDetector.setMinSpeedForDepartureAlert(ldwsMinSpeedKmh)
        }
    }
    @Published var stopAndGoAlertEnabled: Bool = true {
        didSet { UserDefaults.standard.set(stopAndGoAlertEnabled, forKey: "stopAndGoAlertEnabled") }
    }
    @Published var autoDebugScreenshotEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoDebugScreenshotEnabled, forKey: "autoDebugScreenshotEnabled") }
    }
    // Track last advisory alert key for cooldown
    private var lastAdvisoryAlertKey: String? = nil
    private var lastAdvisoryAlertTime: TimeInterval = 0

    // Traffic Sign Recognition (TSR)
    @Published var enableSpeedSignRecognition: Bool = true {
        didSet {
            UserDefaults.standard.set(enableSpeedSignRecognition, forKey: "enableSpeedSignRecognition")
            camera.enableSpeedSignRecognition = enableSpeedSignRecognition
        }
    }
    @Published var overspeedToleranceKmh: Double = 3.0 {
        didSet { UserDefaults.standard.set(overspeedToleranceKmh, forKey: "overspeedToleranceKmh") }
    }
    @Published var detectedSpeedLimit: Int?
    @Published private(set) var isOverspeeding: Bool = false
    @Published private(set) var showSpeedLimitCleared: Bool = false
    @Published private(set) var showEndOfAllRestrictions: Bool = false  // DP.135 indicator
    @Published private(set) var activeAdvisorySignText: String?  // e.g., "Cấm vượt", "Cấm ô tô", "Khu dân cư"
    @Published private(set) var debugCaptureTrigger: Date? = nil  // triggers silent auto-screenshot

    // Vietnam TT38 statutory speed limits based on residential area + divided road
    @Published var enableDefaultOutsideResidentialLimit: Bool = true {
        didSet { UserDefaults.standard.set(enableDefaultOutsideResidentialLimit, forKey: "enableDefaultOutsideResidentialLimit") }
    }
    @Published var isInResidentialArea: Bool? = nil  // nil=unknown, true=inside, false=outside
    @Published var isDividedRoad: Bool = false  // from OSM or dual carriageway sign
    var isCurrentLimitStatutory = false  // true if detectedSpeedLimit came from TT38, false if from P.127 sign
    var lastCameraResidentialSignTime: Date = .distantPast  // for 5-min camera precedence over OSM
    var lastCameraResidentialSignLocation: CLLocation? = nil  // for 2km camera precedence over OSM
    var hasReceivedCameraSignOverride = false  // true after any camera sign confirmed or manual clear

    /// Computed current speed limit (TT38 statutory or camera-detected)
    var currentSpeedLimit: Int? { detectedSpeedLimit }

    // Display Theme & Mirror Mode
    @Published var displayThemeMode: DisplayThemeMode = .auto {
        didSet { UserDefaults.standard.set(displayThemeMode.rawValue, forKey: "displayThemeMode") }
    }
    var isNightThemeActive: Bool {
        if displayThemeMode == .night { return true }
        if displayThemeMode == .day { return false }
        // auto: 3-tier fallback
        // 1) Camera luminance (handles tunnels, heavy rain, real twilight)
        if !ecoBlackHUD && !hudMirrorMode && camera.hasValidCameraBrightness {
            return camera.isLowLightScene
        }
        // 2) GPS astronomical sunrise/sunset
        if let astroNight = location.isAstronomicalNight {
            return astroNight
        }
        // 3) Clock fallback
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 6 || hour >= 18
    }
    @Published var hudMirrorMode: Bool = false {
        didSet {
            UserDefaults.standard.set(hudMirrorMode, forKey: "hudMirrorMode")
            if hudMirrorMode {
                savedBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 1.0
            } else {
                UIScreen.main.brightness = savedBrightness
            }
        }
    }
    private var savedBrightness: CGFloat = 1.0

    let camera = CameraManager()
    let motion = MotionManager()
    let laneDetector = LaneDetector()
    let diagnostics = DiagnosticsLogStore()
    let location = LocationManager()
    private let alerts = AlertManager()
    private var cancellables = Set<AnyCancellable>()
    private var smoothedDistance: Double?
    private let distanceEMAAlpha = 0.3
    private var distanceHistory: [(timestamp: TimeInterval, distance: Double)] = []
    private let closingSpeedWindow: TimeInterval = 0.5
    private var criticalFrameCount = 0
    private var lastSpeedKMPH: Double = 0
    private var lastSpeedUpdateTime: TimeInterval = 0
    private let maxAccelerationMPS2: Double = 6.0
    private let maxClosingSpeedMPS: Double = 25.0
    
    // For dynamic horizon calibration
    var lastTrackedBox: CGRect?
    var previousLeadBoxForSwitch: CGRect?  // separate tracker for target-switch detection
    var lastTrackedConfidence: Float = 0
    var horizonCalibrationFrames = 0

    // Stop-and-Go (Lead Vehicle Departure) state machine
    @Published var isLeadVehicleMovingAlertActive: Bool = false
    private var stopAndGoArmed = false
    private var stoppedLeadDistance: Double = 0
    private var leadVehicleStableStartTime: TimeInterval?
    private var leadVehicleGoneStartTime: TimeInterval?
    private var departureDetectedStartTime: TimeInterval?
    private var lastStopAndGoAlertTime: TimeInterval = 0
    private let stopAndGoAlertCooldown: TimeInterval = 8.0  // prevent re-trigger within same stop

    var safeDistance: Double { max(5, speedKMPH / 3.6 * timeHeadway) }

    /// TT38 statutory distance for a given speed (km/h), with wet multiplier.
    /// Per TT38/2023/TT-BGTVT: 80 km/h -> 55m (60.01...80.0), 80.01...100 -> 70m
    private func tt38Distance(forSpeed speed: Double) -> Double {
        let base: Double
        switch speed {
        case ..<10: base = 5.0
        case 10..<58: base = max(5, speed * 0.5)
        case 58...60: base = 35
        case 60.01...80.0: base = 55
        case 80.01...100.0: base = 70
        default: base = 100
        }
        return (distanceRuleMode == .vnLaw && effectiveRoadCondition == .wet) ? base * 1.3 : base
    }

    var baseSafeDistance: Double {
        switch distanceRuleMode {
        case .timeHeadway:
            return max(5, speedKMPH / 3.6 * timeHeadway)
        case .vnLaw:
            return tt38Distance(forSpeed: speedKMPH)
        }
    }

    /// Used for collision alert gating & progress bar (0 when < 10 km/h in .vnLaw mode).
    var activeMinimumDistance: Double {
        baseSafeDistance
    }

    /// Used for HUD display: when stopped/crawling (< 10 km/h) in .vnLaw mode,
    /// show the statutory distance for the active speed limit (or 5m floor).
    var displayMinimumDistance: Double {
        if distanceRuleMode == .vnLaw && speedKMPH < 10 {
            if let limit = detectedSpeedLimit {
                return tt38Distance(forSpeed: Double(limit))
            }
            return 5.0
        }
        return activeMinimumDistance
    }

    var effectiveRoadCondition: RoadCondition {
        roadCondition == .auto ? detectedRoadCondition : roadCondition
    }

    init() {
        let defaults = UserDefaults.standard
        ecoBlackHUD = defaults.bool(forKey: "ecoBlackHUD")
        glassHUD = defaults.object(forKey: "glassHUD") as? Bool ?? true
        voiceAlertsEnabled = defaults.object(forKey: "voiceAlertsEnabled") as? Bool ?? false
        distanceRuleMode = DistanceRuleMode(rawValue: defaults.string(forKey: "distanceRuleMode") ?? "") ?? .vnLaw
        roadCondition = RoadCondition(rawValue: defaults.string(forKey: "roadCondition") ?? "") ?? .dry
        calibrationFactor = defaults.object(forKey: "calibrationFactor") as? Double ?? 1.15
        showOutOfROIVehicles = defaults.object(forKey: "showOutOfROIVehicles") as? Bool ?? true
        hoodOffsetMeters = defaults.object(forKey: "hoodOffsetMeters") as? Double ?? 1.8
        laneCenterOffsetX = defaults.object(forKey: "laneCenterOffsetX") as? Double ?? 0.02
        showHorizonGuide = defaults.object(forKey: "showHorizonGuide") as? Bool ?? true
        enableLaneDetection = defaults.object(forKey: "enableLaneDetection") as? Bool ?? true
        ldwsMinSpeedKmh = defaults.object(forKey: "ldwsMinSpeedKmh") as? Double ?? 50.0
        stopAndGoAlertEnabled = defaults.object(forKey: "stopAndGoAlertEnabled") as? Bool ?? true
        // Traffic Sign Recognition (TSR)
        enableSpeedSignRecognition = defaults.object(forKey: "enableSpeedSignRecognition") as? Bool ?? true
        overspeedToleranceKmh = defaults.object(forKey: "overspeedToleranceKmh") as? Double ?? 3.0
        displayThemeMode = DisplayThemeMode(rawValue: defaults.string(forKey: "displayThemeMode") ?? "") ?? .auto
        hudMirrorMode = defaults.bool(forKey: "hudMirrorMode")
        autoDebugScreenshotEnabled = defaults.object(forKey: "autoDebugScreenshotEnabled") as? Bool ?? true
        enableDefaultOutsideResidentialLimit = defaults.object(forKey: "enableDefaultOutsideResidentialLimit") as? Bool ?? true
        if hudMirrorMode {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
        }

        camera.attachDiagnostics(diagnostics)
        camera.setCalibrationFactor(calibrationFactor)
        camera.setLaneCenterOffsetX(laneCenterOffsetX)
        camera.laneDetector = laneDetector
        camera.enableSpeedSignRecognition = enableSpeedSignRecognition
        laneDetector.setROIOffset(laneCenterOffsetX)
        laneDetector.setMinSpeedForDepartureAlert(ldwsMinSpeedKmh)
        laneDetector.attachDiagnostics(diagnostics)
        location.roadMetadata.attachDiagnostics(diagnostics)

        // Forward camera, location & motion changes to trigger reactive theme & calibration updates
        camera.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        location.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        motion.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        location.$speedKMPH
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSpeed in
                self?.applySpeedRateLimit(newSpeed)
                self?.camera.currentSpeedKMPH = newSpeed
            }
            .store(in: &cancellables)

        location.$horizontalAccuracy.assign(to: &$gpsAccuracy)
        location.$weatherRoadCondition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] condition in
                self?.detectedRoadCondition = condition
                self?.updateAlertState()
            }
            .store(in: &cancellables)
        camera.$leadVehicleDistance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawDistance in
                guard let self else { return }
                if let rawDistance {
                    let bumperDistance = max(0.5, rawDistance - self.hoodOffsetMeters)
                    self.smoothedDistance = self.smoothedDistance.map {
                        self.distanceEMAAlpha * bumperDistance + (1 - self.distanceEMAAlpha) * $0
                    } ?? bumperDistance
                    self.distance = self.smoothedDistance
                    self.updateDistanceHistory(distance: self.smoothedDistance ?? bumperDistance)
                } else {
                    self.smoothedDistance = nil
                    self.distance = nil
                    self.distanceHistory.removeAll(keepingCapacity: true)
                    self.closingSpeedMPS = 0
                    self.timeToCollision = nil
                }
                self.updateAlertState()
            }.store(in: &cancellables)
        $calibrationFactor.dropFirst().sink { [weak self] factor in
            self?.camera.setCalibrationFactor(factor)
            self?.updateAlertState()
        }.store(in: &cancellables)
        $hoodOffsetMeters.dropFirst().sink { [weak self] _ in
            self?.updateAlertState()
        }.store(in: &cancellables)
        $laneCenterOffsetX.dropFirst().sink { [weak self] offset in
            self?.camera.setLaneCenterOffsetX(offset)
            self?.laneDetector.setROIOffset(offset)
            self?.updateAlertState()
        }.store(in: &cancellables)
        $showHorizonGuide.dropFirst().sink { [weak self] enabled in
            self?.camera.setHorizonFilterEnabled(enabled)
            if enabled {
                self?.motion.start()
            } else {
                self?.motion.stop()
            }
        }.store(in: &cancellables)
        $timeHeadway.dropFirst().sink { [weak self] _ in self?.updateAlertState() }.store(in: &cancellables)
        $distanceRuleMode.dropFirst().sink { [weak self] _ in self?.updateAlertState() }.store(in: &cancellables)
        $roadCondition.dropFirst().sink { [weak self] _ in self?.updateAlertState() }.store(in: &cancellables)
        $enableLaneDetection.dropFirst().sink { [weak self] enabled in
            self?.laneDetector.setLDWSEnabled(enabled)
            if !enabled {
                self?.laneDetector.stop()
            }
        }.store(in: &cancellables)
        $ldwsMinSpeedKmh.dropFirst().sink { [weak self] speed in
            self?.laneDetector.setMinSpeedForDepartureAlert(speed)
        }.store(in: &cancellables)
        // Sync effectiveHorizonY to CameraManager and trigger auto-calibration
        camera.$leadVehicleBox
            .combineLatest(camera.$leadVehicleConfidence, motion.$effectiveHorizonY)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] box, confidence, effectiveHorizonY in
                self?.camera.setEffectiveHorizonY(effectiveHorizonY)
                self?.attemptHorizonAutoCalibration(box: box, confidence: confidence)
            }
            .store(in: &cancellables)

        // Detect lead vehicle target switch (IoU < 0.15) — clear distance history to prevent fake closing speed
        camera.$leadVehicleBox
            .receive(on: DispatchQueue.main)
            .sink { [weak self] box in
                guard let self, let box = box else { return }
                if let lastBox = self.previousLeadBoxForSwitch {
                    let iou = self.intersectionOverUnion(lastBox, box)
                    if iou < 0.15 {
                        // Target switched (e.g., far car -> passing motorcycle) — reset history
                        self.distanceHistory.removeAll(keepingCapacity: true)
                        self.closingSpeedMPS = 0
                        self.timeToCollision = nil
                        self.diagnostics.record(type: "target_switched_iou", details: "iou=\(String(format: "%.2f", iou)) cleared_history")
                    }
                }
                self.previousLeadBoxForSwitch = box
            }
            .store(in: &cancellables)

        // Lane departure alerts
        laneDetector.$departureAlertActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                if active {
                    self?.alerts.playLaneDepartureAlert(speak: self?.voiceAlertsEnabled ?? false)
                }
            }
            .store(in: &cancellables)

        // Traffic Sign Recognition (TSR) - subscribe to camera's trafficSignDetector
        camera.trafficSignDetector.$detectedSpeedLimit
            .receive(on: DispatchQueue.main)
            .sink { [weak self] limit in
                self?.detectedSpeedLimit = limit
                // Explicit P.127 sign from camera overrides statutory — mark as non-statutory
                // But allow R.420 residential entry (limit=50) to stay statutory so divided road upgrades 50->60
                if limit != nil {
                    let inResidential = self?.camera.trafficSignDetector.isInResidentialArea ?? false
                    if !(inResidential && limit == 50) {
                        self?.isCurrentLimitStatutory = false
                    }
                    self?.hasReceivedCameraSignOverride = true  // any confirmed camera sign
                } else {
                    // Manual clear (tap on badge), DP.134, or DP.135 — ALWAYS revert to TT38 statutory limit
                    // Preserve isInResidentialArea (only R.421 or GPS/OSM leaving urban area clears it)
                    // Do NOT set hasReceivedCameraSignOverride = true — OSM roadMaxSpeed fallback must remain active
                    self?.isCurrentLimitStatutory = true
                    self?.applyTT38StatutoryLimit()
                }
                self?.updateOverspeedState()
            }
            .store(in: &cancellables)

        // Speed limit cleared event (DP.134 / DP.135) — revert to TT38 statutory limit
        camera.trafficSignDetector.$didClearSpeedLimitEvent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] eventDate in
                guard let self, eventDate != nil else { return }
                self.detectedSpeedLimit = nil
                self.isOverspeeding = false
                self.showSpeedLimitCleared = true
                self.hasReceivedCameraSignOverride = true  // manual clear counts as camera override
                self.isCurrentLimitStatutory = true  // revert to statutory
                self.applyTT38StatutoryLimit()  // apply TT38 fallback immediately
                self.alerts.playSpeedLimitClearedAlert(speak: self.voiceAlertsEnabled)

                // Auto-hide micro-badge after 2.5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.showSpeedLimitCleared = false
                }
            }
            .store(in: &cancellables)

        // DP.135 (End of All Restrictions) persistent indicator
        camera.trafficSignDetector.$detectedEndOfAllRestrictions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detected in
                self?.showEndOfAllRestrictions = detected
            }
            .store(in: &cancellables)

        // Secondary advisory sign (e.g., "Cấm vượt", "Khu dân cư") — trigger audio alert + diagnostics
        camera.trafficSignDetector.$activeAdvisorySignText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                self?.activeAdvisorySignText = key
                guard let self, let key else { return }
                // Per-key 8s cooldown (separate from AlertManager's internal cooldown)
                let now = CACurrentMediaTime()
                if self.lastAdvisoryAlertKey == key, now - self.lastAdvisoryAlertTime < 8.0 {
                    return
                }
                self.lastAdvisoryAlertKey = key
                self.lastAdvisoryAlertTime = now
                self.alerts.playTrafficSignAdvisoryAlert(key: key, speak: self.voiceAlertsEnabled)
                self.diagnostics.record(type: "tsr_advisory_alert", details: "key=\(key) speedKMPH=\(String(format: "%.1f", self.speedKMPH))")
            }
            .store(in: &cancellables)

        // TSR: Residential area state (R.420/R.421) — apply TT38 statutory limits
        camera.trafficSignDetector.$isInResidentialArea
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inResidential in
                self?.isInResidentialArea = inResidential
                // Record timestamp + location when camera sees explicit R.420/R.421 (non-nil)
                // for dual time (>300s) + distance (>2000m) precedence over OSM
                if inResidential != nil {
                    self?.lastCameraResidentialSignTime = Date()
                    self?.lastCameraResidentialSignLocation = self?.location.lastValidLocation
                    self?.isCurrentLimitStatutory = true
                }
                self?.applyTT38StatutoryLimit()
            }
            .store(in: &cancellables)

        // TSR: Dual carriageway sign (class "142") — override OSM divided road
        camera.trafficSignDetector.$isDividedRoadFromSign
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fromSign in
                if fromSign { self?.isDividedRoad = true }
            }
            .store(in: &cancellables)

        // OSM Road metadata: divided road + maxspeed fallback
        location.roadMetadata.$isDividedRoad
            .receive(on: DispatchQueue.main)
            .sink { [weak self] divided in
                // Only apply OSM if not overridden by camera sign
                if !(self?.camera.trafficSignDetector.isDividedRoadFromSign ?? false) {
                    self?.isDividedRoad = divided
                }
                self?.applyTT38StatutoryLimit()
            }
            .store(in: &cancellables)

        location.roadMetadata.$roadMaxSpeed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] maxSpeed in
                // Fallback only before any camera sign confirmed or manual clear
                if !(self?.hasReceivedCameraSignOverride ?? false), let maxSpeed, self?.detectedSpeedLimit == nil {
                    self?.detectedSpeedLimit = maxSpeed
                    self?.updateOverspeedState()
                }
            }
            .store(in: &cancellables)

        // OSM Residential area detection: auto-activate "Khu dân cư" badge + TT38 50/60 km/h
        // when no explicit R.420/R.421 camera sign has been seen recently
        // Dual precedence: BOTH >300s elapsed AND >2000m traveled since camera sign
        location.roadMetadata.$osmIsInResidentialArea
            .receive(on: DispatchQueue.main)
            .sink { [weak self] osmInResidential in
                guard let self else { return }
                // Only apply OSM if camera hasn't seen explicit R.420/R.421
                guard self.camera.trafficSignDetector.isInResidentialArea == nil else { return }
                let timeElapsed = Date().timeIntervalSince(self.lastCameraResidentialSignTime)
                let distanceTraveled: CLLocationDistance
                if let lastLoc = self.lastCameraResidentialSignLocation,
                   let currentLoc = self.location.lastValidLocation {
                    distanceTraveled = currentLoc.distance(from: lastLoc)
                } else {
                    distanceTraveled = .infinity
                }
                // OSM overrides only if BOTH conditions met
                if timeElapsed > 300 && distanceTraveled > 2000 {
                    if let osmInResidential {
                        self.isInResidentialArea = osmInResidential
                        self.applyTT38StatutoryLimit()
                    }
                }
            }
            .store(in: &cancellables)

        // Overspeed alert state - update when speed or tolerance changes
        $speedKMPH
            .combineLatest($overspeedToleranceKmh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateOverspeedState()
            }
            .store(in: &cancellables)

        // Auto-debug screenshot on suspected false detections + critical alerts (5s cooldown)
        var lastDebugCaptureTime: TimeInterval = 0
        diagnostics.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, self.autoDebugScreenshotEnabled else { return }
                let now = CACurrentMediaTime()
                guard now - lastDebugCaptureTime >= 5.0 else { return }
                if event.type == "oncoming_lane_suspect" || event.type == "oncoming_closing_speed_spike" || (event.type == "alert_state_changed" && (event.details?.contains("state=critical") ?? false)) {
                    lastDebugCaptureTime = now
                    self.debugCaptureTrigger = Date()
                }
            }
            .store(in: &cancellables)

        // Start motion manager if enabled
        if showHorizonGuide {
            motion.start()
        }

        // Initialize default TT38 speed limit on startup so badge shows 50 km/h immediately
        applyTT38StatutoryLimit()
    }

    private func applySpeedRateLimit(_ newSpeedKMPH: Double) {
        let now = CACurrentMediaTime()
        if lastSpeedUpdateTime > 0 {
            let dt = now - lastSpeedUpdateTime
            if dt > 0 {
                let maxDeltaKMPH = maxAccelerationMPS2 * dt * 3.6
                let delta = newSpeedKMPH - lastSpeedKMPH
                if abs(delta) > maxDeltaKMPH {
                    let clampedDelta = delta > 0 ? maxDeltaKMPH : -maxDeltaKMPH
                    speedKMPH = lastSpeedKMPH + clampedDelta
                    lastSpeedUpdateTime = now
                    lastSpeedKMPH = speedKMPH
                    return
                }
            }
        }
        speedKMPH = newSpeedKMPH
        lastSpeedKMPH = newSpeedKMPH
        lastSpeedUpdateTime = now
    }

    func start() {
        diagnostics.record(type: "session_started", orientation: String(describing: UIDevice.current.orientation))
        camera.start()
        location.start()
        if showHorizonGuide {
            motion.start()
        }
        if enableLaneDetection {
            laneDetector.start()
        }
    }

    func stop() {
        diagnostics.record(type: "session_stopped", speedKMPH: speedKMPH, distanceMeters: distance, isDangerous: isDangerous, orientation: String(describing: UIDevice.current.orientation))
        camera.stop()
        location.stop()
        motion.stop()
        laneDetector.stop()
        // Restore brightness on app stop if mirror mode was on
        if hudMirrorMode {
            UIScreen.main.brightness = savedBrightness
        }
    }

    func exportDiagnostics() -> URL {
        diagnostics.record(type: "manual_export", speedKMPH: speedKMPH, distanceMeters: distance, isDangerous: isDangerous, orientation: String(describing: UIDevice.current.orientation))
        return diagnostics.exportURL()
    }

    func clearDiagnostics() {
        diagnostics.clear()
        diagnostics.record(type: "logs_cleared", orientation: String(describing: UIDevice.current.orientation))
    }

    func cycleRoadCondition() {
        switch roadCondition {
        case .auto: roadCondition = .dry
        case .dry: roadCondition = .wet
        case .wet: roadCondition = .auto
        }
    }

    private func updateDistanceHistory(distance: Double) {
        let now = CACurrentMediaTime()
        distanceHistory.append((now, distance))
        let cutoff = now - closingSpeedWindow
        distanceHistory.removeAll { $0.timestamp < cutoff }

        guard let oldest = distanceHistory.first,
              now - oldest.timestamp > 0 else {
            closingSpeedMPS = 0
            timeToCollision = nil
            return
        }
        let elapsed = now - oldest.timestamp
        let closingSpeed = max(0, (oldest.distance - distance) / elapsed)
        closingSpeedMPS = min(closingSpeed, maxClosingSpeedMPS)
        timeToCollision = closingSpeedMPS > 0.5 ? distance / closingSpeedMPS : nil

        // Oncoming closing speed spike diagnostic: closing speed exceeds ego speed by >8 m/s
        // while speed >= 15 km/h (indicates likely oncoming traffic false positive)
        if speedKMPH >= 15 && closingSpeedMPS > (speedKMPH / 3.6) + 8.0 {
            diagnostics.record(type: "oncoming_closing_speed_spike",
                details: "speedKMPH=\(String(format: "%.1f", speedKMPH)), closingSpeedMPS=\(String(format: "%.1f", closingSpeedMPS)), distanceM=\(String(format: "%.1f", distance)), leadBox=\(camera.leadVehicleBox?.debugDescription ?? "nil")")
        }
    }

    /// Test helper: expose updateAlertState for unit tests
    func updateAlertStateForTest() {
        updateAlertState()
    }

    private func updateAlertState() {
        guard let distance else {
            criticalFrameCount = 0
            setAlertState(.normal)
            return
        }

        let alertsSuppressed = distanceRuleMode == .vnLaw && speedKMPH < 10
        let isLowSpeedWarning = distanceRuleMode == .timeHeadway && speedKMPH < 10 && distance < 4
        let isWarning = !alertsSuppressed && speedKMPH >= 10 && distance < activeMinimumDistance
        // TTC-based critical only above 25 km/h; below 25 km/h use absolute distance < 3.5m
        let isCriticalCandidate = (speedKMPH >= 25.0 && (timeToCollision.map { $0 < 1.8 } ?? false)) ||
            (speedKMPH < 25.0 && distance < 3.5)

        if isCriticalCandidate {
            criticalFrameCount += 1
        } else {
            criticalFrameCount = 0
        }

        if alertsSuppressed {
            criticalFrameCount = 0
            setAlertState(.normal)
        } else if criticalFrameCount >= 3 {
            setAlertState(.critical)
            alerts.playCriticalAlert(speak: voiceAlertsEnabled, reduceSpeed: timeToCollision.map { $0 < 1.8 } ?? false)
        } else if isLowSpeedWarning || isWarning {
            setAlertState(.warning)
            if speedKMPH >= 10 {
                alerts.playWarningAlert()
            }
        } else {
            setAlertState(.normal)
        }

        // Stop-and-Go alert logic
        updateStopAndGoAlert(distance: distance)
    }

    private func setAlertState(_ state: ADASAlertState) {
        guard alertState != state else {
            isDangerous = state == .critical
            return
        }
        alertState = state
        isDangerous = state == .critical
        diagnostics.record(type: "alert_state_changed", speedKMPH: speedKMPH, distanceMeters: distance, isDangerous: isDangerous, orientation: String(describing: UIDevice.current.orientation), details: "state=\(String(describing: state)), closingSpeedMPS=\(closingSpeedMPS), ttc=\(timeToCollision.map { String($0) } ?? "nil")")
    }

    /// Stop-and-Go (Lead Vehicle Departure) alert
    private func updateStopAndGoAlert(distance: Double) {
        let now = CACurrentMediaTime()

        // Disarm if speed >= 5 km/h (moving)
        if speedKMPH >= 5.0 {
            if stopAndGoArmed {
                stopAndGoArmed = false
                stoppedLeadDistance = 0
                leadVehicleStableStartTime = nil
                departureDetectedStartTime = nil
            }
            leadVehicleGoneStartTime = nil
            return
        }

        // Disarm if lead vehicle gone for > 1.5s (distance > 20m means no lead vehicle)
        if distance > 20.0 {
            if leadVehicleGoneStartTime == nil {
                leadVehicleGoneStartTime = now
            } else if now - leadVehicleGoneStartTime! >= 1.5 {
                if stopAndGoArmed {
                    stopAndGoArmed = false
                    stoppedLeadDistance = 0
                    leadVehicleStableStartTime = nil
                    departureDetectedStartTime = nil
                }
                leadVehicleGoneStartTime = nil
            }
            return
        } else {
            leadVehicleGoneStartTime = nil
        }

        // Arm: stopped (speed < 3), lead vehicle at 1.5-9m for >= 2.5s
        let hasLeadVehicleInRange = distance >= 1.5 && distance <= 9.0
        if stopAndGoAlertEnabled && speedKMPH < 3.0 && hasLeadVehicleInRange {
            if leadVehicleStableStartTime == nil {
                leadVehicleStableStartTime = now
            } else if now - leadVehicleStableStartTime! >= 2.5 && !stopAndGoArmed {
                stopAndGoArmed = true
                stoppedLeadDistance = distance  // minimum distance while stopped
                departureDetectedStartTime = nil
            }
        } else {
            leadVehicleStableStartTime = nil
        }

        // While armed and stopped, watch for distance increase >= 1.8m above stoppedLeadDistance
        if stopAndGoArmed && speedKMPH < 3.0 && closingSpeedMPS == 0 {
            let distanceIncrease = distance - stoppedLeadDistance
            if distanceIncrease >= 1.8 {
                if departureDetectedStartTime == nil {
                    departureDetectedStartTime = now
                } else if now - departureDetectedStartTime! >= 0.4 {
                    // Trigger alert (respect cooldown)
                    if now - lastStopAndGoAlertTime >= stopAndGoAlertCooldown {
                        alerts.playStopAndGoAlert(speak: voiceAlertsEnabled)
                        lastStopAndGoAlertTime = now
                        isLeadVehicleMovingAlertActive = true

                        // Auto-hide after 3s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                            self?.isLeadVehicleMovingAlertActive = false
                        }
                    }
                    // Disarm after trigger (only once per stop)
                    stopAndGoArmed = false
                    stoppedLeadDistance = 0
                    leadVehicleStableStartTime = nil
                    departureDetectedStartTime = nil
                }
            } else {
                departureDetectedStartTime = nil
                // Update stoppedLeadDistance to track minimum distance while stopped
                if distance < stoppedLeadDistance || stoppedLeadDistance == 0 {
                    stoppedLeadDistance = distance
                }
            }
        } else {
            departureDetectedStartTime = nil
        }
    }

    /// Overspeed alert based on detected speed limit sign
    private func updateOverspeedState() {
        guard enableSpeedSignRecognition else {
            isOverspeeding = false
            return
        }
        guard let limit = detectedSpeedLimit else {
            isOverspeeding = false
            return
        }
        let newOverspeeding = speedKMPH > Double(limit) + overspeedToleranceKmh
        if newOverspeeding != isOverspeeding {
            isOverspeeding = newOverspeeding
            if isOverspeeding {
                alerts.playOverspeedAlert(limit: limit, speak: voiceAlertsEnabled)
                diagnostics.record(type: "overspeed_alert", details: "speedKMPH=\(String(format: "%.1f", speedKMPH)), limit=\(limit), toleranceKmh=\(String(format: "%.1f", overspeedToleranceKmh))")
            }
        }
    }

    /// Apply Vietnam TT38 statutory speed limits based on residential area + divided road status.
    /// Called when isInResidentialArea or isDividedRoad changes, or when explicit P.127 sign clears.
    /// - If explicit P.127 sign is active (isCurrentLimitStatutory == false), do nothing.
    /// - If statutory limit is active (isCurrentLimitStatutory == true) or no limit set, update to new TT38 value.
    ///     * isInResidentialArea == true:  50 km/h (2-way) or 60 km/h (divided)
    ///     * isInResidentialArea == false: 80 km/h (2-way) or 90 km/h (divided)  [if enableDefaultOutsideResidentialLimit]
    ///     * isInResidentialArea == nil:   50 km/h (default urban fallback)
    private func applyTT38StatutoryLimit() {
        // If an explicit P.127 speed sign was confirmed by camera, respect it and don't override
        guard isCurrentLimitStatutory || detectedSpeedLimit == nil else { return }
        // Default to residential (50 km/h) if unknown — ensures a valid limit is ALWAYS active
        let inResidential = isInResidentialArea ?? true
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
            diagnostics.record(type: "tsr_tt38_statutory", details: "limit=\(newLimit) inResidential=\(inResidential) divided=\(isDividedRoad) source=\(isDividedRoad ? (camera.trafficSignDetector.isDividedRoadFromSign ? "sign" : "osm") : "osm")")
            updateOverspeedState()
        }
    }

    /// Handle camera-detected residential sign (R.420 enter / R.421 exit)
    /// Sets camera override with time+location for dual precedence over OSM
    func handleCameraResidentialSign(isResidential: Bool, location: CLLocation, timestamp: Date) {
        isInResidentialArea = isResidential
        isCurrentLimitStatutory = true
        lastCameraResidentialSignTime = timestamp
        lastCameraResidentialSignLocation = location
        hasReceivedCameraSignOverride = true
        applyTT38StatutoryLimit()
    }

    /// Handle camera-detected clear limit sign (DP.134 / DP.135)
    /// Clears camera override but preserves residential status from OSM
    func handleCameraClearLimitSign(location: CLLocation, timestamp: Date) {
        hasReceivedCameraSignOverride = false  // Clear the camera override
        lastCameraResidentialSignTime = timestamp
        lastCameraResidentialSignLocation = location
        // Clear detected speed limit to trigger statutory fallback
        detectedSpeedLimit = nil
        isCurrentLimitStatutory = true
        applyTT38StatutoryLimit()
    }

    /// Evaluate dual precedence (time > 5 min AND distance > 2 km) to clear camera override
    func evaluateCameraPrecedence() {
        guard hasReceivedCameraSignOverride,
              lastCameraResidentialSignTime != .distantPast,
              let signLoc = lastCameraResidentialSignLocation,
              let currentLoc = location.lastValidLocation else {
            hasReceivedCameraSignOverride = false
            return
        }

        let timeElapsed = Date().timeIntervalSince(lastCameraResidentialSignTime)
        let distanceTraveled = currentLoc.distance(from: signLoc)

        if timeElapsed > 300 && distanceTraveled > 2000 {
            hasReceivedCameraSignOverride = false
            // Clear camera residential state so OSM can take over
            // Apply OSM residential status immediately (don't wait for subscriber which requires AND)
            if let osmInResidential = location.roadMetadata.osmIsInResidentialArea {
                isInResidentialArea = osmInResidential
            } else {
                isInResidentialArea = nil
            }
            isCurrentLimitStatutory = true
            applyTT38StatutoryLimit()
        }
    }

    /// Dynamic in-drive horizon auto-calibration with progress tracking
    private func attemptHorizonAutoCalibration(box: CGRect?, confidence: Float) {
        // Check for mount shift on every frame
        motion.checkMountShift(speedKMPH: speedKMPH)

        // Skip calibration if mount is shifted or already auto-calibrated
        guard showHorizonGuide,
              motion.isActive,
              speedKMPH > 25.0,
              abs(motion.deltaRoll) < 2.0,
              !motion.isMountShifted else {
            horizonCalibrationFrames = 0
            lastTrackedBox = nil
            return
        }

        // Use lead vehicle box or confident lane lines for stable tracking
        let hasStableLeadVehicle = box != nil && confidence >= 0.70 && box!.width >= 0.05 && box!.width <= 0.25
        let hasConfidentLanes = laneDetector.isLaneDetectionActive &&
                                laneDetector.leftLaneConfidence > 0.6 &&
                                laneDetector.rightLaneConfidence > 0.6 &&
                                !laneDetector.leftLanePoints.isEmpty &&
                                !laneDetector.rightLanePoints.isEmpty
        let hasStableTracking = hasStableLeadVehicle || hasConfidentLanes

        if hasStableLeadVehicle, let box = box {
            if let lastBox = lastTrackedBox {
                let iou = intersectionOverUnion(lastBox, box)
                if iou < 0.5 {
                    horizonCalibrationFrames = 0
                    lastTrackedBox = box
                    // Still record calibration frame for lane-based stability
                    motion.recordCalibrationFrame(speedKMPH: speedKMPH, hasStableTracking: hasConfidentLanes, horizonGuideEnabled: showHorizonGuide)
                    return
                }
            }
            lastTrackedBox = box
            horizonCalibrationFrames += 1
        } else if hasConfidentLanes {
            // Lane-based calibration frame
            horizonCalibrationFrames += 1
        } else {
            horizonCalibrationFrames = 0
            lastTrackedBox = nil
            motion.recordCalibrationFrame(speedKMPH: speedKMPH, hasStableTracking: false, horizonGuideEnabled: showHorizonGuide)
            return
        }

        // Record calibration progress
        motion.recordCalibrationFrame(speedKMPH: speedKMPH, hasStableTracking: hasStableTracking, horizonGuideEnabled: showHorizonGuide)

        guard horizonCalibrationFrames >= 5 else { return }

        // Infer horizon from lead vehicle or lane geometry
        var inferredHorizonY: Double = 0.45
        if hasStableLeadVehicle, let box = box {
            inferredHorizonY = (1.0 - box.minY) - (box.height * 0.15)
        } else if hasConfidentLanes,
                  let laneEdges = laneDetector.getLaneEdgesAtY(0.85, imageSize: camera.cameraFrameSize) {
            // Use lane geometry to infer horizon (vanishing point)
            let laneCenter = (laneEdges.left + laneEdges.right) / 2.0
            inferredHorizonY = 0.45 + (laneCenter - 0.5) * 0.1  // Small adjustment
        }

        let clampedInferred = max(0.25, min(0.65, inferredHorizonY))
        motion.updateEffectiveHorizonFromVision(inferredHorizonY: clampedInferred)
    }
    
    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
