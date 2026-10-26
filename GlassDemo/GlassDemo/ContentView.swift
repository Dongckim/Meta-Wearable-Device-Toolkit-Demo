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

/// 데모 화면. 아이폰을 들고 보여 주므로 글자를 크게, 필요한 상태만.
struct ContentView: View {
    let configureError: String?

    @State private var registrationState: RegistrationState?
    @State private var devices: [Device] = []
    @State private var log: [String] = []
    @State private var isGlassesOutput = false
    @State private var speech = SpeechPlayer()
    @State private var cameraModel = CameraModel()
    @State private var call: RealtimeCall?
    @State private var showDataset = false
    @State private var showCalibration = false
    @State private var exportURL: URL?
    @State private var isExporting = false

    private var isRegistered: Bool { registrationState == .registered }

    var body: some View {
        VStack(spacing: 12) {
            header

            CameraView(model: cameraModel, placeholder: placeholder)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        detectionChip
                        gripPanel
                    }
                    .padding(12)
                }
                .overlay(alignment: .bottomLeading) { voicePill.padding(12) }
                .overlay { pausedOverlay }
                .frame(maxHeight: .infinity)

            controls

            if showCalibration { calibrationPanel }

            if showDataset { datasetPanel }

            logPanel
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
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
            cameraModel.dataset.log = addLog
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

