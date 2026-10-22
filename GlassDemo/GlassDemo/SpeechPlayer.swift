//
//  SpeechPlayer.swift
//  GlassDemo
//

import AVFoundation
import QuartzCore

final class SpeechPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    var log: (String) -> Void = { _ in }
    var onSpeaking: (Bool) -> Void = { _ in }

    // 규칙 판단 문장을 영어로 읽는다. 기본값(usesApplicationAudioSession)이라 .playback 세션 → A2DP로 나간다.
    // 아래 play()(5단계 wav 재생)와는 별개.
    private let synthesizer = AVSpeechSynthesizer()
    private var speechRequested: [ObjectIdentifier: CFTimeInterval] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let t = CACurrentMediaTime()
        speechRequested[ObjectIdentifier(utterance)] = t
        MetricsCSV.shared.row("speech_request", t: t, detail: text)
        log("speak: \(text)")
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        speechEvent("speech_start", utterance)
        onSpeaking(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speechEvent("speech_end", utterance)
        speechRequested[ObjectIdentifier(utterance)] = nil
        onSpeaking(false)
    }

    // 소리가 귀에 닿는 시각은 여기에 outputLatency만큼 더 늦다
    private func speechEvent(_ name: String, _ utterance: AVSpeechUtterance) {
        let t = CACurrentMediaTime()
        let since = speechRequested[ObjectIdentifier(utterance)].map { (t - $0) * 1000 }
        MetricsCSV.shared.row(name, t: t, latencyMs: since,
                              detail: String(format: "%@ outLat=%.1fms", utterance.speechString, AVAudioSession.sharedInstance().outputLatency * 1000))
        log(String(format: "%@ +%.1fms", name, since ?? -1))
    }

    private var player: AVAudioPlayer?
    private var current: (name: String, tap: CFTimeInterval, start: CFTimeInterval, duration: TimeInterval)?

    func play(_ name: String) {
        let tap = CACurrentMediaTime()
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            log("\(name).wav missing (add it to the bundle)")
            return
        }
        do {
            if let current { log("\(current.name) interrupted") }
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                log("\(name) play() failed")
                return
            }
            // play() 반환 시각. 실제 소리는 outputLatency(A2DP는 수백 ms)만큼 뒤에 난다.
            let start = CACurrentMediaTime()
            self.player = player
            current = (name, tap, start, player.duration)
            log(String(format: "%@ tap=%.1f start=+%.1fms dur=%.1fms outLat=%.1fms",
                       name, tap * 1000, (start - tap) * 1000, player.duration * 1000,
                       AVAudioSession.sharedInstance().outputLatency * 1000))
        } catch {
            log("\(name) load failed: \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let end = CACurrentMediaTime()
        guard let c = current, player === self.player else { return }
        current = nil
        log(String(format: "%@ end=+%.1fms (start→end %.1fms, dur %.1fms)%@",
                   c.name, (end - c.tap) * 1000, (end - c.start) * 1000, c.duration * 1000,
                   flag ? "" : " decode failed"))
    }
}
