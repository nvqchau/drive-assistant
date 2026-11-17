import CoreMotion
import Foundation
import SwiftUI
import UIKit

final class MotionManager: ObservableObject {
    private let motionManager = CMMotionManager()
    private let updateInterval = 0.1  // 10 Hz

    // Raw gyroscope values
    @Published var rollDegrees: Double = 0
    @Published var pitchDegrees: Double = 0
    @Published var horizonY: Double = 0.5
    @Published var isActive: Bool = false
    @Published var isLevel: Bool = false

    // Reference mount calibration
    @AppStorage("calibratedPitch") var calibratedPitch: Double = 0.0
    @AppStorage("calibratedRoll") var calibratedRoll: Double = 0.0
    @AppStorage("hasSavedMountProfile") var hasSavedMountProfile: Bool = false

    // Learned horizon offset from auto-calibration (persisted)
    @AppStorage("learnedHorizonOffset") private var learnedHorizonOffset: Double = 0.0

    // Delta from calibrated reference
    @Published var deltaPitch: Double = 0
    @Published var deltaRoll: Double = 0

    // Dynamic effective horizon (gyro baseline + in-drive EMA)
    @Published var effectiveHorizonY: Double = 0.45

    // Mount alignment state
    @Published var isMountAligned: Bool = false

    // Auto-calibration progress (0...100)
    @Published var calibrationProgress: Int = 0
    @Published var isAutoCalibrated: Bool = false

    // Mount shift detection
    @Published var isMountShifted: Bool = false
    private var mountShiftStartTime: TimeInterval?
    private let mountShiftThreshold: TimeInterval = 2.0  // seconds
    private let mountShiftAngleThreshold: Double = 3.5  // degrees

    private let verticalFOV: Double = 41.0  // iPhone 1x landscape vertical FOV
    private let baseHorizonY: Double = 0.45  // Base normalized horizon (45% from top)
    private let horizonYRange: ClosedRange<Double> = 0.25...0.65
    private let autoCalibrateAlpha: Double = 0.02  // Slow EMA for in-drive calibration
    private let autoCalibrateClamp: Double = 0.06  // Max deviation from gyro baseline

    init() {
        // Initialize effectiveHorizonY from stored calibration
        computeDeltasAndHorizon()

        // Initialize calibration state from persisted profile
        if hasSavedMountProfile {
            calibrationProgress = 100
            isAutoCalibrated = true
            effectiveHorizonY = horizonY + learnedHorizonOffset
        }
    }
    
    func saveCurrentMountAngle() {
        calibratedPitch = pitchDegrees
        calibratedRoll = rollDegrees
        hasSavedMountProfile = true
        calibrationProgress = 100
        isAutoCalibrated = true
        learnedHorizonOffset = effectiveHorizonY - horizonY
        computeDeltasAndHorizon()
    }

    func resetMountProfile() {
        calibratedPitch = 0.0
        calibratedRoll = 0.0
        hasSavedMountProfile = false
        learnedHorizonOffset = 0.0
        calibrationProgress = 0
        isAutoCalibrated = false
        isMountShifted = false
        mountShiftStartTime = nil
        computeDeltasAndHorizon()
    }

    /// Call from DriveAssistantModel when a valid calibration frame is processed during driving
    func recordCalibrationFrame(speedKMPH: Double, hasStableTracking: Bool, horizonGuideEnabled: Bool) {
        guard horizonGuideEnabled && isActive && speedKMPH > 25.0 && abs(deltaRoll) < 2.0 && hasStableTracking else {
            return
        }

        // Increment progress by ~2% per valid frame
        calibrationProgress = min(calibrationProgress + 2, 100)

        if calibrationProgress >= 100 && !isAutoCalibrated {
            isAutoCalibrated = true
            // Save current pose as the new calibrated reference so deltas are measured against it
            calibratedPitch = pitchDegrees
            calibratedRoll = rollDegrees
            hasSavedMountProfile = true
            // Persist learned horizon offset (measured against new reference)
            learnedHorizonOffset = effectiveHorizonY - horizonY
            isMountShifted = false
            mountShiftStartTime = nil
            // Recompute deltas with new reference
            computeDeltasAndHorizon()
        }
    }

