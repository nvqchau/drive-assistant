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

final class DriveAssistantModel: ObservableObject {
    @Published var distance: Double?
    @Published var speedKMPH: Double = 0
    @Published private(set) var gpsAccuracy: CLLocationAccuracy = .infinity
    @Published var isDangerous = false
    @Published var alertState: ADASAlertState = .normal
    @Published private(set) var closingSpeedMPS: Double = 0
    @Published private(set) var timeToCollision: Double?
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
    @Published var laneCenterOffsetX: Double = -0.03 {
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
    private let location = LocationManager()
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
    private var lastTrackedBox: CGRect?
    private var lastTrackedConfidence: Float = 0
    private var horizonCalibrationFrames = 0

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

    var baseSafeDistance: Double {
        switch distanceRuleMode {
        case .timeHeadway:
            return max(5, speedKMPH / 3.6 * timeHeadway)
        case .vnLaw:
            switch speedKMPH {
            case ..<10: return 0
            case 10..<58: return max(5, speedKMPH * 0.5)
            case 58...60: return 35
            case 60..<80: return 55
            case 80...100: return 70
            default: return 100
            }
        }
    }

    var activeMinimumDistance: Double {
        baseSafeDistance * (distanceRuleMode == .vnLaw && effectiveRoadCondition == .wet ? 1.3 : 1.0)
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
        laneCenterOffsetX = defaults.object(forKey: "laneCenterOffsetX") as? Double ?? -0.03
        showHorizonGuide = defaults.object(forKey: "showHorizonGuide") as? Bool ?? true
        enableLaneDetection = defaults.object(forKey: "enableLaneDetection") as? Bool ?? true
        ldwsMinSpeedKmh = defaults.object(forKey: "ldwsMinSpeedKmh") as? Double ?? 50.0
        stopAndGoAlertEnabled = defaults.object(forKey: "stopAndGoAlertEnabled") as? Bool ?? true
        displayThemeMode = DisplayThemeMode(rawValue: defaults.string(forKey: "displayThemeMode") ?? "") ?? .auto
        hudMirrorMode = defaults.bool(forKey: "hudMirrorMode")
        if hudMirrorMode {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
        }
        
        camera.attachDiagnostics(diagnostics)
        camera.setCalibrationFactor(calibrationFactor)
        camera.setLaneCenterOffsetX(laneCenterOffsetX)
        camera.laneDetector = laneDetector
        laneDetector.setROIOffset(laneCenterOffsetX)
        laneDetector.setMinSpeedForDepartureAlert(ldwsMinSpeedKmh)

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

        // Lane departure alerts
        laneDetector.$departureAlertActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                if active {
                    self?.alerts.playLaneDepartureAlert(speak: self?.voiceAlertsEnabled ?? false)
                }
            }
            .store(in: &cancellables)

        // Start motion manager if enabled
        if showHorizonGuide {
            motion.start()
        }
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
    }

    private func updateAlertState() {
        guard let distance else {
            criticalFrameCount = 0
            setAlertState(.normal)
            return
        }

        let speedMPS = speedKMPH / 3.6
        let alertsSuppressed = distanceRuleMode == .vnLaw && speedKMPH < 10
        let isLowSpeedWarning = distanceRuleMode == .timeHeadway && speedKMPH < 10 && distance < 4
        let isWarning = !alertsSuppressed && speedKMPH >= 10 && distance < activeMinimumDistance
        let isCriticalCandidate = speedKMPH >= 10 && (
            (timeToCollision.map { $0 < 1.8 } ?? false) ||
            distance < max(activeMinimumDistance, max(5.0, speedMPS * 1.0))
        )

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
