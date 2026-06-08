# 용어집 (Glossary)

> 본문에서 처음 나오는 어려운 용어를 여기 모았습니다. 모르는 단어가 나오면 여기서 찾으세요.

## Apple / macOS

| 용어 | 풀이 |
|------|------|
| **ScreenCaptureKit (SCKit)** | Apple이 제공하는 화면 캡처 프레임워크. 화면·창·앱 단위로 이미지/영상을 가져올 수 있음. Dayflow는 이걸로 스크린샷을 찍음. |
| **SCScreenshotManager** | ScreenCaptureKit 안에서 "지금 화면 한 장"을 찍는 클래스. Dayflow는 연속 영상 대신 이걸로 주기적 스냅샷을 찍음. |
| **SCShareableContent** | 캡처 가능한 화면/창 목록을 알려주는 객체. "어떤 디스플레이를 찍을지" 고를 때 사용. |
| **AppKit** | macOS의 전통적 UI 프레임워크(윈도우, 메뉴바 등). SwiftUI로 안 되는 시스템 통합(상태바 아이콘 등)에 사용. |
| **NSStatusBar / NSStatusItem** | 화면 우상단 메뉴바에 아이콘을 띄우는 AppKit API. Dayflow의 "녹화 중" 아이콘. |
| **Entitlements** | 앱이 가질 수 있는 권한 선언 파일(`.entitlements`). 네트워크·파일 접근 등. |
| **Sandbox(샌드박스)** | 앱을 격리해 시스템 접근을 제한하는 보안 기능. Dayflow는 화면 캡처 때문에 비활성. |

## 데이터베이스

| 용어 | 풀이 |
|------|------|
| **SQLite** | 파일 하나로 동작하는 가벼운 관계형 DB. 서버가 필요 없음. |
| **GRDB** | Swift용 SQLite 라이브러리(ORM). SQL을 Swift 코드로 안전하게 다루게 해줌. |
| **ORM** | Object-Relational Mapping. DB의 행(row)을 코드의 객체로, 객체를 행으로 자동 변환해주는 도구. |
| **WAL (Write-Ahead Logging)** | SQLite의 쓰기 방식. 변경을 별도 로그에 먼저 쓴 뒤 본 DB에 반영 → 읽기와 쓰기가 동시에 가능해 빠름. |
| **DatabasePool** | GRDB가 제공하는 연결 풀. 여러 읽기를 동시에, 쓰기는 직렬로 처리. |
| **Checkpoint(체크포인트)** | WAL 로그에 쌓인 변경을 본 DB 파일에 합치는 작업. 주기적으로 실행. |
| **Migration(마이그레이션)** | DB 스키마(테이블 구조)를 버전업할 때 안전하게 바꾸는 단계별 절차. |

## Dayflow 도메인 용어

| 용어 | 풀이 |
|------|------|
| **Screenshot(스크린샷)** | 10초마다 찍는 화면 한 장. `screenshots` 테이블의 한 행. 분석의 원재료. |
| **Batch(배치)** | 스크린샷 여러 장을 시간대로 묶은 분석 단위. 기본 목표 길이 **15분**. LLM에 한 번에 보냄. |
| **Observation(옵저베이션/관찰)** | LLM이 배치 영상을 보고 "이 시간엔 무엇을 했다"라고 적은 1차 기록. 카드의 재료. |
| **Timeline Card(타임라인 카드)** | observation들을 모아 만든 최종 활동 카드(제목·요약·카테고리·시간). 사용자가 보는 단위. |
| **Compression factor(압축 계수)** | 스크린샷들을 짧은 영상으로 합칠 때, 영상 속 시간(예: 30초)을 실제 시간(예: 15분)으로 되돌리는 배율. |
| **4AM boundary(새벽 4시 경계)** | "하루"를 자정이 아니라 새벽 4시에 끊는 규칙. 밤늦게 일하는 사람의 활동이 다음 날로 넘어가지 않게. |
| **Distraction(산만함)** | 집중 외 활동(딴짓) 세션. 분석에서 별도로 표시. |
| **Feature gating(기능 게이팅)** | 일정 분석 시간을 채워야 기능이 열리는 방식. Daily=5h, Chat=10h, Weekly=30h. |
| **Daily Standup(일일 스탠드업)** | 어제 하이라이트 / 오늘 우선순위 / 블로커를 자동 생성한 요약(개발팀 스탠드업 미팅용). |

