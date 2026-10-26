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
import Vision

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
    /// false = YOLO/QR 대신 손 관절 인식을 돌린다. 통화 모드는 인식 결과 대신 사진을 모델에 직접 보낸다.
    nonisolated static let detectionEnabled = false

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
    /// 손 관절(화면 그리기용)과 쥠·회전 판정(GripTracker). grip이 nil이면 판정할 손이 없다.
    var hands: [HandPose] = []
    var grip: GripTracker.Reading?
    var turnState = TurnState.none
    var gripCalibration = GripCalibration.load()
    var calibration: CalibrationRun?
    /// 글래스 쪽 세션/스트림 상태. 안경다리 한 번 탭 = 일시정지/재개, 길게 누르기 = 세션 종료.
    var sessionState: DeviceSessionState?
    var streamState: StreamState?
    var endedOnGlasses = false
    /// 통화 모드 중에는 선제 개입 음성을 재생하지 않는다(판단과 CSV 기록은 그대로).
    var callActive = false
    /// 가장 최근에 처리된 프레임의 최상위 결과. Realtime tool이 그대로 돌려준다.
    @ObservationIgnored private(set) var latest: (label: String, confidence: Float, arrived: CFTimeInterval)?

    var log: (String) -> Void = { _ in }
    var speak: (String) -> Void = { _ in }
    /// 안정된 인식 결과가 바뀔 때마다(판단과 같은 시점). 통화 모드가 "감지되었다" 안내에 쓴다.
    var onStableChange: (String, Float?) -> Void = { _, _ in }

    @ObservationIgnored private var engine = DecisionEngine()
    @ObservationIgnored private var gripTracker = GripTracker()
    @ObservationIgnored private var smoother = LandmarkSmoother()
    @ObservationIgnored private var trackedCenter: CGPoint?  // 두 손 중 같은 손을 계속 따라가려고
    @ObservationIgnored private var missingFrames = 0
    static let decideDegrees = 25.0  // 누적 회전이 이보다 크면 방향을 판정
    static let warningCooldown: CFTimeInterval = 5
    static let holdSeconds = 3.0  // 보정: 쥔 채로 / 편 채로
    static let turnCalibrationDegrees = 360.0  // 보정: 한 바퀴 돌면 자동으로 끝
    static let handLostFrames = 5  // 이만큼 연속 손이 없으면 사라진 것(한두 프레임 놓침은 무시)
    static let wrongTurnWarning = "You're turning it the wrong way."
    @ObservationIgnored private var lastWarning: CFTimeInterval = -.infinity
    @ObservationIgnored private let coreML: CoreMLDetector? = try? CoreMLDetector()
    /// 학습용 프레임 저장(데이터 수집 모드). 영상 표시·인식과 따로 돈다.
    @ObservationIgnored let dataset = DatasetCollector()
    @ObservationIgnored private lazy var processor = FrameProcessor(model: self, detector: detector(for: detectorKind),
                                                                    datasetWriter: dataset.writer)
    @ObservationIgnored private var photoWaiter: CheckedContinuation<Data?, Never>?
    @ObservationIgnored private var photoRequest = 0
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
            endedOnGlasses = false
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

    /// 영상 프레임은 블루투스 대역폭에 맞춰 많이 압축되므로, 모델에 보낼 때는 스틸 사진을 따로 찍는다.
    /// 스트림 중에만 된다. timeout 안에 안 오면 nil.
    func capturePhoto(timeout: Duration = .seconds(2)) async -> Data? {
        resumePhoto(nil)  // 앞 요청이 남아 있으면 끝낸다
        guard let stream = camera?.stream, stream.capturePhoto(format: .jpeg) else {
            report("capturePhoto → not available")
            return nil
        }
        photoRequest += 1
        let request = photoRequest
        let started = CACurrentMediaTime()
        let data = await withCheckedContinuation { continuation in
            photoWaiter = continuation
            Task {
                try? await Task.sleep(for: timeout)
                if photoRequest == request { resumePhoto(nil) }
            }
        }
        let ms = (CACurrentMediaTime() - started) * 1000
        MetricsCSV.shared.row("photo", t: started, latencyMs: ms, detail: data.map { "\($0.count) bytes" } ?? "timeout")
        report(data.map { String(format: "photo %d KB in %.0f ms", $0.count / 1024, ms) } ?? "photo timeout")
        return data
    }

    private func resumePhoto(_ data: Data?) {
        photoWaiter?.resume(returning: data)
        photoWaiter = nil
    }

    func stop() {
        resumePhoto(nil)
        if dataset.isRecording { dataset.toggleTake() }  // 영상이 끊기면 테이크도 끝낸다
        camera?.stream.stop()
        session?.stop()
        tokens.clear()
        tokens = ListenerTokenBag()
        camera = nil
        session = nil
        isRunning = false
        sessionState = .stopped
        streamState = nil
        image = nil
        results = []
        hands = []
        resetGrip()
        calibration = nil
        lastWarning = -.infinity
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
        report("session: \(state.description)")
        sessionState = state
        MetricsCSV.shared.row("session_state", t: CACurrentMediaTime(), label: state.description)
        switch state {
        case .started:
            guard camera == nil, let session else { return }  // pause 후 다시 started가 와도 한 번만
            do {
                // 통화 모드에서는 HFP 음성이 같은 블루투스를 나눠 써서 영상이 밀린다 → 해상도를 낮춘다.
                // 돌리는 방향은 프레임 사이 움직임으로 보므로 fps는 15를 유지한다.
                let config = callActive
                    ? StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 15)
                    : StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)
                report("stream config: \(callActive ? "low / 15fps (call)" : "medium / 15fps")")
                guard let camera = try session.addCamera(config: config) else {
                    return report("addCamera → nil")
                }
                self.camera = camera
                let stream = camera.stream
                let processor = processor
                stream.statePublisher.listen { state in
                    Task { @MainActor in self.streamChanged(state) }
                }.store(in: tokens)
                stream.errorPublisher.listen { error in
                    Task { @MainActor in self.report("stream error: \(error)") }
                }.store(in: tokens)
                stream.photoDataPublisher.listen { photo in
                    Task { @MainActor in self.resumePhoto(photo.data) }
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
            // 우리가 stop()을 부르기 전에 끝났다면 글래스에서 끝낸 것(길게 누르기 등)
            if isRunning {
                endedOnGlasses = true
                report("Session ended on the glasses")
                stop()
            }
        default:
            break
        }
    }

    private func streamChanged(_ state: StreamState) {
        report("stream: \(state)")
        streamState = state
        MetricsCSV.shared.row("stream_state", t: CACurrentMediaTime(), label: "\(state)")
    }

    /// arrived = 이 결과를 만든 프레임의 도착 시각.
    func didDetect(_ detections: [Detection], detector: String, arrived: CFTimeInterval, latencyMs: Double) {
        results = detections
        self.latencyMs = latencyMs
        let top = detections.max { $0.confidence < $1.confidence }
        let label = top?.label ?? "none"
        latest = (label, top?.confidence ?? 0, arrived)
        if label == stableLabel { stableConfidence = top?.confidence }

        let now = CACurrentMediaTime()
        guard let decision = engine.observe(label, at: now) else { return }
        stableLabel = label
        stableConfidence = top?.confidence
        self.decision = decision
        onStableChange(label, top?.confidence)

        let detail: String
        switch decision {
        case .speak(let sentence): detail = "speak: \(sentence)"
        case .silent(let reason): detail = "silent: \(reason)"
        }
        MetricsCSV.shared.row("decision", t: now, detector: detector, label: label, confidence: top?.confidence,
                              latencyMs: (now - arrived) * 1000, detail: detail)
        report("\(label) → \(detail)")
        if case .speak(let sentence) = decision {
            if callActive {
                // 말했어야 할 시점만 남긴다
                MetricsCSV.shared.row("speech_suppressed", t: now, detector: detector, label: label, detail: "call active: \(sentence)")
                report("(call active) would say: \(sentence)")
            } else {
                speak(sentence)
            }
        }
    }

    func didTrackHands(_ poses: [HandPose], arrived t: CFTimeInterval, latencyMs: Double) {
        hands = poses
        self.latencyMs = latencyMs
        guard let hand = trackedHand(in: poses) else {
            missingFrames += 1
            if missingFrames >= Self.handLostFrames, grip != nil {
                resetGrip()  // 손이 화면에서 사라지면 누적을 0으로
                report("hand lost → reset")
            }
            MetricsCSV.shared.row("grip", t: t, label: "no_hand", latencyMs: latencyMs)
            return
        }
        missingFrames = 0
        trackedCenter = Self.center(hand) ?? trackedCenter
        let size = image?.size ?? CGSize(width: 1, height: 1)
        func toPixels(_ points: [CGPoint?]) -> [CGPoint?] { points.map { $0.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } } }
        let raw = toPixels(hand.points)
        let wasGripped = grip?.gripped ?? false
        let r = gripTracker.update(points: toPixels(smoother.smooth(hand.points)), raw: raw, band: gripCalibration.band, at: t)
        grip = r
        if r.gripped != wasGripped { report(r.gripped ? "gripped" : "released") }
        // pts = 평균 전 관절 픽셀(오프라인 재생·튜닝용), 관절 순서는 HandPose.joints
        let pts = raw.map { $0.map { String(format: "%.0f;%.0f", $0.x, $0.y) } ?? "" }.joined(separator: "|")
        MetricsCSV.shared.row("grip", t: t, label: r.gripped ? "gripped" : "open", latencyMs: latencyMs,
                              detail: String(format: "index=%@ angle=%@ w=%@ acc=%.1f hands=%d pts=%@",
                                             Self.fmt(r.gripIndex, "%.3f"), Self.fmt(r.angle, "%.1f"), Self.fmt(r.angularVelocity, "%.1f"), r.accumulated,
                                             poses.count, pts))
        updateCalibration(r, at: t)
        judgeTurn(r, at: t)
    }

    private static func fmt(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "" }

    /// 이전에 따라가던 손(보인 관절 중심이 가장 가까운 손)을 계속 쓴다. 처음에는 오른손, 없으면 첫 번째 손.
    /// 손목 기준이면 손목이 안 보일 때 거리가 무한대라 아무 손이나 골랐다.
    private func trackedHand(in poses: [HandPose]) -> HandPose? {
        guard let trackedCenter else { return poses.first { $0.isRight == true } ?? poses.first }
        return poses.min { a, b in
            func d(_ h: HandPose) -> CGFloat { Self.center(h).map { hypot($0.x - trackedCenter.x, $0.y - trackedCenter.y) } ?? .infinity }
            return d(a) < d(b)
        }
    }

    private static func center(_ hand: HandPose) -> CGPoint? {
        let seen = hand.points.compactMap { $0 }
        guard !seen.isEmpty else { return nil }
        let n = CGFloat(seen.count)
        return CGPoint(x: seen.reduce(0) { $0 + $1.x } / n, y: seen.reduce(0) { $0 + $1.y } / n)
    }

    private func resetGrip() {
        gripTracker.reset()
        smoother.reset()
        trackedCenter = nil
        missingFrames = 0
        grip = nil
        turnState = .none
    }

    /// 누적 회전이 25°를 넘으면 방향 판정. 조이는 방향이면 조용히, 푸는 방향이면 경고(쿨다운 5초) 후 누적 초기화.
    private func judgeTurn(_ r: GripTracker.Reading, at t: CFTimeInterval) {
        guard calibration == nil, let sign = gripCalibration.tightenSign, abs(r.accumulated) > Self.decideDegrees else {
            turnState = .none
            return
        }
        let tightening = (r.accumulated > 0) == (sign > 0)
        let previous = turnState
        turnState = tightening ? .tightening : .loosening
        if turnState != previous { report(String(format: "%@ %+.0f°", turnState.rawValue, r.accumulated)) }
        guard !tightening, t - lastWarning > Self.warningCooldown else { return }
        lastWarning = t
        MetricsCSV.shared.row("warning", t: t, label: "loosening", detail: String(format: "acc=%.1f %@", r.accumulated, Self.wrongTurnWarning))
        speak(Self.wrongTurnWarning)
        gripTracker.clearAccumulation()
    }

    // MARK: - 쥠 보정

    func startCalibration(_ step: CalibrationRun.Step) {
        if step == .turn {
            guard gripCalibration.band != nil else { return report("calibration: record grip and open first") }
            gripTracker.clearAccumulation()
        }
        calibration = CalibrationRun(step: step)
        report("calibration: \(step.rawValue)")
    }

    func cancelCalibration() {
        calibration = nil
        report("calibration cancelled")
    }

    /// 회전 단계: 그동안 누적된 각도의 부호를 조이는 방향으로 저장한다.
    func finishTurnCalibration() {
        let accumulated = gripTracker.accumulated
        calibration = nil
        guard abs(accumulated) > Self.decideDegrees else {
            return report(String(format: "calibration: turned only %.0f°, try again", accumulated))
        }
        gripCalibration.tightenSign = accumulated > 0 ? 1 : -1
        gripCalibration.save()
        gripTracker.clearAccumulation()
        report(String(format: "calibration: tighten = %@ (%+.0f°)", accumulated > 0 ? "angle +" : "angle −", accumulated))
    }

    private func updateCalibration(_ r: GripTracker.Reading, at t: CFTimeInterval) {
        guard var run = calibration else { return }
        switch run.step {
        case .grip, .open:
            guard let index = r.gripIndex else { return }
            let started = run.started ?? t
            run.started = started
            run.samples.append(index)
            run.progress = min((t - started) / Self.holdSeconds, 1)
            if run.progress >= 1 {
                let mean = run.samples.reduce(0, +) / Double(run.samples.count)
                if run.step == .grip { gripCalibration.grippedIndex = mean } else { gripCalibration.openIndex = mean }
                gripCalibration.save()
                calibration = nil
                report(String(format: "calibration: %@ = %.3f (%d frames)", run.step == .grip ? "gripped" : "open", mean, run.samples.count))
                if gripCalibration.grippedIndex != nil, gripCalibration.openIndex != nil, gripCalibration.band == nil {
                    report("calibration: gripped value is not smaller than open value, record again")
                }
                return
            }
        case .turn:
            run.progress = min(abs(r.accumulated) / Self.turnCalibrationDegrees, 1)
            if run.progress >= 1 {
                calibration = run
                return finishTurnCalibration()
            }
        }
        calibration = run
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
    private let handDetector = HandPoseDetector()
    private let datasetWriter: DatasetWriter

    init(model: CameraModel, detector: any Detector, datasetWriter: DatasetWriter) {
        self.model = model
        self.detector = detector
        self.datasetWriter = datasetWriter
    }

    var detectorName: String { lock.withLock { detector.name } }

    func setDetector(_ detector: any Detector) {
        lock.withLock { self.detector = detector }
    }

    func onFrame(_ frame: VideoFrame) {
        let arrived = CACurrentMediaTime()
        datasetWriter.save(frame.sampleBuffer)  // 테이크 중이면 모든 프레임(인식이 건너뛰는 프레임 포함)
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

        guard CameraModel.detectionEnabled else {
            queue.async { [self] in
                let poses = (try? handDetector.detect(frame.sampleBuffer)) ?? []
                let latency = (CACurrentMediaTime() - arrived) * 1000
                lock.withLock { busy = false }
                Task { @MainActor [weak model] in
                    model?.didTrackHands(poses, arrived: arrived, latencyMs: latency)
                }
            }
            return
        }

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
