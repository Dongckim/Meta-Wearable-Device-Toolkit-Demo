//
//  CameraModel.swift
//  GlassDemo
//

import CoreGraphics
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import QuartzCore
import UIKit

/// Vision 정규화 좌표 → aspect-fill로 그린 이미지 위의 SwiftUI 좌표(좌상단 원점).
func viewRect(normalized r: CGRect, imageSize: CGSize, viewSize: CGSize) -> CGRect {
    let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    let w = imageSize.width * scale
    let h = imageSize.height * scale
    let ox = (viewSize.width - w) / 2
    let oy = (viewSize.height - h) / 2
    return CGRect(x: ox + r.minX * w, y: oy + (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
}

enum DetectorKind: String {
    case coreML = "CoreML"
    case qr = "QR"
}

@Observable
final class CameraModel {
    var image: UIImage?
    var results: [Detection] = []
    var fps = 0
    var latencyMs: Double?
    var isRunning = false
    var detectorKind = DetectorKind.coreML
    var stableLabel: String?  // nil = 아직 안정된 결과 없음, "none" = 아무것도 없음
    var stableConfidence: Float?
    var decision: DecisionEngine.Decision?
    var isSpeaking = false

    var log: (String) -> Void = { _ in }
    var speak: (String) -> Void = { _ in }

    @ObservationIgnored private var engine = DecisionEngine()
    @ObservationIgnored private let coreML: CoreMLDetector? = try? CoreMLDetector()
    @ObservationIgnored private lazy var processor = FrameProcessor(model: self, detector: detector(for: detectorKind))
    private var session: DeviceSession?
    private var camera: Camera?
    // 리스너가 self를 강하게 잡는다. stop()에서 tokens를 비워 순환을 끊는다.
    private var tokens = ListenerTokenBag()

    /// Meta AI 앱으로 갔다가 onOpenURL로 돌아오는 흐름이라, 스트림을 열기 전에 호출한다.
    func ensurePermission() async -> Bool {
        do {
            var status = try await Wearables.shared.checkPermissionStatus(.camera)
            if status != .granted {
                status = try await Wearables.shared.requestPermission(.camera)
                report("requestPermission → \(status)")
            }
            return status == .granted
        } catch {
            report("Camera permission failed: \(error)")
            return false
        }
    }

    func start() async {
        if coreML == nil { report("YOLO model failed to load — using QR") }
        do {
            // AutoDeviceSelector는 생성 직후 activeDevice가 nil이라 noEligibleDevice가 난다. 연결된 기기를 직접 지정.
            guard let deviceId = Wearables.shared.devices.first(where: {
                Wearables.shared.deviceForIdentifier($0)?.linkState == .connected
            }) else { return report("No connected glasses (devices=\(Wearables.shared.devices.count))") }
            let session = try Wearables.shared.createSession(deviceSelector: SpecificDeviceSelector(device: deviceId))
            self.session = session
            isRunning = true
            // publisher는 replay하지 않으므로 start() 전에 등록
            session.statePublisher.listen { state in
                Task { @MainActor in self.sessionChanged(state) }
            }.store(in: tokens)
            session.errorPublisher.listen { error in
                Task { @MainActor in self.report("session error: \(error)") }
            }.store(in: tokens)
            try session.start()
            MetricsCSV.shared.row("demo_start", t: CACurrentMediaTime(), detector: processor.detectorName)
        } catch {
            report("Camera start failed: \(error)")
            stop()
        }
    }

    func stop() {
        camera?.stream.stop()
        session?.stop()
        tokens.clear()
        tokens = ListenerTokenBag()
        camera = nil
        session = nil
        isRunning = false
        image = nil
        results = []
        fps = 0
        MetricsCSV.shared.row("demo_stop", t: CACurrentMediaTime())
    }

    func reset() {
        engine = DecisionEngine()
        stableLabel = nil
        stableConfidence = nil
        decision = nil
        results = []
        MetricsCSV.shared.row("reset", t: CACurrentMediaTime())
        report("reset")
    }

    func toggleDetector() {
        detectorKind = detectorKind == .coreML ? .qr : .coreML
        processor.setDetector(detector(for: detectorKind))
        reset()  // 다른 인식기의 결과로 이어서 판단하지 않는다
        report("detector → \(processor.detectorName)")
    }

    private func detector(for kind: DetectorKind) -> any Detector {
        if kind == .coreML, let coreML { return coreML }
        return QRDetector()
    }

    private func sessionChanged(_ state: DeviceSessionState) {
        report("session: \(state)")
        switch state {
        case .started:
            guard camera == nil, let session else { return }  // pause 후 다시 started가 와도 한 번만
            do {
                let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)
                guard let camera = try session.addCamera(config: config) else {
                    return report("addCamera → nil")
                }
                self.camera = camera
                let stream = camera.stream
                let processor = processor
                stream.statePublisher.listen { state in
                    Task { @MainActor in self.report("stream: \(state)") }
                }.store(in: tokens)
                stream.errorPublisher.listen { error in
                    Task { @MainActor in self.report("stream error: \(error)") }
                }.store(in: tokens)
                stream.videoFramePublisher.listen { frame in
                    processor.onFrame(frame)
                }.store(in: tokens)
                stream.start()
            } catch {
                report("addCamera failed: \(error)")
            }
        case .stopped:
            camera = nil
        default:
            break
        }
    }

    /// arrived = 이 결과를 만든 프레임의 도착 시각.
    func didDetect(_ detections: [Detection], detector: String, arrived: CFTimeInterval, latencyMs: Double) {
        results = detections
        self.latencyMs = latencyMs
        let top = detections.max { $0.confidence < $1.confidence }
        let label = top?.label ?? "none"
        if label == stableLabel { stableConfidence = top?.confidence }

        let now = CACurrentMediaTime()
        guard let decision = engine.observe(label, at: now) else { return }
        stableLabel = label
        stableConfidence = top?.confidence
        self.decision = decision

        let detail: String
        switch decision {
        case .speak(let sentence): detail = "speak: \(sentence)"
        case .silent(let reason): detail = "silent: \(reason)"
        }
        MetricsCSV.shared.row("decision", t: now, detector: detector, label: label, confidence: top?.confidence,
                              latencyMs: (now - arrived) * 1000, detail: detail)
        report("\(label) → \(detail)")
        if case .speak(let sentence) = decision { speak(sentence) }
    }

    func report(_ text: String) {
        log(text)
    }
}

/// SDK 콜백 스레드에서 프레임을 받아 직렬 큐에서 인식. 어떤 Detector인지는 모른다.
nonisolated final class FrameProcessor: @unchecked Sendable {
    private weak var model: CameraModel?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "GlassDemo.detector")
    private var busy = false
    private var arrivals: [CFTimeInterval] = []
    private var detector: any Detector

    init(model: CameraModel, detector: any Detector) {
        self.model = model
        self.detector = detector
    }

    var detectorName: String { lock.withLock { detector.name } }

    func setDetector(_ detector: any Detector) {
        lock.withLock { self.detector = detector }
    }

    func onFrame(_ frame: VideoFrame) {
        let arrived = CACurrentMediaTime()
        let (fps, skip, detector) = lock.withLock {
            arrivals.append(arrived)
            arrivals.removeAll { $0 < arrived - 1 }
            let skip = busy
            busy = true
            return (arrivals.count, skip, self.detector)
        }

        let image = frame.makeUIImage()
        Task { @MainActor [weak model] in
            model?.image = image
            model?.fps = fps
        }
        guard !skip else { return }  // 이전 인식이 안 끝났으면 이 프레임은 건너뛴다

        queue.async { [self] in
            let detections: [Detection]
            let failure: Error?
            do { detections = try detector.detect(frame.sampleBuffer); failure = nil } catch { detections = []; failure = error }
            let done = CACurrentMediaTime()
            lock.withLock { busy = false }

            let latency = (done - arrived) * 1000
            let top = detections.max { $0.confidence < $1.confidence }
            MetricsCSV.shared.row("frame", t: arrived, detector: detector.name, label: top?.label ?? "none",
                                  confidence: top?.confidence, fps: fps, latencyMs: latency,
                                  detail: detections.map { String(format: "%@:%.2f", $0.label, $0.confidence) }.joined(separator: ";"))
            Task { @MainActor [weak model, failure] in
                model?.didDetect(detections, detector: detector.name, arrived: arrived, latencyMs: latency)
                if let failure { model?.report("\(detector.name) failed: \(failure)") }
            }
        }
    }
}

