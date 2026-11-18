import AVFoundation
import AudioToolbox
import Foundation
import UIKit

final class AlertManager {
    private var lastWarningAlert = Date.distantPast
    private var lastCriticalAlert = Date.distantPast
    private var lastLaneDepartureAlert = Date.distantPast
    private var lastOverspeedAlert = Date.distantPast
    private let overspeedAlertCooldown: TimeInterval = 10.0
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
        do {
            let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            guard sampleRate > 0 else { return }
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
                try audioEngine.start()
            }
            playerNode.play()
        } catch {
            print("AlertManager: Low chime failed: \(error)")
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

    // MARK: - Stop-and-Go Alert (Lead Vehicle Departure)
    func playStopAndGoAlert(speak: Bool) {
        // Ascending two-note chime: C5 (523.25 Hz) -> E5 (659.25 Hz), 0.15s apart
        playAscendingChime(note1Freq: 523.25, note2Freq: 659.25, gap: 0.15)

        // Gentle success haptic
        hapticGenerator.notificationOccurred(.success)

        if speak {
            let utterance = AVSpeechUtterance(string: "Xe phía trước đã di chuyển")
            utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utterance.rate = 0.48
            do {
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch { }
            synthesizer.speak(utterance)
        }
    }

    private func playAscendingChime(note1Freq: Double, note2Freq: Double, gap: Double) {
        do {
            let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            guard sampleRate > 0 else { return }
            let noteDuration = 0.12
            let frameCount = AVAudioFrameCount(sampleRate * noteDuration)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

            // Note 1
            if let buffer1 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                buffer1.frameLength = frameCount
                let channelData = buffer1.floatChannelData?[0]
                for frame in 0..<Int(frameCount) {
                    let t = Double(frame) / sampleRate
                    let envelope = exp(-t * 10.0)
                    let sample = sin(2.0 * .pi * note1Freq * t) * envelope * 0.25
                    channelData?[frame] = Float(sample)
                }
                playerNode.scheduleBuffer(buffer1, at: nil, options: .interrupts, completionHandler: nil)
            }

            // Note 2 (delayed)
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
                guard let self,
                      let buffer2 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
                buffer2.frameLength = frameCount
                let channelData = buffer2.floatChannelData?[0]
                for frame in 0..<Int(frameCount) {
                    let t = Double(frame) / sampleRate
                    let envelope = exp(-t * 10.0)
                    let sample = sin(2.0 * .pi * note2Freq * t) * envelope * 0.25
                    channelData?[frame] = Float(sample)
                }
                self.playerNode.scheduleBuffer(buffer2, at: nil, options: .interrupts, completionHandler: nil)
                if !self.audioEngine.isRunning {
                    try? self.audioEngine.start()
                }
                self.playerNode.play()
            }

            // Play first note immediately
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            playerNode.play()
        } catch {
            print("AlertManager: Ascending chime failed: \(error)")
        }
    }
}

// MARK: - Overspeed Alert (Speed Limit Sign Recognition)
extension AlertManager {
    func playOverspeedAlert(limit: Int, speak: Bool) {
        guard Date().timeIntervalSince(lastOverspeedAlert) >= overspeedAlertCooldown else { return }
        lastOverspeedAlert = Date()

        // Sharp warning chime: high-pitched single beep (~880Hz A5) distinct from collision (~880Hz rapid)
        playOverspeedChime()

        // Error haptic for overspeed
        hapticGenerator.notificationOccurred(.error)

        if speak {
            let utterance = AVSpeechUtterance(string: "Vượt quá tốc độ giới hạn \(limit) ki-lô-mét trên giờ")
            utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utterance.rate = 0.48
            do {
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch { }
            synthesizer.speak(utterance)
        }
    }

    private func playOverspeedChime() {
        do {
            let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            guard sampleRate > 0 else { return }
            let duration = 0.15
            let frameCount = AVAudioFrameCount(sampleRate * duration)
            let frequency = 880.0  // A5 - sharp warning pitch

            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

            buffer.frameLength = frameCount
            let channelData = buffer.floatChannelData?[0]
            for frame in 0..<Int(frameCount) {
                let t = Double(frame) / sampleRate
                let envelope = exp(-t * 12.0)  // Very fast decay for sharp beep
                let sample = sin(2.0 * .pi * frequency * t) * envelope * 0.35
                channelData?[frame] = Float(sample)
            }

            playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            playerNode.play()
        } catch {
            print("AlertManager: Overspeed chime failed: \(error)")
        }
    }
}

// MARK: - Speed Limit Cleared Alert (DP.134 / DP.135)
extension AlertManager {
    func playSpeedLimitClearedAlert(speak: Bool) {
        // Subtle neutral chime: descending two-note (E5 -> C5) softer than overspeed
        playClearedChime()

        // Light success haptic
        hapticGenerator.notificationOccurred(.success)

        if speak {
            let utterance = AVSpeechUtterance(string: "Hết hạn chế tốc độ")
            utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
            utterance.rate = 0.48
            do {
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            } catch { }
            synthesizer.speak(utterance)
        }
    }

    private func playClearedChime() {
        do {
            let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            guard sampleRate > 0 else { return }
            let noteDuration = 0.10
            let frameCount = AVAudioFrameCount(sampleRate * noteDuration)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

            // Note 1: E5 (659.25 Hz)
            if let buffer1 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) {
                buffer1.frameLength = frameCount
                let channelData = buffer1.floatChannelData?[0]
                for frame in 0..<Int(frameCount) {
                    let t = Double(frame) / sampleRate
                    let envelope = exp(-t * 8.0)
                    let sample = sin(2.0 * .pi * 659.25 * t) * envelope * 0.2
                    channelData?[frame] = Float(sample)
                }
                playerNode.scheduleBuffer(buffer1, at: nil, options: .interrupts, completionHandler: nil)
            }

            // Note 2: C5 (523.25 Hz) - delayed 0.12s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self,
                      let buffer2 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
                buffer2.frameLength = frameCount
                let channelData = buffer2.floatChannelData?[0]
                for frame in 0..<Int(frameCount) {
                    let t = Double(frame) / sampleRate
                    let envelope = exp(-t * 8.0)
                    let sample = sin(2.0 * .pi * 523.25 * t) * envelope * 0.2
                    channelData?[frame] = Float(sample)
                }
                self.playerNode.scheduleBuffer(buffer2, at: nil, options: .interrupts, completionHandler: nil)
                if !self.audioEngine.isRunning {
                    try? self.audioEngine.start()
                }
                self.playerNode.play()
            }

            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            playerNode.play()
        } catch {
            print("AlertManager: Cleared chime failed: \(error)")
        }
    }
}
