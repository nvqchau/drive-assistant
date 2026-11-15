import AVFoundation
import AudioToolbox
import Foundation
import UIKit

final class AlertManager {
    private var lastWarningAlert = Date.distantPast
    private var lastCriticalAlert = Date.distantPast
    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession = AVAudioSession.sharedInstance()
    private var interruptionObserver: NSObjectProtocol?
    private let hapticGenerator = UINotificationFeedbackGenerator()

    init() {
        configureAudioSession()
        observeInterruptions()
        hapticGenerator.prepare()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    private func configureAudioSession() {
        do {
            try audioSession.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("AlertManager: Failed to configure audio session: \(error)")
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            if type == .ended {
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        self.reactivateAudioSession()
                    }
                }
            }
        }
    }

    private func reactivateAudioSession() {
        do {
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("AlertManager: Failed to reactivate audio session: \(error)")
        }
    }

    func playWarningAlert() {
        guard Date().timeIntervalSince(lastWarningAlert) >= 5 else { return }
        lastWarningAlert = Date()
        AudioServicesPlaySystemSound(1052)
    }

    func playCriticalAlert(speak: Bool, reduceSpeed: Bool) {
        guard Date().timeIntervalSince(lastCriticalAlert) >= 3 else { return }
        lastCriticalAlert = Date()
        AudioServicesPlaySystemSound(1005)
        hapticGenerator.notificationOccurred(.error)
        guard speak else { return }
        let utterance = AVSpeechUtterance(string: reduceSpeed ? "Giảm tốc độ" : "Giữ khoảng cách an toàn")
        utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
        utterance.rate = 0.48
        do {
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("AlertManager: Failed to activate audio session for speech: \(error)")
        }
        synthesizer.speak(utterance)
    }
}
