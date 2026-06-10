import CloudKit
import Foundation

// HANDOFF/13 §4, §7 — CloudKit schema definitions: container, zone, record
// types, and field keys. Centralised so RecordMapper and CloudSyncManager share
// one source of truth for what syncs and under which names.
//
// Scope note (HANDOFF/13 §10): Phase 1–3 syncs `timeline_cards` only. Journal /
// goals / standup / observations / ratings are Phase 4 — their schema columns
// already exist (Phase 1 migration) but their record types are added here when
// that phase lands. The control-plane `RecordingLease` (§14) is not a data
// table; it lives in the same zone as a single shared record.
enum SyncSchema {

  /// iCloud container id. Must match the entitlement added during provisioning
  /// (HANDOFF/13 §8). Inert until that capability exists in the signed build.
  static let containerIdentifier = "iCloud.so.dayflow"

  /// Single custom zone holds all of the user's synced records, enabling
  /// atomic multi-record changes and zone-wide change tracking.
  static let zoneName = "DayflowZone"
  static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

  enum RecordType: String {
    case timelineCard = "TimelineCard"
    case recordingLease = "RecordingLease"
  }

  /// CKRecord field keys for `TimelineCard`. Encrypted fields hold AES-GCM
  /// `Data` (HANDOFF/13 §15); the rest are plaintext because the engine needs
  /// them for ordering, dedup, and filtering.
  enum CardField {
    // Plaintext (queryable / sortable / dedup keys)
    static let startTs = "startTs"
    static let endTs = "endTs"
    static let day = "day"
    static let category = "category"
    static let subcategory = "subcategory"
    static let sourceTimezone = "sourceTimezone"
    static let isDeleted = "isDeleted"
    static let deletedAt = "deletedAt"
    static let updatedAt = "updatedAt"
    // Encrypted (sensitive screen-derived text)
    static let titleEnc = "titleEnc"
    static let summaryEnc = "summaryEnc"
    static let detailedSummaryEnc = "detailedSummaryEnc"
    static let metadataEnc = "metadataEnc"
    static let startClockEnc = "startClockEnc"  // "h:mm a" label
    static let endClockEnc = "endClockEnc"
    // NOTE deliberately NOT synced: batch_id (local FK, §C2),
    // video_summary_url (local path, §G3), confidence / source_summary /
    // needs_review (per-device analysis quality).
  }

  static func recordID(forUUID uuid: String) -> CKRecord.ID {
    CKRecord.ID(recordName: uuid, zoneID: zoneID)
  }
}
