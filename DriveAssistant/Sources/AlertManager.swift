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

    // Advisory sign alert cooldowns (per key, 8s)
    private var lastAdvisoryAlert: [String: Date] = [:]
    private let advisoryAlertCooldown: TimeInterval = 8.0

    // AVAudioEngine for synthesized chimes
    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private let chimeFrequency: Double = 220.0  // A3 - low pitch
    private let chimeDuration: Double = 0.18
    private var engineStarted = false

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
        engineStarted = false
    }

    private func configureAudioSession() {
        do {
            try audioSession.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("AlertManager: Failed to configure audio session: \(error)")
        }
    }

    private func ensureEngineRunning() -> Bool {
        if engineStarted && audioEngine.isRunning {
            return true
        }
        do {
            try audioEngine.start()
            engineStarted = true
            return true
        } catch {
            print("AlertManager: Failed to start audio engine: \(error)")
            engineStarted = false
            return false
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
        _ = ensureEngineRunning()
    }

    private func playLowChime() {
        guard ensureEngineRunning() else { return }
        let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
        let frameCount = AVAudioFrameCount(sampleRate * chimeDuration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        // Validate format matches player node output format
        guard buffer.format.isEqual(playerNode.outputFormat(forBus: 0)) else {
            print("AlertManager: Low chime buffer format mismatch")
            return
        }

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
            synthesizer.speak(utterance)
        } catch {
            print("AlertManager: Critical speech failed: \(error)")
        }
    }
}

extension AlertManager {
    func playLaneDepartureAlert(speak: Bool) {
        do {
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
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                synthesizer.speak(utterance)
            }
        } catch {
            print("AlertManager: Lane departure alert failed: \(error)")
        }
    }

    // MARK: - Stop-and-Go Alert (Lead Vehicle Departure)
    func playStopAndGoAlert(speak: Bool) {
        do {
            // Ascending two-note chime: C5 (523.25 Hz) -> E5 (659.25 Hz), 0.15s apart
            playAscendingChime(note1Freq: 523.25, note2Freq: 659.25, gap: 0.15)

            // Gentle success haptic
            hapticGenerator.notificationOccurred(.success)

            if speak {
                let utterance = AVSpeechUtterance(string: "Xe phía trước đã di chuyển")
                utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
                utterance.rate = 0.48
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                synthesizer.speak(utterance)
            }
        } catch {
            print("AlertManager: Stop-and-go alert failed: \(error)")
        }
    }

    private func playAscendingChime(note1Freq: Double, note2Freq: Double, gap: Double) {
        guard ensureEngineRunning() else { return }
        let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
        let noteDuration = 0.12
        let frameCount = AVAudioFrameCount(sampleRate * noteDuration)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        // Validate format matches player node output format
        guard format.isEqual(playerNode.outputFormat(forBus: 0)) else {
            print("AlertManager: Ascending chime format mismatch")
            return
        }

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
                  self.ensureEngineRunning(),
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
            self.playerNode.play()
        }

        // Play first note immediately
        playerNode.play()
    }
}

// MARK: - Overspeed Alert (Speed Limit Sign Recognition)
extension AlertManager {
    func playOverspeedAlert(limit: Int, speak: Bool) {
        do {
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
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                synthesizer.speak(utterance)
            }
        } catch {
            print("AlertManager: Overspeed alert failed: \(error)")
        }
    }

    private func playOverspeedChime() {
        guard ensureEngineRunning() else { return }
        let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
        let duration = 0.15
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let frequency = 880.0  // A5 - sharp warning pitch

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        // Validate format matches player node output format
        guard buffer.format.isEqual(playerNode.outputFormat(forBus: 0)) else {
            print("AlertManager: Overspeed chime format mismatch")
            return
        }

        buffer.frameLength = frameCount
        let channelData = buffer.floatChannelData?[0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-t * 12.0)  // Very fast decay for sharp beep
            let sample = sin(2.0 * .pi * frequency * t) * envelope * 0.35
            channelData?[frame] = Float(sample)
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        playerNode.play()
    }
}

