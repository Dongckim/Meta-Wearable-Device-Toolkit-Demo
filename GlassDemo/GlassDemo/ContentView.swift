//
//  ContentView.swift
//  GlassDemo
//
//  Created by dongchankim on 10/21/26.
//
import AVFoundation
import MWDATCamera
import MWDATCore
import SwiftUI

/// 데모 화면. 아이폰을 들고 보여 주므로 글자를 크게.
struct ContentView: View {
    let configureError: String?

    @State private var registrationState: RegistrationState?
    @State private var devices: [Device] = []
    @State private var log: [String] = []
    @State private var isGlassesOutput = false
    @State private var speech = SpeechPlayer()
    @State private var cameraModel = CameraModel()
    @State private var call: RealtimeCall?
    @State private var outputKind = ""

    private var isRegistered: Bool { registrationState == .registered }

    var body: some View {
        VStack(spacing: 10) {
            statusPanel

            CameraView(model: cameraModel, placeholder: isRegistered ? "Press Start demo" : "Connect your glasses first")
                .frame(maxHeight: .infinity)

            controls

            callRow

            logLines
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .onOpenURL { url in
            addLog("onOpenURL: \(url)")
            Task {
                do {
                    let handled = try await Wearables.shared.handleUrl(url)
                    addLog("handleUrl → \(handled)")
                } catch {
                    addLog("handleUrl failed: \(error)")
                }
            }
        }
        .task {
            speech.log = addLog
            speech.onSpeaking = { cameraModel.isSpeaking = $0 }
            cameraModel.log = addLog
            cameraModel.speak = speech.speak
            let call = RealtimeCall(camera: cameraModel)
            call.log = addLog
            self.call = call
            let session = AVAudioSession.sharedInstance()
            do {
                // 재생 전용. .playAndRecord/HFP 금지 (A2DP가 끊기고 모노 16kHz로 떨어짐)
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                addLog("AVAudioSession setup failed: \(error)")
            }
            updateRoute()
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                updateRoute()
            }
        }
        .task {
            guard configureError == nil else { return }
            for await state in Wearables.shared.registrationStateStream() {
                registrationState = state
                addLog("registrationState: \(state.description)")
            }
        }
        .task {
            guard configureError == nil else { return }
            for await ids in Wearables.shared.devicesStream() {
                devices = ids.compactMap { Wearables.shared.deviceForIdentifier($0) }
                addLog("devices: \(ids)")
            }
        }
    }

    // MARK: - 상단: 현재 인식 결과 / 현재 판단 / 오디오 출력

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            sessionBanner

