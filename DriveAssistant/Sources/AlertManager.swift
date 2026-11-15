import AVFoundation
import AudioToolbox
import Foundation

final class AlertManager {
    private var lastWarningAlert = Date.distantPast
    private var lastCriticalAlert = Date.distantPast
    private let synthesizer = AVSpeechSynthesizer()

    func playWarningAlert() {
        guard Date().timeIntervalSince(lastWarningAlert) >= 5 else { return }
        lastWarningAlert = Date()
        AudioServicesPlaySystemSound(1052)
    }

    func playCriticalAlert(speak: Bool, reduceSpeed: Bool) {
        guard Date().timeIntervalSince(lastCriticalAlert) >= 3 else { return }
        lastCriticalAlert = Date()
        AudioServicesPlaySystemSound(1005)
        guard speak else { return }
        let utterance = AVSpeechUtterance(string: reduceSpeed ? "Giảm tốc độ" : "Giữ khoảng cách an toàn")
        utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }
}
