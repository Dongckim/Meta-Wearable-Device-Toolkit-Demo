//
//  GripTracker.swift
//  GlassDemo
//
//  손 추적만으로 뚜껑 돌리는 방향을 판정한다(마커 없음).
//  쥔 상태에서만 엄지→검지 선의 각도 변화를 누적하므로, 손을 펴고 되돌리는 동작은 세지 않는다.
//  쥠 경계와 조이는 방향은 보정 화면에서 사람마다 잰다(GripCalibration, UserDefaults).
//

import CoreGraphics
import Foundation

/// 최근 length프레임 이동평균. 관절마다 보인 프레임만 평균한다.
nonisolated struct LandmarkSmoother {
    var length = 5
    private var history: [[CGPoint?]] = []

    mutating func reset() {
        history = []
    }

    mutating func smooth(_ points: [CGPoint?]) -> [CGPoint?] {
        history = Array((history + [points]).suffix(length))
        return points.indices.map { j in
            let seen = history.compactMap { $0[j] }
            guard !seen.isEmpty else { return nil }
            let n = CGFloat(seen.count)
            return CGPoint(x: seen.reduce(0) { $0 + $1.x } / n, y: seen.reduce(0) { $0 + $1.y } / n)
        }
    }
}

/// 보정값. 쥠 경계 = 쥔 값과 편 값의 중간, 히스테리시스 폭 = 두 값 차이의 15%.
nonisolated struct GripCalibration: Codable, Equatable {
    var grippedIndex: Double?
    var openIndex: Double?
    /// +1 = 조이는 방향에서 각도가 커진다, -1 = 작아진다
    var tightenSign: Double?

    static let hysteresisRatio = 0.15
    private static let key = "gripCalibration.palm"  // 쥠 지표 단위가 바뀌어(손목 기준 → 손바닥 폭) 예전 값은 버린다

    var band: (boundary: Double, margin: Double)? {
        guard let grippedIndex, let openIndex, openIndex > grippedIndex else { return nil }
        return ((grippedIndex + openIndex) / 2, (openIndex - grippedIndex) * Self.hysteresisRatio)
    }

    static func load() -> GripCalibration {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? GripCalibration()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

nonisolated struct GripTracker {
    struct Reading {
        let gripIndex: Double?
        let gripped: Bool
        let angle: Double?  // 엄지→검지 선, 도(y 위 좌표). 평균 전 점
        let angularVelocity: Double?  // 도/초
        let accumulated: Double  // 확정된 쥠 구간 합 + 지금 쥔 구간
    }

    var minSpeed = 10.0  // 도/초. 이보다 느린 변화는 떨림
    var maxSpeed = 800.0  // 도/초. 이보다 빠르면 엄지·검지 점이 튄 것(실기기 실제 회전은 ~650까지, 튄 값은 1700~3400)
    var minSegment = 10.0  // 도. 한 번 쥔 구간에서 이보다 적게 돌았으면 통째로 버린다
    var confirmFrames = 3  // 쥠/폄이 바뀌려면 이만큼 연속 같은 판정

    private(set) var gripped = false
    private var pending: Bool?
    private var pendingCount = 0
    private var lastAngle: Double?
    private var lastTime: Double = 0
    private var total = 0.0  // 끝난 쥠 구간들의 합
    private var segment = 0.0  // 지금 쥔 구간
    var accumulated: Double { total + segment }

    /// 손 크기 = 손바닥 폭(검지 MCP → 약지 MCP). 쥠 지표 = 엄지 끝과 나머지 네 손가락 끝 거리의 평균 / 손 크기.
    /// 손목 → 중지 MCP였을 때는 뚜껑을 쥐면 손목이 화면 밖이라(쥔 프레임의 15%만 보임) 지표가 거의 안 나왔다.
    /// 점은 픽셀 단위(정규화 좌표는 가로세로 비율이 달라 거리가 찌그러진다).
    static func gripIndex(_ p: [CGPoint?]) -> Double? {
        guard let thumb = p[4], let indexMCP = p[5], let ringMCP = p[13] else { return nil }
        let size = hypot(ringMCP.x - indexMCP.x, ringMCP.y - indexMCP.y)
        let tips = [8, 12, 16, 20].compactMap { p[$0] }
        guard size > 1, tips.count >= 2 else { return nil }
        return tips.map { Double(hypot($0.x - thumb.x, $0.y - thumb.y)) }.reduce(0, +) / Double(tips.count) / Double(size)
    }

    /// 뚜껑은 손바닥이 아니라 손끝으로 굴려 돌린다 → 손 전체 회전(Kabsch)은 거의 안 움직이고 이 선이 돈다(실기기 비교).
    static func angle(_ p: [CGPoint?]) -> Double? {
        guard let thumb = p[4], let index = p[8] else { return nil }
        return atan2(index.y - thumb.y, index.x - thumb.x) * 180 / .pi
    }

    /// points: 이동평균한 점(쥠 지표용). raw: 평균 전 점(회전용 — 평균하면 한 번 튄 점이 여러 프레임의 가짜 회전으로 퍼진다).
    /// band가 없으면(보정 전) 쥠 판정을 하지 않는다 → 누적도 없다.
    mutating func update(points p: [CGPoint?], raw: [CGPoint?], band: (boundary: Double, margin: Double)?, at t: Double) -> Reading {
        let index = Self.gripIndex(p)
        if let index, let band {
            // 경계 ± margin 안쪽에서는 지금 상태를 유지한다(히스테리시스)
            let wanted = index < band.boundary - band.margin ? true : index > band.boundary + band.margin ? false : gripped
            if wanted == gripped {
                pending = nil
                pendingCount = 0
            } else {
                pendingCount = pending == wanted ? pendingCount + 1 : 1
                pending = wanted
                if pendingCount >= confirmFrames { setGripped(wanted) }
            }
        }

        let angle = Self.angle(raw)
        var velocity: Double?
        if let angle, let lastAngle, t > lastTime {
            var d = angle - lastAngle
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            let v = d / (t - lastTime)
            velocity = v
            // 쥠을 확인 못 한 프레임과 튄 프레임은 세지 않는다
            if gripped, index != nil, abs(v) >= minSpeed, abs(v) <= maxSpeed { segment += d }
        }
        if let angle {
            lastAngle = angle
            lastTime = t
        }
        return Reading(gripIndex: index, gripped: gripped, angle: angle, angularVelocity: velocity, accumulated: accumulated)
    }

    private mutating func setGripped(_ value: Bool) {
        if gripped, !value {
            // 쥠 구간 끝: 충분히 돌았으면 확정, 아니면 잡음으로 버린다. 편 상태로 바뀌어도 누적값은 유지(뚜껑은 제자리)
            if abs(segment) >= minSegment { total += segment }
            segment = 0
        }
        gripped = value
        pending = nil
        pendingCount = 0
    }

    /// 경고 후, 보정의 회전 단계 시작 때.
    mutating func clearAccumulation() {
        total = 0
        segment = 0
    }

    /// 손이 화면에서 사라졌을 때.
    mutating func reset() {
        self = GripTracker(minSpeed: minSpeed, maxSpeed: maxSpeed, minSegment: minSegment, confirmFrames: confirmFrames)
    }
}

/// 판정된 돌리는 방향(누적 25° 초과 시).
nonisolated enum TurnState: String {
    case none = "–"
    case tightening = "Tightening"
    case loosening = "Loosening"
}

/// 보정 한 단계 진행 상태.
nonisolated struct CalibrationRun {
    enum Step: String, CaseIterable {
        case grip = "Hold the cap gripped (3 s)"
        // 활짝 편 손으로 재면 경계가 너무 높아져, 다시 쥐려고 살짝 뗀 손도 "쥠"으로 남는다(replay에서 오경보)
        case open = "Lift your fingers off the cap, as when re-gripping (3 s)"
        case turn = "Turn one full round, tightening"
    }

    let step: Step
    var started: Double?
    var samples: [Double] = []
    var progress = 0.0  // 0...1
}
