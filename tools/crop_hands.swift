// 데이터 수집 모드로 모은 프레임에서 손(뚜껑을 쥔 손) 주변만 정사각형으로 잘라 학습용 폴더를 만든다.
// 사용: swift tools/crop_hands.swift <dataset 폴더> <출력 폴더>
//   입력: <dataset>/<label>/<label>_tNN_NNNN.jpg
//   출력: <출력>/train/<label>/..., <출력>/test/<label>/...  (Create ML이 폴더 이름을 클래스로 읽는다)
// 테스트는 테이크마다 마지막 20%(앞과 1초 간격을 둠). 연속 프레임은 거의 같아서 무작위로 나누면 정확도가 부풀려진다.
// 앱에서 판정할 때도 같은 규칙(엄지·검지 끝 중간, 손바닥 길이 × cropScale)으로 잘라야 학습과 조건이 같다.

import CoreImage
import Foundation
import Vision

let cropScale = 2.2  // 잘라 낼 한 변 = 손바닥 길이(손목→중지 뿌리) × cropScale
let minSide = 96.0
let testFraction = 0.2
let gapFrames = 15  // 15fps에서 1초

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: swift crop_hands.swift <dataset dir> <output dir>")
    exit(1)
}
let input = URL(filePath: args[1])
let output = URL(filePath: args[2])
let fm = FileManager.default
let context = CIContext()

/// 두 손이 보이면 엄지·검지 끝이 더 오므려진 손(뚜껑을 집은 손)을 고른다. 병을 감싼 손은 더 벌어져 있다.
func cropRect(for image: CIImage) throws -> CGRect? {
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 2
    try VNImageRequestHandler(ciImage: image).perform([request])
    let w = image.extent.width, h = image.extent.height
    func px(_ p: VNRecognizedPoint) -> CGPoint { CGPoint(x: p.location.x * w, y: p.location.y * h) }  // CIImage도 좌하단 원점

    var best: (pinch: CGFloat, rect: CGRect)?
    for hand in request.results ?? [] {
        guard let pts = try? hand.recognizedPoints(.all),
              let thumb = pts[.thumbTip], let index = pts[.indexTip],
              let wrist = pts[.wrist], let middle = pts[.middleMCP],
              [thumb, index, wrist, middle].allSatisfy({ $0.confidence > 0.3 }) else { continue }
        let t = px(thumb), i = px(index), wr = px(wrist), m = px(middle)
        let palm = hypot(m.x - wr.x, m.y - wr.y)
        guard palm > 1 else { continue }
        let pinch = hypot(i.x - t.x, i.y - t.y) / palm
        let side = min(max(palm * cropScale, minSide), min(w, h))
        let center = CGPoint(x: (t.x + i.x) / 2, y: (t.y + i.y) / 2)
        // 가장자리에서는 잘리지 않게 안쪽으로 민다(크기는 유지)
        let x = min(max(center.x - side / 2, 0), w - side)
        let y = min(max(center.y - side / 2, 0), h - side)
        let rect = CGRect(x: x, y: y, width: side, height: side).integral
        if best == nil || pinch < best!.pinch { best = (pinch, rect) }
    }
    return best?.rect
}

var summary: [String] = []
let labels = try fm.contentsOfDirectory(atPath: input.path()).filter {
    var isDir: ObjCBool = false
    return fm.fileExists(atPath: input.appending(path: $0).path(), isDirectory: &isDir) && isDir.boolValue
}.sorted()

for label in labels {
    let files = try fm.contentsOfDirectory(atPath: input.appending(path: label).path()).filter { $0.hasSuffix(".jpg") }.sorted()
    // 테이크별로 묶는다: correct_t03_0041.jpg → "t03"
    let takes = Dictionary(grouping: files) { $0.split(separator: "_").dropFirst().first.map(String.init) ?? "?" }
    var kept = ["train": 0, "test": 0], skipped = 0
    for (_, takeFiles) in takes.sorted(by: { $0.key < $1.key }) {
        let testStart = Int(Double(takeFiles.count) * (1 - testFraction))
        for (n, file) in takeFiles.enumerated() {
            let split: String
            if n >= testStart { split = "test" } else if n >= testStart - gapFrames { continue } else { split = "train" }
            guard let image = CIImage(contentsOf: input.appending(path: label).appending(path: file)),
                  let rect = try cropRect(for: image) else {
                skipped += 1
                continue
            }
            let dir = output.appending(path: split).appending(path: label)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let cropped = image.cropped(to: rect)
            try context.writeJPEGRepresentation(of: cropped.transformed(by: .init(translationX: -rect.minX, y: -rect.minY)),
                                                to: dir.appending(path: file), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
            kept[split, default: 0] += 1
        }
    }
    summary.append("\(label): \(takes.count) take(s), \(files.count) frames → train \(kept["train"]!), test \(kept["test"]!), no hand \(skipped)")
}
summary.forEach { print($0) }
