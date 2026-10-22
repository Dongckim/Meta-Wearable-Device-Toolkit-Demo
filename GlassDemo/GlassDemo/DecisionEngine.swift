//
//  DecisionEngine.swift
//  GlassDemo
//

import QuartzCore

/// 로컬 규칙 판단. 인식 결과가 3프레임 연속 같아야 '바뀐 것'으로 보고 그때 한 번만 판단한다.
nonisolated struct DecisionEngine {
    static let stableFrames = 3
    static let cooldown: CFTimeInterval = 5
    /// "none" = 아무것도 없음. cup은 정답이라 말하지 않는다.
    static let sentences = ["none": "Next is the cup.", "bowl": "That's not it."]

    enum Decision: Equatable {
        case speak(String)
        case silent(String)  // 이유
    }

    private(set) var stable: String?
    private var candidate: String?
    private var streak = 0
    private var lastSentence: String?
    private var lastSpokenAt: CFTimeInterval = -.infinity

    /// 처리된 프레임마다 최상위 라벨(없으면 "none")을 넣는다. 안정 결과가 바뀐 순간에만 판단을 돌려준다.
    mutating func observe(_ label: String, at t: CFTimeInterval) -> Decision? {
        if label == candidate { streak += 1 } else { candidate = label; streak = 1 }
        guard streak >= Self.stableFrames, label != stable else { return nil }
        stable = label

        guard let sentence = Self.sentences[label] else {
            return .silent(label == "cup" ? "correct object" : "no rule for \(label)")
        }
        if sentence == lastSentence { return .silent("same sentence as last time") }
        if t - lastSpokenAt < Self.cooldown { return .silent("cooldown") }
        lastSentence = sentence
        lastSpokenAt = t
        return .speak(sentence)
    }
}
