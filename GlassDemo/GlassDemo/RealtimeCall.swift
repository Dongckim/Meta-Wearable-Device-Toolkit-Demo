//
//  RealtimeCall.swift
//  GlassDemo
//
//  OpenAI Realtime (WebRTC) 통화 모드. 글래스 마이크(HFP)를 쓴다. CLAUDE.md "통화 모드" 참고.
//  스키마 출처: developers.openai.com/api/docs/guides/realtime-webrtc, realtime-conversations (Function calling),
//  api/reference/resources/realtime/subresources/calls/methods/create
//

import AVFoundation
import Foundation
import Observation
import QuartzCore
import WebRTC

@Observable
final class RealtimeCall: NSObject {
    enum State: String {
        case idle = "Idle"
        case connecting = "Connecting…"
        case connected = "In call"
    }

    static let model = "gpt-realtime-2.1"
    static let instructions = "한국어로 짧게 답한다. 지금 무엇이 보이는지 물으면 반드시 get_current_detection을 호출해서 답한다. 절대 추측하지 않는다. 그릇이 보이면 컵을 집으라고 안내한다."

    var state = State.idle
    var inputDevice = "–"
    var outputDevice = "–"

    var log: (String) -> Void = { _ in }

    @ObservationIgnored private let camera: CameraModel
    @ObservationIgnored private var factory: RTCPeerConnectionFactory?
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var events: RTCDataChannel?
    @ObservationIgnored private var cameraWasRunning = false

    init(camera: CameraModel) {
        self.camera = camera
    }

    func toggle() async {
        if state == .idle { await start() } else { end() }
    }

    // MARK: - 시작

    private func start() async {
        guard !Secrets.openAIAPIKey.isEmpty else { return log("Call: Secrets.openAIAPIKey is empty") }
        guard await AVAudioApplication.requestRecordPermission() else { return log("Call: microphone permission denied") }

        state = .connecting
        MetricsCSV.shared.row("call_start", t: CACurrentMediaTime())
        camera.callActive = true  // 이 순간부터 선제 개입 음성은 재생하지 않고 CSV에만 남긴다

        // DAT: HFP 경로가 자리잡기 전에 카메라 스트림을 시작하면 오디오 경로가 조용히 실패할 수 있다 → 먼저 멈춘다
        cameraWasRunning = camera.isRunning
        if cameraWasRunning { camera.stop() }

        do {
            try configureHFPAudioSession()
            try await connect()
        } catch {
            log("Call failed: \(error)")
            end()
            return
        }

        // HFP 경로가 자리잡을 때까지 기다린 뒤 확인하고 카메라를 다시 켠다
        try? await Task.sleep(for: .seconds(2))
        guard state != .idle else { return }
        readRoute()
        let hfp = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        log(hfp ? "Call: HFP route settled" : "Call: HFP input not active — check the glasses connection")
        if cameraWasRunning { await camera.start() }
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
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.setConfiguration(config, active: true)
        if let glasses = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try session.setPreferredInput(glasses)
        } else {
            log("Call: no HFP input available yet")
        }
        session.isAudioEnabled = true
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

    /// 문서의 session.update + Function calling 스키마 그대로.
    private func registerSession() {
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": Self.instructions,
                "tools": [[
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
        case "output_audio_buffer.started":
            // WebRTC 전용: 서버가 모델 음성을 내보내기 시작한 시각
            MetricsCSV.shared.row("model_audio_start", t: CACurrentMediaTime())
        case "response.done":
            let output = (event["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
            for item in output where item["type"] as? String == "function_call" {
                guard item["name"] as? String == "get_current_detection", let callId = item["call_id"] as? String else { continue }
                answerTool(callId: callId)
            }
        case "error":
            log("Call error: \((event["error"] as? [String: Any])?["message"] ?? event)")
        default:
            break
        }
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
