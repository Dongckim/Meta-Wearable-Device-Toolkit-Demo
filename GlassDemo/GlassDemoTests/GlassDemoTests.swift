//
//  GlassDemoTests.swift
//  GlassDemoTests
//
//  Created by dongchankim on 10/21/26.
//

import CoreGraphics
import Testing
@testable import GlassDemo

struct GlassDemoTests {

    /// 손 점 21개(픽셀). 엄지 끝(4)을 원점에 두고 검지 끝(8)을 angle° 방향 100px에, 나머지 손끝을 spread px에 둔다.
    /// 손 크기(손목 0 → 중지 MCP 9) = 100px이라 쥠 지표 ≈ (100 + 3·spread) / 4 / 100.
    private func hand(angle: Double, spread: Double) -> [CGPoint?] {
        var p = [CGPoint?](repeating: nil, count: 21)
        let a = angle * .pi / 180
        p[0] = CGPoint(x: 0, y: -150)
        p[9] = CGPoint(x: 0, y: -50)
        p[4] = .zero
        p[8] = CGPoint(x: cos(a) * 100, y: sin(a) * 100)
        for tip in [12, 16, 20] { p[tip] = CGPoint(x: spread, y: 0) }
        return p
    }

    // 쥔 값 0.4, 편 값 1.6 → 경계 1.0, 히스테리시스 ±0.18
    private let band = GripCalibration(grippedIndex: 0.4, openIndex: 1.6).band

    @Test func gripNeedsThreeFramesAndHysteresis() {
        var tracker = GripTracker()
        var t = 0.0
        func step(_ spread: Double) -> Bool {
            t += 1.0 / 15
            return tracker.update(points: hand(angle: 0, spread: spread), band: band, at: t).gripped
        }
        #expect(!step(20))  // 지표 0.4: 쥠 후보 1프레임
        #expect(!step(20))
        #expect(step(20))  // 3프레임 연속 → 쥠
        #expect(step(150))  // 지표 1.375(경계+폭 1.18 이상): 폄 후보지만 아직 쥠
        #expect(step(115))  // 지표 1.11: 경계 안쪽 → 상태 유지, 후보 끊김
        #expect(step(150))
        #expect(step(150))
        #expect(!step(150))  // 다시 3프레임 연속 → 폄
    }

    @Test func gripAccumulatesOnlyWhileGripped() {
        var tracker = GripTracker()
        var t = 0.0, angle = 0.0
        func frames(_ n: Int, step: Double, spread: Double) -> GripTracker.Reading {
            var r: GripTracker.Reading!
            for _ in 0..<n {
                angle += step
                t += 1.0 / 15
                r = tracker.update(points: hand(angle: angle, spread: spread), band: band, at: t)
            }
            return r
        }
        _ = frames(3, step: 0, spread: 20)  // 쥠 확정
        let turned = frames(10, step: -5, spread: 20)  // 쥔 채로 -50°
        #expect(abs(turned.accumulated + 50) < 0.1)
        // 펴고 되돌리기 +50°: 누적하지 않고, 펴도 지우지 않는다(폄 확정까지 3프레임은 아직 쥠이라 첫 2스텝은 들어간다)
        let released = frames(10, step: 5, spread: 150)
        #expect(!released.gripped)
        #expect(abs(released.accumulated - (-50 + 10)) < 0.1)
        // 초당 10° 미만은 떨림 → 무시
        _ = frames(3, step: 0, spread: 20)
        let slow = frames(10, step: 0.5, spread: 20)  // 7.5°/s
        #expect(abs(slow.accumulated - (-40)) < 0.1)
        // 한 번 쥔 구간에서 10° 미만만 돌았으면 구간째 버린다
        _ = frames(2, step: 3, spread: 20)  // +6°
        let small = frames(4, step: 0, spread: 150)
        #expect(abs(small.accumulated - (-40)) < 0.1)
    }

    /// 실기기 오경보: 쥔 뒤 손목이 안 잡혀 쥠 지표가 비는 동안, 손을 놓으며 되돌린 각도가 "쥔 채 푼 것"으로 쌓였다.
    @Test func gripDoesNotAccumulateWithoutGripIndex() {
        var tracker = GripTracker()
        var t = 0.0, angle = 0.0
        for _ in 0..<3 {
            t += 1.0 / 15
            _ = tracker.update(points: hand(angle: 0, spread: 20), band: band, at: t)
        }
        var r: GripTracker.Reading!
        for _ in 0..<10 {
            angle += 5
            t += 1.0 / 15
            var p = hand(angle: angle, spread: 20)
            p[0] = nil  // 손목 없음 → 쥠 지표 nil, 각도는 있음
            r = tracker.update(points: p, band: band, at: t)
        }
        #expect(r.gripped)  // 상태는 유지
        #expect(r.accumulated == 0)
    }

    @Test func landmarkSmootherAveragesLastFiveFrames() {
        var smoother = LandmarkSmoother()
        var out: [CGPoint?] = []
        for x in [0.0, 10, 20, 30, 40, 50] { out = smoother.smooth([CGPoint(x: x, y: 0), nil]) }
        #expect(out[0] == CGPoint(x: 30, y: 0))  // 10~50 평균
        #expect(out[1] == nil)
    }

