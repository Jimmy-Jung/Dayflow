# 13a. CloudKit 동기화 — 수동 프로비저닝 / 활성화 가이드

> [13. CloudKit 동기화 설계](13-cloud-sync.md)의 **구현 코드가 들어간 뒤** 필요한,
> 코드로는 자동화할 수 없는 수동 단계 모음. 이 단계들을 끝내기 전까지 동기화 코드는
> **컴파일·실행되지만 네트워크에 닿지 않는 비활성(inert) 상태**입니다.

---

## 0. 현재 구현 상태 (Phase 1–3 코드 골격 완료)

| 영역 | 파일 | 상태 |
|------|------|------|
| Phase 1 스키마 (uuid/updated_at/deleted_at/source_timezone/ck_system_fields + 백필 + partial unique index) | [StorageManager.swift](../Dayflow/Dayflow/Core/Recording/StorageManager.swift) 마이그레이션 블록 | ✅ 빌드·실행 검증 |
| INSERT/소프트삭제 경로 sync 컬럼 스탬프 | StorageManager+TimelineCards/Observations/TimelineReview.swift, [StorageManager+Sync.swift](../Dayflow/Dayflow/Core/Sync/StorageManager+Sync.swift) | ✅ 빌드 |
| E2E 암호화 (AES-GCM + iCloud Keychain 키) | [SyncCrypto.swift](../Dayflow/Dayflow/Core/Sync/SyncCrypto.swift) | ✅ 빌드 (런타임 미검증) |
| 스키마/매핑 (CKRecord ⇄ payload) | [SyncSchema.swift](../Dayflow/Dayflow/Core/Sync/SyncSchema.swift), [RecordMapper.swift](../Dayflow/Dayflow/Core/Sync/RecordMapper.swift) | ✅ 빌드 |
| CKSyncEngine 래퍼 + LWW 충돌 해결 | [CloudSyncManager.swift](../Dayflow/Dayflow/Core/Sync/CloudSyncManager.swift), [ConflictResolver.swift](../Dayflow/Dayflow/Core/Sync/ConflictResolver.swift), [StorageManager+SyncData.swift](../Dayflow/Dayflow/Core/Sync/StorageManager+SyncData.swift) | ✅ 빌드 (런타임 미검증) |
| 녹화 lease 핸드오프 + 안정 deviceID | [RecordingLeaseController.swift](../Dayflow/Dayflow/Core/Sync/RecordingLeaseController.swift), [DeviceIdentity.swift](../Dayflow/Dayflow/Core/Sync/DeviceIdentity.swift) | ✅ 빌드 (런타임 미검증) |

> **범위**: Phase 1–3 = `timeline_cards`만 동기화. journal/goals/standup/observations/ratings는
> Phase 4 — 스키마 컬럼은 이미 추가됨, 레코드 타입/매퍼 확장만 남음.

⚠️ **런타임 미검증**: CloudKit 네트워크 경로(암호화 왕복·양방향·lease)는 프로비저닝된 컨테이너 +
2대 Mac이 있어야 실제로 동작 확인 가능. 아래 단계 완료 후 §13 §10의 검증 절차를 수행할 것.

---

## 1. ⚠️ entitlements — 코드로 커밋하지 말 것 (서명 실패 위험)

프로비저닝되지 않은 컨테이너 id를 `Dayflow.entitlements`에 넣으면 **자동 서명이 실패해 빌드가
깨집니다.** 그래서 코드 골격에는 포함하지 않았습니다. Apple Developer 포털에서 컨테이너를 만든
**뒤에** Xcode가 직접 entitlement를 추가하도록 합니다.

### 권장 절차 (Xcode UI)
1. Apple Developer 포털 → Certificates, Identifiers & Profiles → Identifiers → App ID(`so.dayflow`)에
   **iCloud** capability 활성화.
2. iCloud Containers에서 **`iCloud.so.dayflow`** 컨테이너 생성
   (코드 상수 [`SyncSchema.containerIdentifier`](../Dayflow/Dayflow/Core/Sync/SyncSchema.swift)와 반드시 일치).
3. Xcode → Dayflow 타깃 → Signing & Capabilities → **+ Capability → iCloud** → **CloudKit** 체크 →
   위 컨테이너 선택. Xcode가 `Dayflow.entitlements`에 아래를 자동 추가:
   ```xml
   <key>com.apple.developer.icloud-services</key>
   <array><string>CloudKit</string></array>
   <key>com.apple.developer.icloud-container-identifiers</key>
   <array><string>iCloud.so.dayflow</string></array>
   ```
