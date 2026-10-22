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
