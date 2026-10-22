//
//  ContentView.swift
//  GlassDemo
//
//  Created by dongchankim on 10/21/26.
//
import AVFoundation
import MWDATCore
import SwiftUI

struct ContentView: View {
    let configureError: String?

    @State private var registrationState: RegistrationState?
    @State private var devices: [Device] = []
    @State private var log: [String] = []
    @State private var isGlassesOutput = false
    @State private var speech = SpeechPlayer()
    @State private var cameraModel = CameraModel()
    @State private var showCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let configureError {
                Text("configure() 실패: \(configureError)")
                    .foregroundStyle(.red)
            }

            Text("등록 상태: \(registrationState.map { "\($0)" } ?? "-")")

            Button("연결하기") {
                Task {
                    addLog("startRegistration()")
                    do {
                        try await Wearables.shared.startRegistration()
                    } catch {
                        addLog("startRegistration 실패: \(error)")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(configureError != nil)

            Text("글래스").font(.headline)
            if devices.isEmpty {
                Text("없음").foregroundStyle(.secondary)
            }
            ForEach(devices, id: \.identifier) { device in
                Text("\(device.nameOrId()) — \(device.deviceType().rawValue)")
            }

            Text(isGlassesOutput ? "출력: 글래스" : "출력: 아이폰 스피커")
                .font(.largeTitle.bold())
                .foregroundStyle(isGlassesOutput ? .green : .orange)

            ForEach(["warn_before", "step_done", "after_error"], id: \.self) { name in
                Button(name) { speech.play(name) }
                    .buttonStyle(.bordered)
            }

            Button("카메라") {
                Task {
                    guard await cameraModel.ensurePermission() else { return }
                    showCamera = true
                    await cameraModel.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(registrationState != .registered)

            Spacer()

            Text("이벤트 로그").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(model: cameraModel) {
                cameraModel.stop()
                showCamera = false
            }
        }
        .onOpenURL { url in
            addLog("onOpenURL: \(url)")
            Task {
                do {
                    let handled = try await Wearables.shared.handleUrl(url)
                    addLog("handleUrl → \(handled)")
                } catch {
                    addLog("handleUrl 실패: \(error)")
                }
            }
        }
        .task {
            speech.log = addLog
            cameraModel.log = addLog
            let session = AVAudioSession.sharedInstance()
            do {
                // 재생 전용. .playAndRecord/HFP 금지 (A2DP가 끊기고 모노 16kHz로 떨어짐)
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                addLog("AVAudioSession 설정 실패: \(error)")
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
                addLog("registrationState: \(state)")
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

    private func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isGlassesOutput = outputs.contains { $0.portType == .bluetoothA2DP }
        addLog("route: \(outputs.map { "\($0.portName)(\($0.portType.rawValue))" })")
    }

    private func addLog(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log = Array((log + ["\(time) \(message)"]).suffix(10))
    }
}

#Preview {
    ContentView(configureError: nil)
}
