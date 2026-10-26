// crop_hands.swift가 만든 train/test 폴더로 뚜껑 방향 분류기(correct / reversed)를 학습한다.
// 사용: xcrun swift tools/train_cap.swift <crops 폴더> <출력 .mlmodel>
// 증강에 뒤집기·회전은 넣지 않는다(위아래를 뒤집으면 라벨 의미가 바뀐다).

import CreateML
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: xcrun swift train_cap.swift <crops dir> <output .mlmodel>")
    exit(1)
}
let crops = URL(filePath: args[1])
let output = URL(filePath: args[2])

let parameters = MLImageClassifier.ModelParameters(
    validation: .split(strategy: .automatic),
    augmentation: [.crop, .exposure, .blur, .noise],
    algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor)
)
let model = try MLImageClassifier(trainingData: .labeledDirectories(at: crops.appending(path: "train")), parameters: parameters)

func percent(_ error: Double) -> String { String(format: "%.1f%%", (1 - error) * 100) }
print("train accuracy:      \(percent(model.trainingMetrics.classificationError))")
print("validation accuracy: \(percent(model.validationMetrics.classificationError))  (같은 테이크에서 무작위로 뗀 것 → 부풀려짐)")

let test = model.evaluation(on: MLImageClassifier.DataSource.labeledDirectories(at: crops.appending(path: "test")))
print("test accuracy:       \(percent(test.classificationError))  (테이크 끝 20%, 학습에 안 씀)")
print("confusion (test):")
print(test.confusion)

try model.write(to: output, metadata: MLModelMetadata(author: "GlassDemo", shortDescription: "Cap orientation on hand crops: correct / reversed"))
print("saved: \(output.path())")
