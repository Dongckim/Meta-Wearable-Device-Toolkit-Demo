//
//  RealtimeCall.swift
//  GlassDemo
//
//  OpenAI Realtime (WebRTC) 통화 모드. 글래스 마이크(HFP)를 쓴다. CLAUDE.md "통화 모드" 참고.
//  (DAT in-stream 마이크 시도는 experiment/in-stream-audio 브랜치에 보관)
//  스키마 출처: developers.openai.com/api/docs/guides/realtime-webrtc, realtime-conversations (Function calling),
//  api/reference/resources/realtime/subresources/calls/methods/create
//

import AVFoundation
import Foundation
import Observation
import QuartzCore
import UIKit
import WebRTC

@Observable
final class RealtimeCall: NSObject {
    enum State: String {
        case idle = "Idle"
        case connecting = "Connecting…"
        case connected = "In call"
    }

    static let model = "gpt-realtime-2.1"
    static let instructions = CameraModel.detectionEnabled ? detectionInstructions : visionInstructions
    static let visionInstructions = """
        The user calls you by saying "Hey Illini" and then asks a question. Answer briefly in English. \
        Call look_through_glasses only when the answer depends on what the user sees; \
        it takes a photo from the camera on the user's glasses. Describe what is actually in that photo. \
        For anything else (for example the time, or general questions) answer directly without it; \
        use get_current_time for the time. If the photo is unclear or missing, say so instead of guessing.
        """
    static let detectionInstructions = """
        The user calls you by saying "Hey Illini"; answer the request that follows it. \
        Answer briefly in English. When asked what is visible, you must call get_current_detection and answer from its result. \
        Never guess. If a bowl is visible, tell the user to pick up the cup. \
        When you receive a system message starting with "Detection update", announce it to the user in one short sentence \
        (for example "I see a cup."); if it is a bowl, also tell them to pick up the cup.
        """

    var state = State.idle
    var inputDevice = "–"
    var outputDevice = "–"

    var log: (String) -> Void = { _ in }

    @ObservationIgnored private let camera: CameraModel
    @ObservationIgnored private var factory: RTCPeerConnectionFactory?
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var events: RTCDataChannel?
    @ObservationIgnored private var routeTask: Task<Void, Never>?
    /// 모델이 답하는 중에 response.create를 보내면 충돌하므로, 끝날 때까지 감지 안내를 보류한다(가장 최근 것만).
    @ObservationIgnored private var responseActive = false
    /// "Hey Illini"만 부르고 질문이 없으면 "Yes, sir?"로 받고, 그 뒤 이 시각까지 오는 말을 질문으로 받는다.
    @ObservationIgnored private var followUpUntil: CFTimeInterval?
    @ObservationIgnored private var awaitingFollowUp = false
    static let followUpWindow: CFTimeInterval = 8
    static let acknowledgement = "Yes, sir?"
    /// 모델 음성이 나가는 중에 시작된 말 = 글래스 마이크로 되돌아온 모델 목소리일 수 있어서 무시한다.
    @ObservationIgnored private var modelSpeaking = false
    @ObservationIgnored private var echoItems: Set<String> = []
    @ObservationIgnored private var pendingAnnouncement: (label: String, confidence: Float?)?

    init(camera: CameraModel) {
        self.camera = camera
        super.init()
        camera.onStableChange = { [weak self] label, confidence in self?.detectionChanged(label, confidence) }
    }

    // MARK: - 감지되면 먼저 말하기

    /// 안정된 인식 결과가 바뀌었을 때(3프레임 연속) 호출된다. cup/bowl만 안내하고 none은 조용히.
    private func detectionChanged(_ label: String, _ confidence: Float?) {
        guard state == .connected else { return }
        guard label == "cup" || label == "bowl" else {
            pendingAnnouncement = nil
            return
        }
        pendingAnnouncement = (label, confidence)
        flushAnnouncement()
    }

