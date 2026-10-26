//
//  Dataset.swift
//  GlassDemo
//
//  학습용 데이터 수집. 테이크가 켜져 있는 동안 들어오는 프레임을 전부
//  Documents/dataset/<label>/<label>_tNN_NNNN.jpg 로 저장한다. Create ML이 폴더 이름을 클래스로 읽는다.
//

import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Observation
import QuartzCore

nonisolated enum DatasetLabel: String, CaseIterable, Sendable {
    case correct
    case reversed
}

/// SDK 콜백 스레드에서 프레임을 받아 자기 직렬 큐에서 JPEG으로 쓴다(인식 큐와 따로라 인식을 막지 않는다).
nonisolated final class DatasetWriter: @unchecked Sendable {
    static let root = URL.documentsDirectory.appending(path: "dataset")

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "GlassDemo.dataset")
    private let context = CIContext()
    private var active: (label: DatasetLabel, take: Int)?
    private var frameIndex = 0
    var onSaved: @Sendable (DatasetLabel) -> Void = { _ in }
    var onError: @Sendable (String) -> Void = { _ in }

    func begin(_ label: DatasetLabel, take: Int) {
        try? FileManager.default.createDirectory(at: Self.root.appending(path: label.rawValue), withIntermediateDirectories: true)
        lock.withLock {
            active = (label, take)
            frameIndex = 0
        }
    }

    func end() {
        lock.withLock { active = nil }
    }

    /// 쓰기 대기 중인 프레임이 다 저장될 때까지 기다린다(내보내기 전에).
    func flush() {
        queue.sync {}
    }

    func save(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let next: (label: DatasetLabel, take: Int, index: Int)? = lock.withLock {
            guard let active else { return nil }
            frameIndex += 1
            return (active.label, active.take, frameIndex)
        }
        guard let next else { return }
        // 글래스에서 온 픽셀 그대로(리사이즈·회전·보정 없음). 인식기도 같은 버퍼를 .up으로 읽는다
        nonisolated(unsafe) let image = CIImage(cvPixelBuffer: pixelBuffer)  // 만든 뒤에는 읽기만 한다
        let name = String(format: "%@_t%02d_%04d.jpg", next.label.rawValue, next.take, next.index)
        let url = Self.root.appending(path: next.label.rawValue).appending(path: name)
        queue.async { [self] in
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95,
            ]
            guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options) else {
                return onError("JPEG encode failed: \(name)")
            }
            do {
                try jpeg.write(to: url)
                onSaved(next.label)
            } catch {
                onError("save failed: \(error)")
            }
        }
    }

    /// 파일 앱 폴더 압축과 같은 방식(NSFileCoordinator .forUploading)으로 dataset 폴더 전체를 zip으로 만든다.
    func exportZip() throws -> URL {
        flush()
        let dest = FileManager.default.temporaryDirectory.appending(path: "dataset.zip")
        var result: Result<URL, Error> = .failure(CocoaError(.fileNoSuchFile))
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: Self.root, options: .forUploading, error: &coordinatorError) { zip in
            result = Result {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zip, to: dest)
                return dest
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try result.get()
    }

    /// 이미 저장된 파일에서 라벨별 개수와 마지막 테이크 번호를 읽는다(앱을 다시 켜도 번호가 이어지게).
    static func scan() -> (counts: [DatasetLabel: Int], lastTake: Int) {
        var counts: [DatasetLabel: Int] = [:]
        var lastTake = 0
        for label in DatasetLabel.allCases {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: label.rawValue).path())) ?? []
            let jpegs = files.filter { $0.hasSuffix(".jpg") }
            counts[label] = jpegs.count
            for file in jpegs {
                // correct_t03_0041.jpg → 3
                let parts = file.split(separator: "_")
                if parts.count == 3, parts[1].hasPrefix("t"), let take = Int(parts[1].dropFirst()) {
                    lastTake = max(lastTake, take)
                }
            }
        }
        return (counts, lastTake)
    }
}

/// 화면 상태(라벨 선택, 테이크, 라벨별 개수).
@Observable
final class DatasetCollector {
    var label = DatasetLabel.correct
    private(set) var isRecording = false
    private(set) var take: Int
    private(set) var takeFrames = 0
    private(set) var counts: [DatasetLabel: Int]

    @ObservationIgnored let writer = DatasetWriter()
    var log: (String) -> Void = { _ in }

    init() {
        let scanned = DatasetWriter.scan()
        counts = scanned.counts
        take = scanned.lastTake
        writer.onSaved = { [weak self] label in
            Task { @MainActor in
                self?.counts[label, default: 0] += 1
                self?.takeFrames += 1
            }
        }
        writer.onError = { [weak self] message in
            Task { @MainActor in self?.log("dataset: \(message)") }
        }
    }

    func toggleTake() {
        if isRecording {
            writer.end()
            isRecording = false
            log("take t\(String(format: "%02d", take)) stopped: \(takeFrames) frames (\(label.rawValue))")
            MetricsCSV.shared.row("take_stop", t: CACurrentMediaTime(), label: label.rawValue, detail: "take=\(take) frames=\(takeFrames)")
        } else {
            take += 1
            takeFrames = 0
            writer.begin(label, take: take)
            isRecording = true
            log("take t\(String(format: "%02d", take)) started (\(label.rawValue))")
            MetricsCSV.shared.row("take_start", t: CACurrentMediaTime(), label: label.rawValue, detail: "take=\(take)")
        }
    }

    func exportZip() async throws -> URL {
        let writer = writer
        return try await Task.detached { try writer.exportZip() }.value
    }
}
