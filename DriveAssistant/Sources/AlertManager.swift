import AVFoundation
import AudioToolbox
import Foundation
import UIKit

final class AlertManager {
    private var lastWarningAlert = Date.distantPast
    private var lastCriticalAlert = Date.distantPast
    private var lastLaneDepartureAlert = Date.distantPast
    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession = AVAudioSession.sharedInstance()
    private var interruptionObserver: NSObjectProtocol?
    private let hapticGenerator = UINotificationFeedbackGenerator()
    
    // AVAudioEngine for synthesized low-pitched chime (distinct from forward collision)
    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private let chimeFrequency: Double = 220.0  // A3 - low pitch (vs ~880Hz for collision)
    private let chimeDuration: Double = 0.18

    init() {
        configureAudioSession()
        observeInterruptions()
        hapticGenerator.prepare()
        setupChimeEngine()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        audioEngine.stop()
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

    // MARK: - Synthesized Chime Engine
    private func setupChimeEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
        do {
            try audioEngine.start()
        } catch {
            print("AlertManager: Failed to start audio engine: \(error)")
        }
    }

    private func playLowChime() {
        let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * chimeDuration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        
        buffer.frameLength = frameCount
        let channelData = buffer.floatChannelData?[0]
        
        // Generate low-pitched sine wave with quick decay envelope
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t * 8.0)  // Fast decay
            let sample = sin(2.0 * .pi * chimeFrequency * t) * envelope * 0.3
            channelData?[frame] = Float(sample)
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        playerNode.play()
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

extension AlertManager {
    func playLaneDepartureAlert(speak: Bool) {
        // Low-pitched double-pulse chime (220Hz A3) - clearly distinct from high-pitched collision beep (~880Hz)
        playLowChime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.playLowChime()
        }
        
        // Haptic feedback
        hapticGenerator.notificationOccurred(.warning)
        
        if speak {
            let utterance = AVSpeechUtterance(string: "Cảnh báo lệch làn")
            utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utterance.rate = 0.5
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            } catch { }
            synthesizer.speak(utterance)
        }
    }
}
