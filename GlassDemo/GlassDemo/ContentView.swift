//
//  ContentView.swift
//  GlassDemo
//
//  Created by dongchankim on 10/21/26.
//
import MWDATCore
import SwiftUI

struct ContentView: View {
    let configureError: String?

    @State private var registrationState: RegistrationState?
    @State private var devices: [Device] = []
    @State private var log: [String] = []

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
            guard configureError == nil else { return }
            async let states: Void = {
                for await state in Wearables.shared.registrationStateStream() {
                    registrationState = state
                    addLog("registrationState: \(state)")
                }
            }()
            async let deviceIds: Void = {
                for await ids in Wearables.shared.devicesStream() {
                    devices = ids.compactMap { Wearables.shared.deviceForIdentifier($0) }
                    addLog("devices: \(ids)")
                }
            }()
            _ = await (states, deviceIds)
        }
    }

    private func addLog(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log = Array((log + ["\(time) \(message)"]).suffix(10))
    }
}

#Preview {
    ContentView(configureError: nil)
}
