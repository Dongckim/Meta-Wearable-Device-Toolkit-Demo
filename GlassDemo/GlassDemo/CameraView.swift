//
//  CameraView.swift
//  GlassDemo
//

import SwiftUI

/// 글래스 영상 + 인식 박스 + 구석의 fps / 인식 ms.
struct CameraView: View {
    let model: CameraModel
    let placeholder: String

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

                    ForEach(model.results) { item in
                        let rect = viewRect(normalized: item.boundingBox, imageSize: image.size, viewSize: geo.size)
                        let color = Self.color(for: item.label)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(color, lineWidth: 4)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        Text("\(item.label) \(item.confidence, format: .number.precision(.fractionLength(2)))")
                            .font(.title3.monospaced().bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.black)
                            .offset(x: rect.minX, y: max(rect.minY - 32, 0))
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 52, weight: .light))
                        Text(placeholder)
                            .font(.title3)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .overlay(alignment: .bottomTrailing) { metricsBadge.padding(10) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    static func color(for label: String) -> Color {
        switch label {
        case "cup": .green
        case "bowl": .red
        default: .yellow
        }
    }

    private var metricsBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(model.fps) fps")
            Text("\(model.latencyMs.map { String(format: "%.0f", $0) } ?? "–") ms")
        }
        .font(.headline.monospaced())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
