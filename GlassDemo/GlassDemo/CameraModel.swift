//
//  CameraModel.swift
//  GlassDemo
//

import CoreGraphics
import CoreML
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import QuartzCore
import UIKit
import Vision

struct Detection: Identifiable {
    let id = UUID()
    let isQR: Bool
    let value: String  // QR 페이로드 또는 YOLO 라벨
    let confidence: Float
    let box: CGRect  // Vision 정규화 좌표 (좌하단 원점)
}

/// Vision 정규화 좌표 → aspect-fill로 그린 이미지 위의 SwiftUI 좌표(좌상단 원점).
func viewRect(normalized r: CGRect, imageSize: CGSize, viewSize: CGSize) -> CGRect {
    let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    let w = imageSize.width * scale
    let h = imageSize.height * scale
    let ox = (viewSize.width - w) / 2
    let oy = (viewSize.height - h) / 2
    return CGRect(x: ox + r.minX * w, y: oy + (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
}

@Observable
final class CameraModel {
    var image: UIImage?
    var results: [Detection] = []
    var fps = 0
    var latencyMs: Double?
    var messages: [String] = []
    var isRunning = false

    var log: (String) -> Void = { _ in }

    private var session: DeviceSession?
    private var camera: Camera?
    // 리스너가 self를 강하게 잡는다. stop()에서 tokens를 비워 순환을 끊는다.
    private var tokens = ListenerTokenBag()
    @ObservationIgnored private lazy var processor = FrameProcessor(model: self)

    /// Meta AI 앱으로 갔다가 onOpenURL로 돌아오는 흐름이라, 카메라 화면을 띄우기 전에 호출한다.
    func ensurePermission() async -> Bool {
        do {
            var status = try await Wearables.shared.checkPermissionStatus(.camera)
            report("camera permission: \(status)")
            if status != .granted {
                status = try await Wearables.shared.requestPermission(.camera)
                report("requestPermission → \(status)")
            }
            return status == .granted
        } catch {
            report("카메라 권한 실패: \(error) / \(error.localizedDescription)")
            return false
        }
    }

    func start() async {
        do {
            // AutoDeviceSelector는 생성 직후 activeDevice가 nil이라 noEligibleDevice가 난다. 연결된 기기를 직접 지정.
            guard let deviceId = Wearables.shared.devices.first(where: {
                Wearables.shared.deviceForIdentifier($0)?.linkState == .connected
            }) else { return report("연결된 글래스 없음 (devices=\(Wearables.shared.devices.count))") }
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
        } catch {
            report("카메라 시작 실패: \(error) / \(error.localizedDescription)")
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
                report("addCamera 실패: \(error)")
            }
        case .stopped:
            camera = nil
        default:
            break
        }
    }

    func report(_ text: String) {
        messages = Array((messages + [text]).suffix(8))
        log(text)
    }
}

/// SDK 콜백 스레드에서 프레임을 받아 Vision 큐에서 QR + YOLO 인식. MainActor 밖에서 동작.
nonisolated final class FrameProcessor: @unchecked Sendable {
    private weak var model: CameraModel?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "GlassDemo.vision")
    private var busy = false
    private var arrivals: [CFTimeInterval] = []
    private var loggedSize = false
    private let csv = MetricsCSV()
    private let yolo: VNCoreMLRequest?
    private static let yoloLabels: Set = ["cup"]

    init(model: CameraModel) {
        self.model = model
        // Xcode가 yolo11n.mlpackage를 빌드 시 yolo11n.mlmodelc로 컴파일해 번들에 넣는다
        yolo = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc")
            .flatMap { try? MLModel(contentsOf: $0) }
            .flatMap { try? VNCoreMLModel(for: $0) }
            .map {
                let r = VNCoreMLRequest(model: $0)
                r.imageCropAndScaleOption = .scaleFit  // 잘라내지 않고 여백 → 박스 좌표가 원본 기준
                return r
            }
        if yolo == nil {
            Task { @MainActor [weak model] in model?.report("YOLO 모델 로드 실패 — QR만 인식") }
        }
    }

    func onFrame(_ frame: VideoFrame) {
        let arrived = CACurrentMediaTime()
        let (fps, skip, firstFrame) = lock.withLock {
            arrivals.append(arrived)
            arrivals.removeAll { $0 < arrived - 1 }
            let skip = busy
            busy = true
            defer { loggedSize = true }
            return (arrivals.count, skip, !loggedSize)
        }

        let image = frame.makeUIImage()
        Task { @MainActor [weak model] in
            model?.image = image
            model?.fps = fps
            if firstFrame, let image, let pb = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
                model?.report("첫 프레임 buffer \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)), UIImage \(image.size) orient=\(image.imageOrientation.rawValue)")
            }
        }
        guard !skip else { return }

        queue.async { [self] in
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cmSampleBuffer: frame.sampleBuffer, orientation: .up)
            var error: Error?
            // QR과 YOLO를 따로 재서 어느 쪽이 지연을 만드는지 CSV에서 구분
            let qrStart = CACurrentMediaTime()
            do { try handler.perform([request]) } catch let e { error = e }
            let qrDone = CACurrentMediaTime()
            if let yolo {
                do { try handler.perform([yolo]) } catch let e { error = e }
            }
            let done = CACurrentMediaTime()
            lock.withLock { busy = false }

            let qr = (request.results ?? []).map {
                Detection(isQR: true, value: $0.payloadStringValue ?? "?", confidence: $0.confidence, box: $0.boundingBox)
            }
            let objects = (yolo?.results ?? []).compactMap { $0 as? VNRecognizedObjectObservation }
                .filter { Self.yoloLabels.contains($0.labels.first?.identifier ?? "") }
                // labels[].confidence는 클래스 분포라 거의 1.0. 실제 검출 점수는 observation.confidence
                .map { Detection(isQR: false, value: $0.labels[0].identifier, confidence: $0.confidence, box: $0.boundingBox) }
            let results = qr + objects
            let latency = (done - arrived) * 1000
            csv.write(t: arrived, fps: fps, latencyMs: latency, results: results,
                      qrMs: (qrDone - qrStart) * 1000, yoloMs: yolo == nil ? nil : (done - qrDone) * 1000)
            Task { @MainActor [weak model, error] in
                model?.results = results
                model?.latencyMs = latency
                if let error { model?.report("Vision 실패: \(error)") }
            }
        }
    }
}

/// Documents/metrics.csv 에 프레임별 측정값을 계속 추가 (파일 앱에서 꺼낼 수 있음).
nonisolated final class MetricsCSV {
    private let handle: FileHandle?

    private static let header = "t_ms,event,fps,latency_ms,detail,qr_ms,yolo_ms\n"

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

    /// Vision 큐(직렬)에서만 호출.
    func write(t: CFTimeInterval, fps: Int, latencyMs: Double, results: [Detection], qrMs: Double, yoloMs: Double?) {
        let detail = results.map { "\($0.value.replacingOccurrences(of: "\"", with: "\"\"")):\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ";")
        let yolo = yoloMs.map { String(format: "%.1f", $0) } ?? ""
        let line = String(format: "%.1f,camera_frame,%d,%.1f,\"%@\",%.1f,%@\n", t * 1000, fps, latencyMs, detail, qrMs, yolo)
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}
