import Foundation
import GRDB

// HANDOFF/13 §5, §7 — storage-side read/write helpers the CloudKit engine uses.
//
// Upload side: read a card row → `SyncCardPayload` (CloudSyncManager encrypts &
// maps it to a CKRecord). Download side: apply a fetched payload back into
// `timeline_cards` with last-writer-wins (ConflictResolver), preserving the
// AUTOINCREMENT `id` and dropping the device-local `batch_id` FK (§C2).
//
// IMPORTANT: the remote-apply writes here deliberately bypass `stampInsertedRow`
// so they do NOT re-enqueue a change — otherwise an applied remote edit would
// bounce straight back to the server in an infinite loop.
extension StorageManager {

  // MARK: - Upload side

  /// Every card uuid, for the first full upload (enqueue saves for all of them).
  func allSyncCardRecordNames() -> [String] {
    (try? timedRead("allSyncCardRecordNames") { db in
      try String.fetchAll(db, sql: "SELECT uuid FROM timeline_cards WHERE uuid IS NOT NULL")
    }) ?? []
  }

  /// Read a single card as a sync payload, or nil if the row is gone.
  func syncFetchCardPayload(uuid: String) -> SyncCardPayload? {
    (try? timedRead("syncFetchCardPayload") { db -> SyncCardPayload? in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT * FROM timeline_cards WHERE uuid = ?", arguments: [uuid])
      else { return nil }
      return Self.cardPayload(from: row)
    }) ?? nil
  }

  private static func cardPayload(from row: Row) -> SyncCardPayload {
    let isDeletedInt: Int = row["is_deleted"] ?? 0
    return SyncCardPayload(
      uuid: row["uuid"] ?? "",
      startTs: row["start_ts"] ?? 0,
      endTs: row["end_ts"] ?? 0,
      day: row["day"] ?? "",
      category: row["category"] ?? "",
      subcategory: row["subcategory"] ?? "",
      sourceTimezone: row["source_timezone"],
      isDeleted: isDeletedInt != 0,
      deletedAt: row["deleted_at"],
      updatedAt: row["updated_at"] ?? 0,
      startClock: row["start"] ?? "",
      endClock: row["end"] ?? "",
      title: row["title"] ?? "",
      summary: row["summary"],
      detailedSummary: row["detailed_summary"],
      metadata: row["metadata"],
      ckSystemFields: row["ck_system_fields"]
    )
  }

  // MARK: - Download side

  /// Apply a fetched remote card to the local DB (insert or LWW update). Never
  /// re-enqueues (see file note). Stores the encoded server system fields so the
  /// next local edit updates the existing record in place.
  func syncUpsertRemoteCard(_ payload: SyncCardPayload) {
    try? timedWrite("syncUpsertRemoteCard") { db in
      let existing = try Row.fetchOne(
        db, sql: "SELECT id, updated_at FROM timeline_cards WHERE uuid = ?",
        arguments: [payload.uuid])

      if let existing {
        let localUpdatedAt: Int = existing["updated_at"] ?? 0
        guard
          ConflictResolver.decide(localUpdatedAt: localUpdatedAt, remoteUpdatedAt: payload.updatedAt)
            == .applyRemote
        else { return }
        let id: Int64 = existing["id"]
        try db.execute(
          sql: """
                UPDATE timeline_cards SET
                  start = ?, end = ?, start_ts = ?, end_ts = ?, day = ?,
                  title = ?, summary = ?, category = ?, subcategory = ?,
                  detailed_summary = ?, metadata = ?, is_deleted = ?,
                  deleted_at = ?, updated_at = ?, source_timezone = ?,
                  ck_system_fields = ?
                WHERE id = ?
            """,
          arguments: [
            payload.startClock, payload.endClock, payload.startTs, payload.endTs, payload.day,
            payload.title, payload.summary, payload.category, payload.subcategory,
            payload.detailedSummary ?? "", payload.metadata, payload.isDeleted ? 1 : 0,
            payload.deletedAt, payload.updatedAt, payload.sourceTimezone,
            payload.ckSystemFields, id,
          ])
      } else {
        try db.execute(
          sql: """
                INSERT INTO timeline_cards(
                    uuid, batch_id, start, end, start_ts, end_ts, day, title,
                    summary, category, subcategory, detailed_summary, metadata,
                    is_deleted, deleted_at, updated_at, source_timezone, ck_system_fields
                )
                VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            payload.uuid, payload.startClock, payload.endClock, payload.startTs, payload.endTs,
            payload.day, payload.title, payload.summary, payload.category, payload.subcategory,
            payload.detailedSummary ?? "", payload.metadata, payload.isDeleted ? 1 : 0,
            payload.deletedAt, payload.updatedAt, payload.sourceTimezone, payload.ckSystemFields,
          ])
      }
    }
  }

  /// Apply a remote deletion: tombstone the local row so the timeline hides it.
  func syncApplyRemoteDeletion(uuid: String) {
    let now = Int(Date().timeIntervalSince1970)
    try? timedWrite("syncApplyRemoteDeletion") { db in
      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET is_deleted = 1, deleted_at = COALESCE(deleted_at, ?), updated_at = ?
              WHERE uuid = ?
          """,
        arguments: [now, now, uuid])
    }
  }

  /// Cache the encoded CKRecord system fields after a successful upload so the
  /// next change carries the server change tag (HANDOFF/13 §F4).
  func syncSaveSystemFields(uuid: String, data: Data) {
    try? timedWrite("syncSaveSystemFields") { db in
      try db.execute(
        sql: "UPDATE timeline_cards SET ck_system_fields = ? WHERE uuid = ?",
        arguments: [data, uuid])
    }
  }
}
