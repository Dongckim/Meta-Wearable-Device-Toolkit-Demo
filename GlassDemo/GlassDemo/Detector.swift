//
//  Detector.swift
//  GlassDemo
//

import CoreGraphics
import CoreMedia
import CoreML
import Foundation
import Vision

struct Detection: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect  // Vision 정규화 좌표 (좌하단 원점)
}

/// 프레임 → 인식 결과. FrameProcessor의 직렬 큐에서만 호출된다.
nonisolated protocol Detector: Sendable {
    var name: String { get }
    func detect(_ frame: CMSampleBuffer) throws -> [Detection]
}

/// 모델이 말을 안 들을 때 돌아갈 자리. QR 페이로드를 "cup"/"bowl"로 인쇄하면 같은 규칙으로 돈다.
nonisolated struct QRDetector: Detector {
    let name = "QR"

    func detect(_ frame: CMSampleBuffer) throws -> [Detection] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cmSampleBuffer: frame, orientation: .up).perform([request])
        return (request.results ?? []).map {
            Detection(label: $0.payloadStringValue ?? "?", confidence: $0.confidence, boundingBox: $0.boundingBox)
        }
    }
}

nonisolated final class CoreMLDetector: Detector, @unchecked Sendable {
    let name = "CoreML"
    static let labels: Set = ["cup", "bowl"]
    static let minConfidence: Float = 0.4

    struct ModelMissing: Error {}

    private let request: VNCoreMLRequest  // 직렬 큐에서만 쓰므로 프레임마다 재사용

    init() throws {
        // Xcode가 yolo11n.mlpackage를 빌드 시 yolo11n.mlmodelc로 컴파일해 번들에 넣는다
        guard let url = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc") else { throw ModelMissing() }
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: url)))
        // 504x896 → 640x640: 박스 위치는 두 옵션 모두 같지만, .scaleFill은 컵을 눌러 bowl로 오인한다
        // (맥에서 같은 프레임: .scaleFit cup 0.93 / .scaleFill bowl 0.40)
        request.imageCropAndScaleOption = .scaleFit
    }

    func detect(_ frame: CMSampleBuffer) throws -> [Detection] {
        try VNImageRequestHandler(cmSampleBuffer: frame, orientation: .up).perform([request])
        let all = (request.results ?? []).compactMap { $0 as? VNRecognizedObjectObservation }.map {
            // labels[].confidence는 클래스 분포라 거의 1.0. 실제 검출 점수는 observation.confidence
            Detection(label: $0.labels.first?.identifier ?? "", confidence: $0.confidence, boundingBox: $0.boundingBox)
        }
        return Self.keepBest(all)
    }

    /// cup/bowl만, 0.4 이상만, 클래스마다 가장 높은 하나만.
    static func keepBest(_ detections: [Detection]) -> [Detection] {
        Dictionary(grouping: detections.filter { labels.contains($0.label) && $0.confidence >= minConfidence }, by: \.label)
            .compactMap { $0.value.max { $0.confidence < $1.confidence } }
            .sorted { $0.confidence > $1.confidence }
    }
}