    // MARK: - 상단 상태

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusChip(icon: "eyeglasses", text: glassesText, color: devices.isEmpty || !isRegistered ? .gray : .green)
                if cameraModel.isRunning {
                    StatusChip(icon: isPaused ? "pause.fill" : "dot.radiowaves.left.and.right",
                               text: isPaused ? "Paused" : "Live", color: isPaused ? .orange : .red)
                }
                StatusChip(icon: isGlassesOutput ? "speaker.wave.2.fill" : "iphone",
                           text: isGlassesOutput ? "Glasses audio" : "iPhone audio", color: isGlassesOutput ? .green : .orange)
                Spacer(minLength: 0)
            }
            if let configureError {
                Label("configure() failed: \(configureError)", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 4)
    }

    private var glassesText: String {
        guard isRegistered else { return "Not connected" }
        return devices.first?.nameOrId() ?? "No glasses"
    }

    private var isPaused: Bool {
        cameraModel.sessionState == .paused || cameraModel.streamState == .paused
    }

    private var placeholder: String {
        if cameraModel.endedOnGlasses { return "Session ended on the glasses" }
        return isRegistered ? "Ready" : "Connect your glasses"
    }

    // MARK: - 영상 위 오버레이

    @ViewBuilder private var detectionChip: some View {
        if cameraModel.isRunning, let label = cameraModel.stableLabel {
            HStack(spacing: 6) {
                Circle().fill(label == "none" ? .gray : CameraView.color(for: label)).frame(width: 10, height: 10)
                Text(label == "none" ? "Nothing" : label.capitalized)
                if label != "none", let conf = cameraModel.stableConfidence {
                    Text(conf, format: .number.precision(.fractionLength(2))).foregroundStyle(.white.opacity(0.7))
                }
                Text(cameraModel.detectorKind.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.2), in: Capsule())
            }
            .font(.headline.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }

    /// 쥠·회전 판정을 한눈에: 쥠/폄(색), 쥠 지표와 보정 경계, 각도·각속도·누적 회전, 판정된 방향.
    @ViewBuilder private var gripPanel: some View {
        if cameraModel.isRunning, !CameraModel.detectionEnabled {
            let g = cameraModel.grip
            let band = cameraModel.gripCalibration.band
            let turn = cameraModel.turnState
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(g == nil ? "NO HAND" : g!.gripped ? "GRIPPED" : "OPEN")
                        .font(.title.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .background(g == nil ? Color.gray : g!.gripped ? Color.green : Color.orange, in: Capsule())
                    if turn != .none {
                        Text(turn.rawValue)
                            .font(.title3.bold())
                            .foregroundStyle(turn == .tightening ? .green : .red)
                    }
                }
                Text("Grip \(Self.fmt(g?.gripIndex, "%.2f"))  ·  boundary "
                     + (band.map { String(format: "%.2f ±%.2f", $0.boundary, $0.margin) } ?? "not calibrated"))
                Text("Angle \(Self.fmt(g?.angle, "%+.0f°"))  ·  \(Self.fmt(g?.angularVelocity, "%+.0f°/s"))")
                Text("Total \(Self.fmt(g?.accumulated, "%+.0f°"))"
                     + (cameraModel.gripCalibration.tightenSign == nil ? "  (direction not calibrated)" : ""))
                    .font(.title3.bold().monospacedDigit())
            }
            .font(.headline.monospacedDigit())
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private static func fmt(_ value: Double?, _ format: String) -> String {
        value.map { String(format: format, $0) } ?? "–"
    }

    // MARK: - 쥠 보정

    /// 1) 쥔 채로 3초 2) 편 채로 3초 3) 조이는 방향으로 한 바퀴. 값은 UserDefaults에 저장된다.
    private var calibrationPanel: some View {
        let cal = cameraModel.gripCalibration
        let run = cameraModel.calibration
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(CalibrationRun.Step.allCases.enumerated()), id: \.offset) { n, step in
                let value: String = switch step {
                case .grip: Self.fmt(cal.grippedIndex, "%.2f")
                case .open: Self.fmt(cal.openIndex, "%.2f")
                case .turn: cal.tightenSign.map { $0 > 0 ? "angle +" : "angle −" } ?? "–"
                }
                HStack(spacing: 8) {
                    Text("\(n + 1). \(step.rawValue)").font(.subheadline)
                    Spacer()
                    Text(value).font(.subheadline.monospacedDigit().bold())
                    if run?.step == step {
                        ProgressView(value: run?.progress ?? 0).frame(width: 60)
                        if step == .turn {
                            Button("Done") { cameraModel.finishTurnCalibration() }.buttonStyle(.borderedProminent)
                        }
                        Button("Cancel") { cameraModel.cancelCalibration() }.buttonStyle(.bordered)
                    } else {
                        Button("Record") { cameraModel.startCalibration(step) }
                            .buttonStyle(.bordered)
                            .disabled(!cameraModel.isRunning || run != nil || (step == .turn && cal.band == nil))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// 침묵이 데모의 절반이라, 말하지 않는 상태도 항상 보이게 둔다.
    @ViewBuilder private var voicePill: some View {
        if cameraModel.isRunning {
            let (icon, text, tint): (String, String, Color) = {
                if cameraModel.callActive { return ("waveform", "Talk mode · local voice off", .purple) }
                if cameraModel.isSpeaking, case .speak(let sentence) = cameraModel.decision { return ("speaker.wave.2.fill", sentence, .blue) }
                if case .silent(let reason) = cameraModel.decision { return ("speaker.slash.fill", "Silent · \(reason)", .black.opacity(0.55)) }
                return ("speaker.slash.fill", "Silent", .black.opacity(0.55))
            }()
            Label(text, systemImage: icon)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tint, in: Capsule())
                .padding(.trailing, 90)  // 오른쪽 아래 fps 배지와 겹치지 않게
                .animation(.easeInOut(duration: 0.15), value: text)
        }
    }

    /// 안경다리 한 번 탭 = 일시정지. 교수님이 안경을 고쳐 쓰다 건드려도 바로 알 수 있게.
    @ViewBuilder private var pausedOverlay: some View {
        if cameraModel.isRunning, isPaused {
            VStack(spacing: 8) {
                Image(systemName: "pause.circle.fill").font(.system(size: 56))
                Text("Paused").font(.title.bold())
                Text("Tap the temple once to resume").font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: - 데이터 수집

    /// 라벨 선택(테이크 중에는 잠김) + 테이크 시작/정지 + zip 내보내기. 개수는 지금까지 저장된 라벨별 프레임 수.
    private var datasetPanel: some View {
        let dataset = cameraModel.dataset
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(DatasetLabel.allCases, id: \.self) { label in
                    let selected = dataset.label == label
                    Button {
                        dataset.label = label
                    } label: {
                        VStack(spacing: 2) {
                            Text(label == .correct ? "Correct" : "Reversed").font(.headline)
                            Text("\(dataset.counts[label] ?? 0) frames").font(.caption.monospacedDigit())
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(selected ? .white : .primary)
                        .background(selected ? (label == .correct ? Color.green : Color.orange) : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(dataset.isRecording)
                }
            }
            HStack(spacing: 8) {
                Button {
                    dataset.toggleTake()
                } label: {
                    Label(dataset.isRecording
                          ? String(format: "Stop take t%02d · %d", dataset.take, dataset.takeFrames)
                          : "Start take",
                          systemImage: dataset.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.headline.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.white)
                        .background(dataset.isRecording ? Color.red : Color.blue, in: Capsule())
                }
                .disabled(!cameraModel.isRunning && !dataset.isRecording)
                .opacity(cameraModel.isRunning || dataset.isRecording ? 1 : 0.4)

                Button {
                    isExporting = true
                    Task {
                        do {
                            exportURL = try await dataset.exportZip()
                        } catch {
                            addLog("export failed: \(error)")
                        }
                        isExporting = false
                    }
                } label: {
                    Group {
                        if isExporting { ProgressView() } else { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                    .font(.headline)
                    .frame(minWidth: 110, minHeight: 44)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .disabled(isExporting || dataset.isRecording)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 버튼

    private var controls: some View {
        HStack(spacing: 12) {
            primaryButton

            Menu {
                Button("Reset decision", systemImage: "arrow.counterclockwise") { cameraModel.reset() }
                Button(cameraModel.detectorKind == .coreML ? "Switch to QR" : "Switch to CoreML",
                       systemImage: "arrow.left.arrow.right") { cameraModel.toggleDetector() }
                Button(showCalibration ? "Hide grip calibration" : "Calibrate grip",
                       systemImage: "hand.raised.fingers.spread") { showCalibration.toggle() }
                Button(showDataset ? "Hide data collection" : "Data collection",
                       systemImage: "square.stack.3d.down.right") { showDataset.toggle() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
        }
    }

    /// 연결 전에는 Connect, 연결 후에는 통화(글래스 마이크) + 카메라 스트림을 한 번에 켜고 끈다.
    @ViewBuilder private var primaryButton: some View {
        let callState = call?.state ?? .idle
        let isActive = callState != .idle || cameraModel.isRunning
        let (title, icon, tint): (String, String, Color) =
            !isRegistered ? ("Connect", "link", .blue)
            : callState == .connecting ? ("Connecting…", "hourglass", .gray)
            : isActive ? ("Stop", "stop.fill", .red)
            : ("Start", "play.fill", .blue)
        Button {
            if !isRegistered {
                Task {
                    addLog("startRegistration()")
                    do {
                        try await Wearables.shared.startRegistration()
                    } catch {
                        addLog("startRegistration failed: \(error)")
                    }
                }
            } else if isActive {
                call?.end()
                cameraModel.stop()
            } else {
                Task {
                    guard await cameraModel.ensurePermission() else { return }
                    await call?.start()
                }
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(.white)
                .background(tint, in: Capsule())
        }
        .disabled(configureError != nil || callState == .connecting)
    }

    // MARK: - 로그

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.removeAll() }
                    .font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
        .padding(12)
        .frame(height: 160)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // 선제 개입 모드는 A2DP, 통화 모드는 HFP로 글래스에 나간다
        isGlassesOutput = outputs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP }
        addLog("route: \(outputs.map { "\($0.portName)(\($0.portType.rawValue))" })")
    }

    private func addLog(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log = Array((log + ["\(time) \(message)"]).suffix(300))
    }
}

private struct StatusChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// zip 파일을 AirDrop·파일 앱 등으로 보내는 시스템 공유 시트.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView(configureError: nil)
}