    @Test func wakeWordSplitsCallFromQuestion() {
        #expect(RealtimeCall.parseWake("Hey Illini.") == (true, nil))
        #expect(RealtimeCall.parseWake("hey illinois") == (true, nil))
        #expect(RealtimeCall.parseWake("Hey Illini, what am I doing?") == (true, "what am i doing"))
        #expect(RealtimeCall.parseWake("What am I holding?") == (false, nil))
        #expect(RealtimeCall.parseWake("I went to Illinoisan Street") == (false, nil))
        // 전사기가 잘못 적는 경우
        #expect(RealtimeCall.parseWake("Hey Elini.") == (true, nil))
        #expect(RealtimeCall.parseWake("Hey, Lainey, what is this?") == (true, "what is this"))
        #expect(RealtimeCall.parseWake("hey ill ini") == (true, nil))
        #expect(RealtimeCall.parseWake("Hey Illiny what time is it") == (true, "what time is it"))
        // "hey" 없이 비슷한 단어만 있으면 호출이 아니다
        #expect(RealtimeCall.parseWake("I'm willing to help") == (false, nil))
        #expect(RealtimeCall.parseWake("Elaine is here") == (false, nil))
        #expect(RealtimeCall.editDistance("elini", "illini") == 2)
        #expect(RealtimeCall.editDistance("", "abc") == 3)
    }

    @Test func visionBoxFlipsYAxis() {
        // 좌하단 1/4 영역 → SwiftUI에서는 아래쪽
        let r = viewRect(normalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.25),
                         imageSize: CGSize(width: 100, height: 200), viewSize: CGSize(width: 100, height: 200))
        #expect(r == CGRect(x: 0, y: 150, width: 50, height: 50))
    }

    @Test func visionBoxAccountsForAspectFillCrop() {
        // 504x896 영상을 393x852 화면에 aspect-fill → 세로 기준 스케일, 좌우가 잘림
        let r = viewRect(normalized: CGRect(x: 0.5, y: 0.5, width: 0, height: 0),
                         imageSize: CGSize(width: 504, height: 896), viewSize: CGSize(width: 393, height: 852))
        #expect(abs(r.midX - 393 / 2) < 0.001)
        #expect(abs(r.midY - 852 / 2) < 0.001)
    }

    @Test func coreMLKeepsBestCupAndBowlAboveThreshold() {
        let box = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let kept = CoreMLDetector.keepBest([
            Detection(label: "cup", confidence: 0.5, boundingBox: box),
            Detection(label: "cup", confidence: 0.8, boundingBox: box),
            Detection(label: "bowl", confidence: 0.39, boundingBox: box),  // 0.4 미만
            Detection(label: "person", confidence: 0.99, boundingBox: box),  // 다른 클래스
        ])
        #expect(kept.map(\.label) == ["cup"])
        #expect(kept.first?.confidence == 0.8)
    }

    @Test func decisionNeedsThreeStableFrames() {
        var engine = DecisionEngine()
        #expect(engine.observe("none", at: 0) == nil)
        #expect(engine.observe("none", at: 0.1) == nil)
        #expect(engine.observe("none", at: 0.2) == .speak("Next is the cup."))
        #expect(engine.observe("none", at: 0.3) == nil)  // 같은 결과면 다시 판단하지 않음
    }

    @Test func flickerDoesNotChangeResult() {
        var engine = DecisionEngine()
        for t in [0.0, 0.1, 0.2] { _ = engine.observe("cup", at: t) }
        #expect(engine.observe("bowl", at: 0.3) == nil)
        #expect(engine.observe("bowl", at: 0.4) == nil)
        #expect(engine.observe("cup", at: 0.5) == nil)  // 2프레임 깜빡임 → 무시
        #expect(engine.stable == "cup")
    }

    @Test func cupIsSilentBowlSpeaks() {
        var engine = DecisionEngine()
        for t in [0.0, 0.1] { _ = engine.observe("cup", at: t) }
        #expect(engine.observe("cup", at: 0.2) == .silent("correct object"))
        for t in [0.3, 0.4] { _ = engine.observe("bowl", at: t) }
        #expect(engine.observe("bowl", at: 0.5) == .speak("That's not it."))
    }

    @Test func cooldownAndNoRepeat() {
        var engine = DecisionEngine()
        func settle(_ label: String, at t: Double) -> DecisionEngine.Decision? {
            _ = engine.observe(label, at: t)
            _ = engine.observe(label, at: t + 0.1)
            return engine.observe(label, at: t + 0.2)
        }
        #expect(settle("none", at: 0) == .speak("Next is the cup."))
        #expect(settle("bowl", at: 1) == .silent("cooldown"))  // 5초 안
        #expect(settle("none", at: 10) == .silent("same sentence as last time"))
        #expect(settle("bowl", at: 20) == .speak("That's not it."))
    }

}
