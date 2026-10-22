//
//  SpeechPlayer.swift
//  GlassDemo
//

import AVFoundation
import QuartzCore

final class SpeechPlayer: NSObject, AVAudioPlayerDelegate {
    var log: (String) -> Void = { _ in }

    private var player: AVAudioPlayer?
    private var current: (name: String, tap: CFTimeInterval, start: CFTimeInterval, duration: TimeInterval)?

    func play(_ name: String) {
        let tap = CACurrentMediaTime()
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            log("\(name).wav 없음 (번들에 추가 필요)")
            return
        }
        do {
            if let current { log("\(current.name) 중단됨") }
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                log("\(name) play() 실패")
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
            log("\(name) 로드 실패: \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let end = CACurrentMediaTime()
        guard let c = current, player === self.player else { return }
        current = nil
        log(String(format: "%@ end=+%.1fms (start→end %.1fms, dur %.1fms)%@",
                   c.name, (end - c.tap) * 1000, (end - c.start) * 1000, c.duration * 1000,
                   flag ? "" : " 디코드 실패"))
    }
}
