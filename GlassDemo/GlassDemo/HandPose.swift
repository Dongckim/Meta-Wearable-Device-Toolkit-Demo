//
//  HandPose.swift
//  GlassDemo
//
//  손 관절 인식(Vision). 쥠·회전 판정은 GripTracker.swift.
//

import CoreGraphics
import CoreMedia
import QuartzCore
import Vision

nonisolated struct HandPose: Sendable {
    typealias Joint = VNHumanHandPoseObservation.JointName

    /// points의 순서. 손목 → 엄지 → 검지 → 중지 → 약지 → 새끼, 각 손가락은 뿌리 → 끝.
    static let joints: [Joint] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    static let tips = [4, 8, 12, 16, 20]
    /// 그릴 뼈대(joints 인덱스 쌍): 손가락마다 손목에서 끝까지 + 손바닥 가로줄.
    static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (0, 9), (9, 10), (10, 11), (11, 12),
        (0, 13), (13, 14), (14, 15), (15, 16),
        (0, 17), (17, 18), (18, 19), (19, 20),
        (5, 9), (9, 13), (13, 17),
    ]

    let points: [CGPoint?]  // Vision 정규화 좌표(좌하단 원점). 신뢰도가 낮은 관절은 nil
    let isRight: Bool?  // Vision의 chirality. 1인칭 시점에서 맞는지는 아직 미확인

    subscript(_ joint: Joint) -> CGPoint? {
        Self.joints.firstIndex(of: joint).flatMap { points[$0] }
    }
}

/// FrameProcessor의 직렬 큐에서만 호출된다.
nonisolated final class HandPoseDetector: @unchecked Sendable {
    static let minJointConfidence: Float = 0.3

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2  // 병 잡는 손 + 돌리는 손
        return request
    }()

    func detect(_ frame: CMSampleBuffer) throws -> [HandPose] {
        try VNImageRequestHandler(cmSampleBuffer: frame, orientation: .up).perform([request])
        return (request.results ?? []).map { observation in
            let recognized = try? observation.recognizedPoints(.all)
            let points = HandPose.joints.map { joint -> CGPoint? in
                guard let p = recognized?[joint], p.confidence > Self.minJointConfidence else { return nil }
                return p.location
            }
            let isRight: Bool? = switch observation.chirality {
            case .right: true
            case .left: false
            default: nil
            }
            return HandPose(points: points, isRight: isRight)
        }
    }
}
