# 12-검증: 스크린샷 분석 고도화 지표 측정 절차

> 작성일: 2026-06-09
>
> [12-screenshot-analysis-enhancement.md](12-screenshot-analysis-enhancement.md) §10 검증 지표를
> 실제로 측정하는 방법. 코드 구현·단위테스트는 완료됐으나, 아래 지표는 **실앱 + 실데이터
> 재처리**로만 측정 가능하다(헤드리스 빌드/단위테스트 범위 밖).

## 자동 검증 완료분 (헤드리스)

- `xcodebuild test -only-testing:DayflowTests -destination 'platform=macOS'` → 29개 통과.
  - ScreenshotFingerprint, KeyframeSelector, ConfidenceEstimator, PersonalizationRules,
    EvidenceTimelineFormatter 회귀 포함.
- 전체 앱 Debug 빌드 통과.

## 실데이터로만 측정 가능한 §10 지표

| 지표 | 측정 방법 |
|------|-----------|
| LLM 입력 프레임 40~70%↓ | 콘솔 로그 `📐 KeyframeSelector: kept N/M frames (X% fewer to LLM)` 집계. provider별(Ollama·ChatCLI 15, Backend 90) 배치 평균 X% 확인. |
| batch 처리 시간 30%↓ | `llm_calls` 테이블 `latency_ms`를 구/신 파이프라인 재처리 비교. |
| 사용자 수정 카드 비율↓ | `category_edits` 행 수 / 카드 수 추이. |
| 낮은 confidence 카드 비율 | `SELECT AVG(needs_review), AVG(confidence) FROM timeline_cards` 추이. |
| 앱명/파일명 오판율↓ | 동일 하루 구/신 카드 title/summary 샘플 수기 평가. |

## 권장 절차 (개발자 1회)

1. 실제 하루치 스크린샷이 쌓인 DB로 앱 실행.
2. 설정에서 OCR/브라우저 host 토글 ON(원하면) → 신규 evidence 수집 확인.
3. `reprocessDay(_:)`로 동일 하루 재처리 → 콘솔 KeyframeSelector 로그로 프레임 감소율 확인.
4. `llm_calls` latency, `timeline_cards` confidence/needs_review 분포 쿼리.
5. needs_review 뱃지 비율이 과도하면 `ConfidenceEstimator.reviewThreshold`(현재 0.5) 조정.

## 미검증 채널 (정직 고지)

- 브라우저 host 수집: 공증(hardened runtime) 빌드 + TCC 자동화 동의 후에만 실동작.
  엔타이틀먼트·Info.plist는 추가됨. 실제 동작은 배포 빌드에서 1회 확인 필요.
- DayflowUITests 번들은 헤드리스 실행 시 크래시(기존 UI 테스트 타깃 이슈, 본 작업 무관).