            if let configureError {
                Label("configure() failed: \(configureError)", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("SEES").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Text(seesText)
                    .font(.largeTitle.bold())
                    .foregroundStyle(cameraModel.stableLabel.map { CameraView.color(for: $0) == .yellow ? .primary : CameraView.color(for: $0) } ?? .secondary)
                Spacer()
                Text(cameraModel.detectorKind.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            decisionBanner

            HStack {
                Label(isGlassesOutput ? "Output: Glasses\(outputKind)" : "Output: iPhone speaker",
                      systemImage: isGlassesOutput ? "eyeglasses" : "iphone")
                    .font(.headline)
                    .foregroundStyle(isGlassesOutput ? .green : .orange)
                Spacer()
                Text(devices.first?.nameOrId() ?? "No glasses")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 교수님이 안경을 고쳐 쓰다 안경다리를 건드려도 바로 알 수 있게 크게 보여 준다.
    private var sessionBanner: some View {
        let paused = cameraModel.sessionState == .paused || cameraModel.streamState == .paused
        let (icon, title, hint, color): (String, String, String?, Color) = {
            if paused { return ("pause.circle.fill", "PAUSED", "Tap the temple once to resume", .orange) }
            switch cameraModel.sessionState {
            case .started: return ("record.circle", "RUNNING", nil, .green)
            case .starting: return ("hourglass", "STARTING", nil, .blue)
            case .stopping: return ("stop.circle", "STOPPING", nil, .gray)
            default:
                return ("stop.circle.fill", "STOPPED",
                        cameraModel.endedOnGlasses ? "Ended on the glasses — press Start demo" : nil, .gray)
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.title2.bold())
                if let hint { Text(hint).font(.headline) }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color, in: RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.15), value: title)
    }

    private var seesText: String {
        guard let label = cameraModel.stableLabel else { return "—" }
        if label == "none" { return "Nothing" }
        let conf = cameraModel.stableConfidence.map { String(format: " %.2f", $0) } ?? ""
        return label + conf
    }

    /// 침묵이 데모의 절반이라, 말하지 않는 상태도 크게 분명하게 보여 준다.
    private var decisionBanner: some View {
        let speaking = cameraModel.isSpeaking
        let (icon, title, subtitle): (String, String, String) = {
            if cameraModel.callActive {
                return ("phone.fill", "CALL MODE", "local voice muted — logged only")
            }
            switch cameraModel.decision {
            case .speak(let sentence):
                return speaking ? ("speaker.wave.3.fill", "SPEAKING", "“\(sentence)”") : ("speaker.slash.fill", "SILENT", "last: “\(sentence)”")
            case .silent(let reason):
                return ("speaker.slash.fill", "SILENT", reason)
            case nil:
                return ("speaker.slash.fill", "SILENT", cameraModel.isRunning ? "waiting for a stable result" : "demo not running")
            }
        }()
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title.bold())
                Text(subtitle).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
        }
        .foregroundStyle(speaking ? .white : .primary)
        .padding(12)
        .background(speaking ? Color.blue : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.15), value: speaking)
    }

    // MARK: - 버튼

    private var controls: some View {
        HStack(spacing: 8) {
            if isRegistered {
                Button {
                    if cameraModel.isRunning {
                        cameraModel.stop()
                    } else {
                        Task {
                            guard await cameraModel.ensurePermission() else { return }
                            await cameraModel.start()
                        }
                    }
                } label: {
                    Label(cameraModel.isRunning ? "Stop demo" : "Start demo",
                          systemImage: cameraModel.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(cameraModel.isRunning ? .red : .blue)
            } else {
                Button {
                    Task {
                        addLog("startRegistration()")
                        do {
                            try await Wearables.shared.startRegistration()
                        } catch {
                            addLog("startRegistration failed: \(error)")
                        }
                    }
                } label: {
                    Label("Connect", systemImage: "link").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(configureError != nil)
            }

            Button { cameraModel.reset() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)

            Button { cameraModel.toggleDetector() } label: {
                Label(cameraModel.detectorKind == .coreML ? "QR" : "ML", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
        }
        .font(.body.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .controlSize(.large)
    }

    // MARK: - 통화 (OpenAI Realtime)

    private var callRow: some View {
        let state = call?.state ?? .idle
        return HStack(spacing: 10) {
            Button {
                Task { await call?.toggle() }
            } label: {
                Label(state == .idle ? "Start talk" : "End talk",
                      systemImage: state == .idle ? "mic.fill" : "phone.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(state == .idle ? .purple : .red)
            .disabled(state == .connecting)
            .font(.body.weight(.semibold))
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.rawValue).font(.subheadline.bold())
                Text("In: \(call?.inputDevice ?? "–")").font(.caption2).lineLimit(1)
                Text("Out: \(call?.outputDevice ?? "–")").font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 하단 로그

    private var logLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(log.suffix(4).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // 선제 개입 모드는 A2DP, 통화 모드는 HFP로 글래스에 나간다
        isGlassesOutput = outputs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP }
        outputKind = outputs.contains { $0.portType == .bluetoothHFP } ? " (HFP)" : ""
        addLog("route: \(outputs.map { "\($0.portName)(\($0.portType.rawValue))" })")
    }

    private func addLog(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log = Array((log + ["\(time) \(message)"]).suffix(50))
    }
}

#Preview {
    ContentView(configureError: nil)
}