/// Documents/metrics.csv 에 측정값을 계속 추가 (파일 앱에서 꺼낼 수 있음). 시각은 모두 CACurrentMediaTime() ms.
nonisolated final class MetricsCSV: @unchecked Sendable {
    static let shared = MetricsCSV()
    private let handle: FileHandle?
    private let lock = NSLock()

    private static let header = "t_ms,event,detector,label,confidence,fps,latency_ms,detail\n"

    init() {
        let fm = FileManager.default
        let url = URL.documentsDirectory.appending(path: "metrics.csv")
        // 열 구성이 바뀐 이전 파일은 지우지 않고 옆으로 옮긴다
        if let old = try? String(contentsOf: url, encoding: .utf8), !old.hasPrefix(Self.header) {
            try? fm.moveItem(at: url, to: URL.documentsDirectory.appending(path: "metrics-old-\(Int(Date().timeIntervalSince1970)).csv"))
        }
        if !fm.fileExists(atPath: url.path()) {
            fm.createFile(atPath: url.path(), contents: Data(Self.header.utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// event: frame / decision / speech_request(발화 예약) / speech_start(실제 재생) / speech_end / demo_start / demo_stop / reset
    func row(_ event: String, t: CFTimeInterval, detector: String = "", label: String = "", confidence: Float? = nil,
             fps: Int? = nil, latencyMs: Double? = nil, detail: String = "") {
        let fields = [
            String(format: "%.1f", t * 1000),
            event,
            detector,
            quoted(label),
            confidence.map { String(format: "%.3f", $0) } ?? "",
            fps.map(String.init) ?? "",
            latencyMs.map { String(format: "%.1f", $0) } ?? "",
            quoted(detail),
        ]
        let line = fields.joined(separator: ",") + "\n"
        lock.withLock { try? handle?.write(contentsOf: Data(line.utf8)) }
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
