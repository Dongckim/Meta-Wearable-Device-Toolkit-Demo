//
//  GripTracker.swift
//  GlassDemo
//
//  손 추적만으로 뚜껑 돌리는 방향을 판정한다(마커 없음).
//  쥔 상태에서만 손 관절 전체의 회전을 누적하므로, 손을 펴고 되돌리는 동작은 세지 않는다.
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
    private static let key = "gripCalibration"

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
        let angle: Double?  // 엄지→검지 선, 도(y 위 좌표). 표시용
        let angularVelocity: Double?  // 도/초. 이전 프레임과 같이 보인 관절 전체의 회전(rotation)
        let accumulated: Double  // 확정된 쥠 구간 합 + 지금 쥔 구간
    }

    var minSpeed = 10.0  // 도/초. 이보다 느린 변화는 떨림
    var maxSpeed = 800.0  // 도/초. 이보다 빠르면 관절이 튄 것(실기기 실제 회전은 ~650까지)
    /// 한 프레임 쥠 지표 변화가 이보다 크면 손 모양이 바뀌는 중 → 회전을 세지 않는다.
    /// 손을 펴기만 해도 관절 회전이 -27°쯤 나온다. 실기기에서 쥔 채 돌릴 때는 ±0.03, 놓을 때 0.06~0.15
    var maxShapeChange = 0.05
    var minSegment = 10.0  // 도. 한 번 쥔 구간에서 이보다 적게 돌았으면 통째로 버린다
    var confirmFrames = 3  // 쥠/폄이 바뀌려면 이만큼 연속 같은 판정

    private(set) var gripped = false
    private var pending: Bool?
    private var pendingCount = 0
    private var lastRaw: [CGPoint?]?
    private var lastShape: Double?  // lastRaw의 쥠 지표
    private var lastTime: Double = 0
    private var total = 0.0  // 끝난 쥠 구간들의 합
    private var segment = 0.0  // 지금 쥔 구간
    var accumulated: Double { total + segment }

    /// 손 크기 = 손목 → 중지 MCP. 쥠 지표 = 엄지 끝과 나머지 네 손가락 끝 거리의 평균 / 손 크기.
    /// 점은 픽셀 단위(정규화 좌표는 가로세로 비율이 달라 거리가 찌그러진다).
    static func gripIndex(_ p: [CGPoint?]) -> Double? {
        guard let thumb = p[4], let wrist = p[0], let middleMCP = p[9] else { return nil }
        let size = hypot(middleMCP.x - wrist.x, middleMCP.y - wrist.y)
        let tips = [8, 12, 16, 20].compactMap { p[$0] }
        guard size > 1, tips.count >= 2 else { return nil }
        return tips.map { Double(hypot($0.x - thumb.x, $0.y - thumb.y)) }.reduce(0, +) / Double(tips.count) / Double(size)
    }

    static func angle(_ p: [CGPoint?]) -> Double? {
        guard let thumb = p[4], let index = p[8] else { return nil }
        return atan2(index.y - thumb.y, index.x - thumb.x) * 180 / .pi
    }

    /// a → b 회전각(도, 반시계 +). 둘 다 보인 관절이 4개 이상일 때만. 2D Kabsch: 중심을 빼고 Σ외적, Σ내적의 atan2.
    /// 점 하나가 튀거나 엄지·검지가 뒤바뀌어도 나머지 관절이 잡아 준다(두 점 선은 한 프레임에 180° 뒤집혔다).
    static func rotation(from a: [CGPoint?], to b: [CGPoint?]) -> Double? {
        let pairs = zip(a, b).compactMap { p, q in p.flatMap { p in q.map { (p, $0) } } }
        guard pairs.count >= 4 else { return nil }
        let n = CGFloat(pairs.count)
        let ca = CGPoint(x: pairs.reduce(0) { $0 + $1.0.x } / n, y: pairs.reduce(0) { $0 + $1.0.y } / n)
        let cb = CGPoint(x: pairs.reduce(0) { $0 + $1.1.x } / n, y: pairs.reduce(0) { $0 + $1.1.y } / n)
        var cross = 0.0, dot = 0.0
        for (p, q) in pairs {
            let (ax, ay, bx, by) = (p.x - ca.x, p.y - ca.y, q.x - cb.x, q.y - cb.y)
            cross += ax * by - ay * bx
            dot += ax * bx + ay * by
        }
        return atan2(cross, dot) * 180 / .pi
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

        let shape = Self.gripIndex(raw)
        var velocity: Double?
        if let lastRaw, t > lastTime, let d = Self.rotation(from: lastRaw, to: raw) {
            let v = d / (t - lastTime)
            velocity = v
            let reshaping = shape.flatMap { s in lastShape.map { abs(s - $0) > maxShapeChange } } ?? false
            // 쥠을 확인 못 한 프레임(손목 안 보임 등), 튄 프레임, 손 모양이 바뀌는 프레임은 세지 않는다
            if gripped, index != nil, !reshaping, abs(v) >= minSpeed, abs(v) <= maxSpeed { segment += d }
        }
        if raw.compactMap({ $0 }).count >= 4 {
            lastRaw = raw
            lastShape = shape
            lastTime = t
        }
        return Reading(gripIndex: index, gripped: gripped, angle: Self.angle(p), angularVelocity: velocity, accumulated: accumulated)
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
        self = GripTracker(minSpeed: minSpeed, maxSpeed: maxSpeed, maxShapeChange: maxShapeChange, minSegment: minSegment, confirmFrames: confirmFrames)
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
        case open = "Hold your hand open (3 s)"
        case turn = "Turn one full round, tightening"
    }

    let step: Step
    var started: Double?
    var samples: [Double] = []
    var progress = 0.0  // 0...1
}
