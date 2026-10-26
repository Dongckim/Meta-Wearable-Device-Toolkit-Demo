# GlassDemo

Ray-Ban Meta 글래스로 절차 중 음성 개입을 실험하는 연구용 데모 앱.

## 반드시 지킬 것
- Meta Wearables DAT는 개발자 프리뷰다. API 이름과 시그니처는 기억으로 쓰지 말고
  매번 search_dat_docs로 확인한다. 확실하지 않으면 추측하지 말고 물어본다.
- DAT iOS는 1.0.1로 고정(Exact Version). 임의로 올리지 않는다.
- stasel/WebRTC는 154.0.0으로 고정(Exact Version). OpenAI API 키는 GlassDemo/GlassDemo/Secrets.swift(gitignore)에만 둔다.
  템플릿은 GlassDemo/Secrets.swift.example.
- Developer Mode로 동작한다. MetaAppID는 "0", ClientToken은 빈 문자열.
  Wearables Developer Center 계정은 쓰지 않는다.
- App Store 배포는 하지 않는다(SDK가 ExternalAccessory 사용). Xcode 직접 설치 전용.
- 오디오는 두 모드로 나뉜다. 두 모드는 동시에 켜지지 않고, 전환할 때 오디오 세션과 카메라 스트림을 다시 연다.
  - 선제 개입 모드(미리 정한 음성 재생): HFP를 켜지 않는다. A2DP 재생 전용(.playback).
    HFP가 켜지면 스피커가 모노 16kHz로 떨어진다.
  - 통화 모드(OpenAI Realtime API): 글래스 마이크(HFP)를 쓴다. 통화 중에는 선제 개입 음성(YOLO 규칙)을 재생하지 않고
    CSV에만 남긴다. 예외: 손 관절로 판정한 "반대 방향" 경고는 통화 중에도 바로 재생한다.
    모델은 "Hey Illini"로 부를 때만 답하고, 사진도 그때만 찍는다. HFP 경로가 자리잡은 뒤(2초) 카메라 스트림을 다시 연다.
    HFP와 카메라 영상이 같은 블루투스를 나눠 써서 영상이 밀리므로, 통화 중 카메라는 .low / 15fps(손 동작 판정에 fps가 필요해서 해상도를 낮춘다).
- 장기 목표: DAT in-stream 오디오(HFP 없이 글래스 마이크 + A2DP 유지).
  2026-10-22 시도 결과(글래스 fw V129, Meta AI V294): audioStreamingError, 오디오 프레임 0개, 영상도 멈춤.
  코드(커스텀 RTCAudioDevice)는 experiment/in-stream-audio 브랜치에 보관. 펌웨어/SDK가 바뀌면 다시 시험한다.
- 카메라 코덱은 .raw를 기본으로 한다(HEVC 경로에서 프레임 멈춤 사례 있음).
- 실기기 전용. 시뮬레이터에서는 글래스가 잡히지 않는다.

## 단계
3. 프로젝트 + SDK 연결   ← 완료
4. 등록해서 글래스 이름 화면에 띄우기   ← 완료
5. AVAudioSession .playback으로 글래스에서 음성 재생 (Meta SDK 불필요)   ← 완료
6. 카메라 스트림 + 지연 측정 (+ QR 인식)   ← 완료
6.5 YOLO(Core ML)로 컵 인식   ← 완료
7. 판단(로컬 규칙, Jev 안 씀) + 인식기 전환(QR↔CoreML) + 타임스탬프 기록   ← 완료
8. A 세션 상태 표시(실행/일시정지/종료)   ← 완료
   B OpenAI Realtime 음성 대화(화면 버튼, HFP)   ← 구현됨, 실기기 대화 확인 대기
   C 더블탭(MWDATInputs .select)으로 대화 시작/종료 — B 실기기 확인 후에만

한 단계 끝날 때마다 실기기에서 확인하고 커밋한다. 다음 단계로 먼저 넘어가지 않는다.