## AI / LLM

| 용어 | 풀이 |
|------|------|
| **LLM** | Large Language Model(대규모 언어 모델). 텍스트·이미지·영상을 이해하고 글을 생성하는 AI. |
| **Provider(프로바이더)** | LLM을 호출하는 방법의 구현체. Dayflow엔 Gemini/DayflowBackend/Ollama/ChatCLI 4종. |
| **Gemini** | Google의 멀티모달 LLM. Dayflow의 기본 클라우드 provider. |
| **Ollama** | 내 컴퓨터에서 LLM을 돌리는 로컬 런타임. `localhost:11434`. 완전 오프라인 분석용. |
| **Chat CLI** | 터미널에 설치된 Claude/Codex 같은 CLI 도구를 stdin/stdout으로 호출하는 방식. |
| **Fallback(폴백)** | 기본 provider가 실패하면 대체 provider로 자동 전환(Gemini 실패 → Gemma). |
| **Transcription(전사)** | 화면 영상을 보고 "무슨 일을 했는지" 텍스트로 옮기는 단계. observation 생성. |
| **Prompt(프롬프트)** | LLM에게 주는 지시문. "이 영상을 보고 3~8개 구간으로 나눠 설명하라" 같은. |

## 배포 / 운영

| 용어 | 풀이 |
|------|------|
| **Sparkle** | macOS 앱 자동 업데이트 라이브러리. 새 버전을 받아 설치. |
| **appcast.xml** | Sparkle이 읽는 "업데이트 목록" XML. 최신 버전·다운로드 URL·서명이 들어있음. |
| **EdDSA** | Sparkle 업데이트 파일의 위변조를 막는 전자서명 방식. 공개키는 Info.plist에. |
| **Notarization(공증)** | Apple에 앱을 보내 악성코드 검사를 받는 과정. 통과해야 사용자가 경고 없이 실행. |
| **PostHog** | 사용자 행동 분석(이벤트 트래킹) 플랫폼. |
| **Sentry** | 크래시·에러 모니터링 플랫폼. |
| **distinct ID** | PostHog가 사용자를 구분하는 고유 ID. Dayflow는 이걸 백엔드 인증 토큰으로도 재사용. |
| **opt-in / opt-out** | 사용자가 데이터 수집에 동의(in)/거부(out)하는 것. Dayflow 분석은 기본 ON(opt-out 가능). |

## Swift / 코드 패턴

| 용어 | 풀이 |
|------|------|
| **Singleton(싱글톤)** | 앱 전체에서 인스턴스가 하나만 존재하는 객체. `.shared`로 접근(예: `StorageManager.shared`). |
| **@MainActor** | 이 코드는 항상 메인 스레드(UI 스레드)에서 돈다는 표시. UI 갱신 안전성용. |
| **actor** | 내부 상태를 동시 접근으로부터 자동 보호하는 Swift 동시성 타입. `VideoProcessingService`가 actor. |
| **@AppStorage** | UserDefaults(앱 설정 저장소)에 값을 저장/읽기하는 SwiftUI 프로퍼티 래퍼. |
| **@Published / ObservableObject** | 값이 바뀌면 SwiftUI 화면을 자동 갱신하게 하는 상태 관리 도구. |
| **DispatchSourceTimer** | 정해진 간격마다 코드를 실행하는 타이머(GCD 기반). 스크린샷 주기 캡처에 사용. |