    private func flushAnnouncement() {
        guard !responseActive, let pending = pendingAnnouncement else { return }
        pendingAnnouncement = nil
        let conf = pending.confidence.map { String(format: " (confidence %.2f)", $0) } ?? ""
        let text = "Detection update from the glasses camera: \(pending.label)\(conf)."
        MetricsCSV.shared.row("detection_announce", t: CACurrentMediaTime(), label: pending.label,
                              confidence: pending.confidence, detail: text)
        log("announce → \(pending.label)")
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]]])
        send(["type": "response.create"])
        responseActive = true  // response.created가 오기 전에 또 보내지 않도록
    }

    // MARK: - 시작

    /// 통화와 카메라 스트림을 함께 켠다. 끌 때는 end()가 둘 다 끈다.
    func start() async {
        guard !Secrets.openAIAPIKey.isEmpty else { return log("Call: Secrets.openAIAPIKey is empty") }
        guard await AVAudioApplication.requestRecordPermission() else { return log("Call: microphone permission denied") }

        state = .connecting
        MetricsCSV.shared.row("call_start", t: CACurrentMediaTime())
        camera.callActive = true  // 이 순간부터 선제 개입 음성은 재생하지 않고 CSV에만 남긴다

        // DAT: HFP 경로가 자리잡기 전에 카메라 스트림을 시작하면 오디오 경로가 조용히 실패할 수 있다 → 먼저 멈춘다
        if camera.isRunning { camera.stop() }

        routeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                guard let self, self.state != .idle else { continue }
                self.routeToGlasses("routeChange")
                self.readRoute()
            }
        }

        do {
            try configureHFPAudioSession()
            try await connect()
        } catch {
            log("Call failed: \(error)")
            end()
            return
        }

        // HFP 경로가 자리잡을 때까지 기다린 뒤 확인하고 카메라를 다시 켠다(통화 중에는 저화질, CameraModel 참고)
        try? await Task.sleep(for: .seconds(2))
        guard state != .idle else { return }
        routeToGlasses("settle")
        readRoute()
        let hfp = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        log(hfp ? "Call: HFP route settled" : "Call: HFP input not active — check the glasses connection")
        await camera.start()
    }

    /// WebRTC가 AVAudioSession을 가져가므로 RTCAudioSession을 통해 명시적으로 설정한다.
    private func configureHFPAudioSession() throws {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(config)

        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        // lockForConfiguration은 재진입 불가(두 번 잠그면 WebRTC가 앱을 죽인다) → 잠금은 이 블록 안에서만
        session.lockForConfiguration()
        do {
            try session.setConfiguration(config, active: true)
        } catch {
            session.unlockForConfiguration()
            throw error
        }
        session.unlockForConfiguration()
        session.isAudioEnabled = true
        routeToGlasses("configure")
    }

    /// playAndRecord의 기본 출력은 아이폰이다. 글래스 HFP를 preferred input으로 잡아야 입력·출력이 함께 글래스로 간다.
    /// HFP 포트는 세션 활성화 직후에는 아직 없을 수 있어서 연결 후·2초 뒤·경로 변경 때마다 다시 시도한다.
    private func routeToGlasses(_ reason: String) {
        let av = AVAudioSession.sharedInstance()
        let inputs = av.availableInputs ?? []
        guard let glasses = inputs.first(where: { $0.portType == .bluetoothHFP }) else {
            return log("Call[\(reason)]: no HFP input — available: \(inputs.map { "\($0.portName)(\($0.portType.rawValue))" })")
        }
        if av.currentRoute.inputs.contains(where: { $0.uid == glasses.uid }) { return }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do {
            try rtc.setPreferredInput(glasses)
            log("Call[\(reason)]: preferred input → \(glasses.portName)")
        } catch {
            log("Call[\(reason)]: setPreferredInput failed: \(error)")
        }
    }

    private func connect() async throws {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                               decoderFactory: RTCDefaultVideoDecoderFactory())
        self.factory = factory

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw CallError.message("peerConnection is nil")
        }
        self.peer = peer

        let mic = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "mic")
        peer.add(mic, streamIds: ["local"])

        guard let events = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
            throw CallError.message("dataChannel is nil")
        }
        events.delegate = self
        self.events = events

        let offer = try await peer.offer(for: constraints)
        try await peer.setLocalDescription(offer)
        let answer = try await postOffer(offer.sdp)
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
    }

    /// 표준 키로는 문서상 multipart(sdp + session)로 모델을 지정한다. raw application/sdp는 ephemeral 키 예시에만 있다.
    private func postOffer(_ sdp: String) async throws -> String {
        let boundary = "glassdemo-\(UUID().uuidString)"
        let session = #"{"type":"realtime","model":"\#(Self.model)","audio":{"output":{"voice":"marin"}}}"#
        var body = ""
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"sdp\"\r\nContent-Type: application/sdp\r\n\r\n\(sdp)\r\n"
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"session\"\r\nContent-Type: application/json\r\n\r\n\(session)\r\n"
        body += "--\(boundary)--\r\n"

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(Secrets.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else { throw CallError.message("calls \(status): \(text.prefix(300))") }
        return text
    }

    // MARK: - 종료

    func end() {
        let wasActive = state != .idle
        pendingAnnouncement = nil
        responseActive = false
        followUpUntil = nil
        awaitingFollowUp = false
        modelSpeaking = false
        echoItems = []
        routeTask?.cancel()
        routeTask = nil
        events?.close()
        peer?.close()
        events = nil
        peer = nil
        factory = nil
        state = .idle

        // 통화 모드 → 선제 개입 모드: HFP를 내리고 .playback(A2DP)으로 되돌린다
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.lockForConfiguration()
        try? rtc.setActive(false)
        rtc.unlockForConfiguration()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            log("Call: restoring .playback failed: \(error)")
        }
        camera.callActive = false
        if camera.isRunning { camera.stop() }
        readRoute()
        if wasActive {
            MetricsCSV.shared.row("call_end", t: CACurrentMediaTime())
            log("Call ended")
        }
    }

    // MARK: - 데이터 채널 이벤트

    private func send(_ event: [String: Any]) {
        guard let events, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        events.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// 사진은 모델이 필요하다고 판단할 때만 찍는다(시간 묻기 같은 질문에는 안 찍는다).
    static let visionTools: [[String: Any]] = [
        [
            "type": "function",
            "name": "look_through_glasses",
            "description": "Takes a photo from the camera on the user's glasses. Use only when you need to see.",
            "parameters": ["type": "object", "properties": [String: Any](), "required": [String]()],
        ],
        [
            "type": "function",
            "name": "get_current_time",
            "description": "Returns the current local date and time.",
            "parameters": ["type": "object", "properties": [String: Any](), "required": [String]()],
        ],
    ]

    /// 문서의 session.update + Function calling 스키마 그대로.
    private func registerSession() {
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": Self.instructions,
                // "Hey Illini"로 시작할 때만 답하므로 자동 응답을 끄고, 전사 결과를 보고 직접 response.create를 보낸다.
                // 옆 사람 말소리가 모델 음성(경고)을 끊지 않도록 interrupt도 끈다. 나머지 값은 문서의 server_vad 기본값.
                "audio": ["input": [
                    "turn_detection": [
                        "type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 500,
                        "create_response": false, "interrupt_response": false,
                    ],
                    "transcription": [
                        "model": "gpt-transcribe", "language": "en", "keywords": ["Hey Illini", "Illini"],
                        "prompt": "The speaker often starts with the wake phrase \"Hey Illini\" (pronounced ih-LIE-nye). Spell it \"Hey Illini\".",
                    ],
                ]],
                "tools": !CameraModel.detectionEnabled ? Self.visionTools : [[
                    "type": "function",
                    "name": "get_current_detection",
                    "description": "Returns what the glasses camera currently sees: label (cup, bowl, or none), confidence, and how many seconds ago that frame arrived.",
                    "parameters": ["type": "object", "properties": [String: Any](), "required": [String]()],
                ]],
                "tool_choice": "auto",
            ],
        ])
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "session.updated":
            log("Call: session.updated (tools registered)")
        case "input_audio_buffer.speech_started":
            if modelSpeaking, let itemId = event["item_id"] as? String { echoItems.insert(itemId) }
        case "conversation.item.input_audio_transcription.completed":
            let transcript = event["transcript"] as? String ?? ""
            let itemId = event["item_id"] as? String
            let now = CACurrentMediaTime()
            MetricsCSV.shared.row("transcript", t: now, detail: transcript)
            let wake = Self.parseWake(transcript)
            let isEcho = itemId.map { echoItems.remove($0) != nil } ?? false
            let isFollowUp = !isEcho && (followUpUntil.map { now < $0 } ?? false)

            if wake.called, wake.request == nil {
                log("Hey Illini → \(Self.acknowledgement)")
                if let itemId { send(["type": "conversation.item.delete", "item_id": itemId]) }
                acknowledge()
            } else if wake.called || isFollowUp {
                log("question → \(transcript)")
                followUpUntil = nil
                ask()
            } else {
                log("heard (ignored\(isEcho ? ", echo" : "")): \(transcript)")
                // 호출하지 않은 말은 대화 기록에서 지워서, 나중 답변이 그 말에 끌려가지 않게 한다
                if let itemId { send(["type": "conversation.item.delete", "item_id": itemId]) }
            }
        case "output_audio_buffer.started":
            // WebRTC 전용: 서버가 모델 음성을 내보내기 시작한 시각
            MetricsCSV.shared.row("model_audio_start", t: CACurrentMediaTime())
            modelSpeaking = true
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            modelSpeaking = false
            // "Yes, sir?"가 다 나간 뒤부터 질문을 기다린다(되돌아온 자기 목소리를 질문으로 받지 않게)
            if awaitingFollowUp {
                awaitingFollowUp = false
                followUpUntil = CACurrentMediaTime() + Self.followUpWindow
            }
        case "response.created":
            responseActive = true
        case "response.done":
            responseActive = false
            defer { flushAnnouncement() }
            let output = (event["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
            for item in output where item["type"] as? String == "function_call" {
                guard let callId = item["call_id"] as? String else { continue }
                switch item["name"] as? String {
                case "get_current_detection": answerTool(callId: callId)
                case "look_through_glasses": look(callId: callId)
                case "get_current_time":
                    answer(callId: callId, name: "get_current_time", output: Date().formatted(date: .complete, time: .shortened))
                default: continue
                }
            }
        case "error":
            responseActive = false  // 거절된 response.create로 보류가 영영 안 풀리는 일 방지
            log("Call error: \((event["error"] as? [String: Any])?["message"] ?? event)")
        default:
            break
        }
    }

    /// 글래스 사진(없으면 화면의 영상 프레임)을 JPEG data URL로 보낸다(문서의 input_image 형식).
    /// 데이터 채널 메시지는 256KB 안쪽이어야 해서 긴 변을 1024px로 줄인다.
    private func sendImage(photo: Data?) {
        let source = photo.flatMap(UIImage.init(data:))
        guard let image = source ?? camera.image else { return log("image → none (camera not streaming)") }
        let scale = min(1, 1024 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.75) else { return }
        let kind = source == nil ? "stream frame" : "photo"
        MetricsCSV.shared.row("image_sent", t: CACurrentMediaTime(), label: kind,
                              detail: "\(Int(size.width))x\(Int(size.height)) \(jpeg.count) bytes")
        log("image → \(kind) \(Int(size.width))x\(Int(size.height)) \(jpeg.count / 1024) KB")
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
                                   ["type": "input_text", "text": "Photo from the glasses camera."]]]])
    }


    /// 고정 문장으로 바로 답한다. 대화 기록에 남지 않는 응답(conversation: none)이라 질문 답변에 섞이지 않는다.
    private func acknowledge() {
        MetricsCSV.shared.row("wake", t: CACurrentMediaTime(), detail: Self.acknowledgement)
        awaitingFollowUp = true
        send(["type": "response.create",
              "response": ["conversation": "none", "instructions": "Say exactly \"\(Self.acknowledgement)\" and nothing else."]])
        responseActive = true
        // output_audio_buffer.stopped가 안 오는 경우를 대비해 3초 뒤에는 어쨌든 질문을 기다린다
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard self.awaitingFollowUp else { return }
            self.awaitingFollowUp = false
            self.followUpUntil = CACurrentMediaTime() + Self.followUpWindow
        }
    }

    /// 질문에 답하게 한다. 사진이 필요한지는 모델이 정한다(필요하면 look_through_glasses를 부른다).
    private func ask() {
        send(["type": "response.create"])
        responseActive = true
    }

    /// look_through_glasses: 사진을 찍어 도구 결과 뒤에 user 메시지로 붙이고 이어서 답하게 한다.
    private func look(callId: String) {
        responseActive = true  // 사진을 기다리는 동안 다른 response.create가 끼지 않게
        let camera = camera
        Task {
            let photo = await camera.capturePhoto()
            guard self.state == .connected else { return }
            self.answer(callId: callId, name: "look_through_glasses",
                        output: "The photo follows as the next message. Answer from what is in it.") { self.sendImage(photo: photo) }
        }
    }

    private func answer(callId: String, name: String, output: String, then extra: () -> Void = {}) {
        MetricsCSV.shared.row("tool_call", t: CACurrentMediaTime(), label: name, detail: output)
        log("tool \(name) → \(output)")
        send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callId, "output": output]])
        extra()
        send(["type": "response.create"])
        responseActive = true
    }

    /// 어디에 있어도 호출로 보는 표기.
    static let wakeNames: Set = ["illini", "ilini", "illinis", "illiny", "illinois"]
    /// "hey" 바로 뒤에 올 때만 호출로 보는 비슷한 발음(전사기가 잘못 적는 경우).
    static let wakeSoundAlikes: Set = ["elini", "alini", "elaine", "eleni", "lainey", "laini", "lenny", "alina", "illana", "illinae"]
    static let heyWords: Set = ["hey", "hi", "hay", "a", "okay", "ok"]

    /// 전사기가 "Illini"를 비슷한 말로 적는 경우까지 받는다. request = 호출어 뒤에 이어진 말(없으면 nil).
    /// 두 단어로 쪼개 적는 경우("ill ini")도 붙여서 본다. 편집 거리 매칭은 "hey" 뒤에서만(아무 문장의 "willing" 등을 피하려고).
    static func parseWake(_ transcript: String) -> (called: Bool, request: String?) {
        let words = transcript.lowercased().split { !$0.isLetter }.map(String.init)
        for i in words.indices {
            let afterHey = i > 0 && heyWords.contains(words[i - 1])
            for span in [1, 2] where i + span <= words.count {
                let w = words[i..<(i + span)].joined()
                let matched = wakeNames.contains(w)
                    || afterHey && (wakeSoundAlikes.contains(w) || w.count >= 4 && editDistance(w, "illini") <= 2)
                guard matched else { continue }
                let rest = words[(i + span)...]
                return (true, rest.isEmpty ? nil : rest.joined(separator: " "))
            }
        }
        return (false, nil)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = old
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    /// 로컬 Detector의 최신 결과를 그대로 돌려준다.
    private func answerTool(callId: String) {
        let now = CACurrentMediaTime()
        var result: [String: Any]
        if let latest = camera.latest {
            result = ["label": latest.label, "confidence": Double(latest.confidence),
                      "seconds_ago": ((now - latest.arrived) * 10).rounded() / 10]
        } else {
            result = ["label": "none", "confidence": 0, "seconds_ago": NSNull(), "note": "no camera frame yet"]
        }
        let output = String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)) ?? Data(), as: UTF8.self)
        MetricsCSV.shared.row("tool_call", t: now, label: "get_current_detection", detail: output)
        log("tool → \(output)")
        send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callId, "output": output]])
        send(["type": "response.create"])
        responseActive = true  // 같은 response.done 처리 안에서 감지 안내가 겹쳐 나가지 않도록
    }

    private func readRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputDevice = route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        outputDevice = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        log("Call route in=\(inputDevice) out=\(outputDevice)")
    }

    enum CallError: Error {
        case message(String)
    }
}

// WebRTC 콜백은 WebRTC 스레드에서 온다 → 메인으로 넘긴다
extension RealtimeCall: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            self.log("Call: peer \(newState.rawValue)")
            if newState == .connected {
                self.state = .connected
                MetricsCSV.shared.row("call_connected", t: CACurrentMediaTime())
                self.routeToGlasses("connected")
                self.readRoute()  // 연결 직후 입력/출력 장치
            } else if newState == .failed || newState == .disconnected {
                self.end()
            }
        }
    }

    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let open = dataChannel.readyState == .open
        Task { @MainActor in if open { self.registerSession() } }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any] else { return }
        nonisolated(unsafe) let unsafeEvent = event
        Task { @MainActor in self.handle(unsafeEvent) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
