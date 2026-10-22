# GlassDemo

Ray-Ban Meta 글래스로 절차 중 음성 개입을 실험하는 연구용 데모 앱.

## 반드시 지킬 것
- Meta Wearables DAT는 개발자 프리뷰다. API 이름과 시그니처는 기억으로 쓰지 말고
  매번 search_dat_docs로 확인한다. 확실하지 않으면 추측하지 말고 물어본다.
- DAT iOS는 1.0.1로 고정(Exact Version). 임의로 올리지 않는다.
- Developer Mode로 동작한다. MetaAppID는 "0", ClientToken은 빈 문자열.
  Wearables Developer Center 계정은 쓰지 않는다.
- App Store 배포는 하지 않는다(SDK가 ExternalAccessory 사용). Xcode 직접 설치 전용.
- 글래스 마이크(HFP)는 절대 켜지 않는다. 켜면 스피커가 모노 16kHz로 떨어진다.
  오디오는 A2DP 재생 전용.
- 카메라 코덱은 .raw를 기본으로 한다(HEVC 경로에서 프레임 멈춤 사례 있음).
- 실기기 전용. 시뮬레이터에서는 글래스가 잡히지 않는다.

## 단계
3. 프로젝트 + SDK 연결   ← 완료
4. 등록해서 글래스 이름 화면에 띄우기   ← 완료
5. AVAudioSession .playback으로 글래스에서 음성 재생 (Meta SDK 불필요)   ← 완료
6. 카메라 스트림 + 지연 측정 (+ QR 인식)   ← 완료
6.5 YOLO(Core ML)로 컵 인식   ← 완료
7. 판단(Jev) + 타임스탬프 기록   ← 지금

한 단계 끝날 때마다 실기기에서 확인하고 커밋한다. 다음 단계로 먼저 넘어가지 않는다.
