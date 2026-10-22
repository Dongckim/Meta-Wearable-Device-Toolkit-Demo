//
//  CameraView.swift
//  GlassDemo
//

import SwiftUI

struct CameraView: View {
    let model: CameraModel
    let close: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = model.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                    ForEach(model.results) { qr in
                        let rect = viewRect(normalized: qr.box, imageSize: image.size, viewSize: geo.size)
                        let color: Color = qr.isQR ? .green : .orange
                        Rectangle()
                            .stroke(color, lineWidth: 3)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        Text("\(qr.value) \(qr.confidence, format: .number.precision(.fractionLength(2)))")
                            .font(.caption.bold())
                            .padding(2)
                            .background(color)
                            .foregroundStyle(.black)
                            .offset(x: rect.minX, y: max(rect.minY - 20, 0))
                    }
                }

                VStack(alignment: .leading) {
                    Text("\(model.fps) fps")
                    Text("인식 \(model.latencyMs.map { String(format: "%.1f", $0) } ?? "-") ms")
                    ForEach(Array(model.messages.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).textSelection(.enabled)
                    }
                }
                .font(.headline.monospaced())
                .padding(8)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .padding(.top, geo.safeAreaInsets.top)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button("닫기", action: close)
                .buttonStyle(.borderedProminent)
                .padding()
        }
    }
}