    /// Call from DriveAssistantModel to check for mount shift
    func checkMountShift(speedKMPH: Double) {
        let hasProfile = hasSavedMountProfile || isAutoCalibrated
        let isShiftedNow = hasProfile && (abs(deltaRoll) > mountShiftAngleThreshold || abs(deltaPitch) > mountShiftAngleThreshold) && speedKMPH > 10.0

        let now = CACurrentMediaTime()
        if isShiftedNow {
            if mountShiftStartTime == nil {
                mountShiftStartTime = now
            } else if now - mountShiftStartTime! >= mountShiftThreshold {
                if !isMountShifted {
                    isMountShifted = true
                    // Reset calibration progress to force re-calibration once mount settles
                    calibrationProgress = 0
                    isAutoCalibrated = false
                }
            }
        } else {
            mountShiftStartTime = nil
            // Auto-clear mount shift when alignment is restored
            if isMountShifted && hasProfile && abs(deltaRoll) <= 1.5 && abs(deltaPitch) <= 1.5 {
                isMountShifted = false
            }
        }
    }
    
    private func computeDeltasAndHorizon() {
        deltaPitch = pitchDegrees - calibratedPitch
        deltaRoll = rollDegrees - calibratedRoll

        // Gyro-based horizon from delta pitch
        var hY = baseHorizonY + (deltaPitch / verticalFOV)
        hY = max(horizonYRange.lowerBound, min(horizonYRange.upperBound, hY))
        horizonY = hY

        // Preserve learned horizon offset if auto-calibrated and not mount-shifted
        if isAutoCalibrated && !isMountShifted {
            effectiveHorizonY = hY + learnedHorizonOffset
            effectiveHorizonY = max(horizonYRange.lowerBound, min(horizonYRange.upperBound, effectiveHorizonY))
        } else {
            effectiveHorizonY = hY
        }

        // Mount aligned: within ±1.5° of saved reference
        let hasProfile = hasSavedMountProfile || isAutoCalibrated
        isMountAligned = hasProfile && abs(deltaRoll) <= 1.5 && abs(deltaPitch) <= 1.5

        // Level check: roll within ±1.5° and pitch within ±3.0° (relative to calibrated)
        isLevel = abs(deltaRoll) <= 1.5 && abs(deltaPitch) <= 3.0
    }
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            print("MotionManager: Device motion not available")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            guard let self, let motion = motion else { return }
            
            if let error = error {
                print("MotionManager: Device motion error: \(error)")
                return
            }
            
            // Use gravity vector to compute attitude (Gimbal Lock free for landscape mounting)
            self.updateAttitudeFromGravity(motion.gravity)
        }
        isActive = true
    }
    
    /// Call from DriveAssistantModel when driving straight with stable lead vehicle
    func updateEffectiveHorizonFromVision(inferredHorizonY: Double) {
        // Slow EMA toward vision-inferred horizon
        let newEffective = effectiveHorizonY * (1 - autoCalibrateAlpha) + inferredHorizonY * autoCalibrateAlpha

        // Clamp within ±0.06 of gyro baseline
        let minAllowed = horizonY - autoCalibrateClamp
        let maxAllowed = horizonY + autoCalibrateClamp
        effectiveHorizonY = max(minAllowed, min(maxAllowed, newEffective))

        // Persist learned offset continuously during adaptation
        if isAutoCalibrated && !isMountShifted {
            learnedHorizonOffset = effectiveHorizonY - horizonY
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isActive = false
    }
    
    deinit {
        stop()
    }
}

// MARK: - Gravity-vector attitude computation (Gimbal Lock free)
extension MotionManager {
    /// Update roll/pitch from gravity vector. Call on each device motion update.
    /// Uses gravity vector directly - works in any orientation without Gimbal Lock.
    func updateAttitudeFromGravity(_ gravity: CMAcceleration) {
        let gx = gravity.x
        let gy = gravity.y
        let gz = gravity.z
        
        // Roll: lateral tilt (left/right horizon tilt)
        // gx <= 0: notch left (landscapeLeft) -> atan2(-gy, -gx)
        // gx > 0: notch right (landscapeRight) -> atan2(gy, gx)
        // Both give 0° when iPhone is held upright in landscape
        let rawRoll: Double
        if gx <= 0 {
            rawRoll = atan2(-gy, -gx) * 180.0 / .pi
        } else {
            rawRoll = atan2(gy, gx) * 180.0 / .pi
        }
        
        // Pitch: vertical camera elevation (0 when horizontal/level to road)
        // asin(clamp(gz)) gives angle from horizontal plane
        // Positive pitch = tilted up toward sky, negative = tilted down toward hood
        let rawPitch = asin(max(-1.0, min(1.0, gz))) * 180.0 / .pi
        
        // Smooth with EMA
        let alpha = 0.3
        rollDegrees = rollDegrees * (1 - alpha) + rawRoll * alpha
        pitchDegrees = pitchDegrees * (1 - alpha) + rawPitch * alpha
        
        computeDeltasAndHorizon()
    }
}
