import AVFoundation
import Combine
import CoreLocation
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

final class DriveAssistantModel: ObservableObject {
    @Published var distance: Double?
    @Published var speedKMPH: Double = 0
    @Published var isDangerous = false
    @Published var alertState: ADASAlertState = .normal
    @Published private(set) var closingSpeedMPS: Double = 0
    @Published private(set) var timeToCollision: Double?
    @Published var isSettingsPresented = false
    @Published var voiceAlertsEnabled = true
    @Published var usesVietnamese = true
    @Published var distanceRuleMode: DistanceRuleMode {
        didSet { UserDefaults.standard.set(distanceRuleMode.rawValue, forKey: "distanceRuleMode") }
    }
    @Published var roadCondition: RoadCondition {
        didSet { UserDefaults.standard.set(roadCondition.rawValue, forKey: "roadCondition") }
    }
    @Published private(set) var detectedRoadCondition: RoadCondition = .dry
    @Published var timeHeadway: Double = 2.5
    @Published var calibrationFactor: Double = 1.40

    let camera = CameraManager()
    let diagnostics = DiagnosticsLogStore()
    private let location = LocationManager()
    private let alerts = AlertManager()
    private var cancellables = Set<AnyCancellable>()
    private var smoothedDistance: Double?
    private let distanceEMAAlpha = 0.3
    private var distanceHistory: [(timestamp: Date, distance: Double)] = []
    private let closingSpeedWindow: TimeInterval = 0.5
    private var criticalFrameCount = 0

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
        distanceRuleMode = DistanceRuleMode(rawValue: defaults.string(forKey: "distanceRuleMode") ?? "") ?? .vnLaw
        roadCondition = RoadCondition(rawValue: defaults.string(forKey: "roadCondition") ?? "") ?? .dry
        camera.attachDiagnostics(diagnostics)
        camera.setCalibrationFactor(calibrationFactor)
        location.$speedKMPH.assign(to: &$speedKMPH)
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
                    self.smoothedDistance = self.smoothedDistance.map {
                        self.distanceEMAAlpha * rawDistance + (1 - self.distanceEMAAlpha) * $0
                    } ?? rawDistance
                    self.distance = self.smoothedDistance
                    self.updateDistanceHistory(distance: self.smoothedDistance ?? rawDistance)
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
        $timeHeadway.dropFirst().sink { [weak self] _ in self?.updateAlertState() }.store(in: &cancellables)
        $distanceRuleMode.dropFirst().sink { [weak self] _ in self?.updateAlertState() }.store(in: &cancellables)
        $roadCondition.dropFirst().sink { [weak self] _ in self?.updateAlertState() }.store(in: &cancellables)
    }

    func start() {
        diagnostics.record(type: "session_started", orientation: String(describing: UIDevice.current.orientation))
        camera.start()
        location.start()
    }

    func stop() {
        diagnostics.record(type: "session_stopped", speedKMPH: speedKMPH, distanceMeters: distance, isDangerous: isDangerous, orientation: String(describing: UIDevice.current.orientation))
        camera.stop()
        location.stop()
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
        let now = Date()
        distanceHistory.append((now, distance))
        let cutoff = now.addingTimeInterval(-closingSpeedWindow)
        distanceHistory.removeAll { $0.timestamp < cutoff }

        guard let oldest = distanceHistory.first,
              now.timeIntervalSince(oldest.timestamp) > 0 else {
            closingSpeedMPS = 0
            timeToCollision = nil
            return
        }
        let elapsed = now.timeIntervalSince(oldest.timestamp)
        let closingSpeed = max(0, (oldest.distance - distance) / elapsed)
        closingSpeedMPS = closingSpeed
        timeToCollision = closingSpeed > 0.5 ? distance / closingSpeed : nil
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
}
