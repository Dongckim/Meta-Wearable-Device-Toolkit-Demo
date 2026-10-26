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

                    handOverlay(imageSize: image.size)
                        .frame(width: geo.size.width, height: geo.size.height)

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
            .overlay(alignment: .bottomTrailing) { if model.isRunning { metricsBadge.padding(12) } }
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

    /// 손 관절 21개 + 뼈대. 엄지·검지 끝(돌리는 방향을 재는 두 점)은 하늘색으로 크게.
    private func handOverlay(imageSize: CGSize) -> some View {
        Canvas { context, size in
            for hand in model.hands {
                let points = hand.points.map { p in
                    p.map { viewRect(normalized: CGRect(origin: $0, size: .zero), imageSize: imageSize, viewSize: size).origin }
                }
                var bones = Path()
                for (a, b) in HandPose.bones {
                    guard let pa = points[a], let pb = points[b] else { continue }
                    bones.move(to: pa)
                    bones.addLine(to: pb)
                }
                context.stroke(bones, with: .color(.white.opacity(0.85)), lineWidth: 2)
                for (i, p) in points.enumerated() {
                    guard let p else { continue }
                    let measured = i == 4 || i == 8
                    let r: CGFloat = measured ? 6 : HandPose.tips.contains(i) ? 4.5 : 3.5
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(measured ? .cyan : .orange))
                }
            }
        }
        .allowsHitTesting(false)
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