4. 추가 후 `xcodebuild`가 자동 서명으로 정상 빌드되는지 먼저 확인하고 커밋.

> Info.plist 변경은 **불필요**합니다. CKSyncEngine + Private DB만 쓰므로
> `NSUbiquitousContainers` 등은 필요 없습니다.

---

## 2. CloudKit Dashboard 스키마 등록

CKSyncEngine은 레코드를 push할 때 필드를 만들지만, **쿼리/인덱스는 수동 등록**이 안전합니다.
[CloudKit Console](https://icloud.developer.apple.com/) → `iCloud.so.dayflow` → Schema:

### Record Type: `TimelineCard`
([RecordMapper.swift](../Dayflow/Dayflow/Core/Sync/RecordMapper.swift)의 `CardField`와 일치)

| 필드 | 타입 | 비고 |
|------|------|------|
| `startTs`, `endTs`, `updatedAt`, `deletedAt`, `isDeleted` | Int(64) | 평문, 정렬/dedup |
| `day`, `category`, `subcategory`, `sourceTimezone` | String | 평문 |
| `titleEnc`, `summaryEnc`, `detailedSummaryEnc`, `metadataEnc`, `startClockEnc`, `endClockEnc` | Bytes | **AES-GCM 암호문** |

### Record Type: `RecordingLease`
([RecordingLeaseController.swift](../Dayflow/Dayflow/Core/Sync/RecordingLeaseController.swift))

| 필드 | 타입 |
|------|------|
| `holder`, `holderName` | String |
| `lastActiveAt` | Date/Time |

### Zone
- 커스텀 존 **`DayflowZone`** (코드가 `saveZone`으로 자동 생성하지만, 콘솔에서 확인).

> ⚠️ **출시 전 Production 배포 필수**: Dashboard에서 Development → **Deploy Schema Changes →
> Production**. 안 하면 App Store 빌드에서 쿼리가 조용히 빈 결과를 반환합니다(§13 cloud-sync
> Anti-Pattern #3, 가장 흔한 첫 출시 함정).

---

## 3. 동기화 켜기 (현재: UserDefaults 플래그, 설정 UI는 Phase 3+ 과제)

동기화는 **기본 OFF**, 명시적 옵트인입니다(§13 §15/§G2). 현재는 설정 토글 UI가 아직 없고,
다음 API로 제어합니다:

```swift
CloudSyncManager.shared.enable()   // 옵트인: UserDefaults "cloudSyncEnabled"=true + 첫 전체 업로드 큐잉
CloudSyncManager.shared.disable()  // 옵트아웃
```

- 앱 시작 시 [AppDelegate](../Dayflow/Dayflow/App/AppDelegate.swift)가
  `CloudSyncManager.shared.startIfEnabled()` + `RecordingLeaseController.shared.startIfEnabled()`를
  호출 — **OFF면 즉시 return**이라 일반 사용자 경로에 영향 없음.
- "이 기기에서 항상 녹화"(lease 무시, §H-5): `UserDefaults` 키
  `cloudSync.alwaysRecordThisDevice` = true.

### 남은 UI 작업 (Phase 3+)
- 설정에 "기기 간 동기화" 토글(기본 OFF) + "암호화되어 동기화됨" 고지 문구.
- 동기화 상태 인디케이터(대기/완료/충돌).

---

## 4. 검증 체크리스트 (프로비저닝 후)

1. 2대 Mac에 동일 iCloud 계정 로그인 + iCloud Drive ON.
2. A에서 `CloudSyncManager.shared.enable()` → 기존 카드 업로드 확인(CloudKit Console에서 레코드 수).
3. B에서도 enable → A의 카드가 B 타임라인에 나타나는지(복호화 성공 = 같은 iCloud Keychain 키 공유).
4. A에서 카드 수정 → B 반영(LWW), A에서 카드 삭제 → B에서 tombstone 처리 확인.
5. iCloud 끄기 → 앱이 오프라인 우선으로 정상 동작(녹화·로컬 저장 지속).
6. lease: A에서 입력 발생 → B 자동 일시정지, B로 이동 → A 자동 일시정지(핸드오프).
7. 출시 전 `/axiom:audit icloud`로 entitlement·CKError 매트릭스·계정 변경 관찰 감사(§13 §11).