// MARK: - Speed Limit Cleared Alert (DP.134 / DP.135)
extension AlertManager {
    func playSpeedLimitClearedAlert(speak: Bool) {
        do {
            // Subtle neutral chime: descending two-note (E5 -> C5) softer than overspeed
            playClearedChime()

            // Light success haptic
            hapticGenerator.notificationOccurred(.success)

            if speak {
                let utterance = AVSpeechUtterance(string: "Hết hạn chế tốc độ")
                utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
                utterance.rate = 0.48
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                synthesizer.speak(utterance)
            }
        } catch {
            print("AlertManager: Speed limit cleared alert failed: \(error)")
        }
    }

    private func playClearedChime() {
        guard ensureEngineRunning() else { return }
        let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
        let noteDuration = 0.10
        let frameCount = AVAudioFrameCount(sampleRate * noteDuration)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        // Validate format matches player node output format
        guard format.isEqual(playerNode.outputFormat(forBus: 0)) else {
            print("AlertManager: Cleared chime format mismatch")
            return
        }

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
                  self.ensureEngineRunning(),
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
            self.playerNode.play()
        }

        // Play first note immediately
        playerNode.play()
    }
}

// MARK: - Traffic Sign Advisory Alert (Prohibitory / Informational)
extension AlertManager {
    /// Play advisory traffic sign alert with distinct chime and Vietnamese voice.
    /// - Parameters:
    ///   - key: Canonical advisory key ("no_entry", "no_cars", "no_overtaking", "residential_area")
    ///   - speak: Whether to speak the Vietnamese prompt
    func playTrafficSignAdvisoryAlert(key: String, speak: Bool) {
        do {
            // Cooldown per sign key (8s)
            let now = Date()
            if let last = lastAdvisoryAlert[key], now.timeIntervalSince(last) < advisoryAlertCooldown {
                return
            }
            lastAdvisoryAlert[key] = now

            // Distinct two-tone descending chime: G5 (784.0 Hz) -> D5 (587.33 Hz)
            playAdvisoryChime()

            // Warning haptic
            hapticGenerator.notificationOccurred(.warning)

            // Vietnamese voice prompt
            if speak {
                let vietnameseText: String
                switch key {
                case "no_entry":
                    vietnameseText = "Chú ý, biển cấm đi ngược chiều"
                case "no_cars":
                    vietnameseText = "Chú ý, đường cấm ô tô"
                case "no_overtaking":
                    vietnameseText = "Chú ý, đoạn đường cấm vượt"
                case "residential_area":
                    vietnameseText = "Vào khu đông dân cư, giới hạn năm mươi ki-lô-mét trên giờ"
                default:
                    vietnameseText = key
                }
                let utterance = AVSpeechUtterance(string: vietnameseText)
                utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
                utterance.rate = 0.48
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                synthesizer.speak(utterance)
            }
        } catch {
            print("AlertManager: Traffic sign advisory alert failed: \(error)")
        }
    }

    /// Play distinct descending two-tone chime: G5 (784.0 Hz) -> D5 (587.33 Hz), 0.12s each, 0.14s gap
    private func playAdvisoryChime() {
        guard ensureEngineRunning() else { return }
        let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
        let noteDuration = 0.12
        let gap = 0.14
        let frameCount = AVAudioFrameCount(sampleRate * noteDuration)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        // Validate format matches player node output format
        guard format.isEqual(playerNode.outputFormat(forBus: 0)) else {
            print("AlertManager: Advisory chime format mismatch")
            return
        }

        let note1Freq = 784.0   // G5
        let note2Freq = 587.33  // D5

        // Note 1: G5
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

        // Note 2: D5 (delayed by noteDuration + gap = 0.26s)
        DispatchQueue.main.asyncAfter(deadline: .now() + noteDuration + gap) { [weak self] in
            guard let self,
                  self.ensureEngineRunning(),
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
            self.playerNode.play()
        }

        // Play first note immediately
        playerNode.play()
    }
}
