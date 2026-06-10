import Foundation
import GRDB

// HANDOFF/13 Phase 1 — sync bookkeeping stamps.
//
// Every write path that creates or soft-deletes a sync-eligible row stamps the
// columns added in the Phase 1 migration (StorageManager.swift): `uuid`,
// `updated_at`, and — for timeline_cards — `source_timezone`. Deletions set
// `deleted_at` (tombstone) instead of hard-deleting, so the change can later be
// propagated to other devices (HANDOFF/13 §4, §16, §D1).
//
// These helpers run INSIDE an existing `timedWrite` transaction (callers pass
// the live `Database`), so they add no extra lock acquisition. The sync-engine
// nudge is attached in a later layer via `enqueueChange` (StorageManager+Sync
// is extended once CloudSyncManager exists); until then these are pure column
// stamps with no networking and no behavioural change while sync is OFF.
extension StorageManager {

  /// Tables keyed by an AUTOINCREMENT `id` that carry a device-stable `uuid`.
  enum SyncTable: String, CaseIterable {
    case timelineCards = "timeline_cards"
    case observations = "observations"
    case timelineReviewRatings = "timeline_review_ratings"
  }

  /// A freshly generated record key. Matches the migration backfill format.
  static func newSyncUUID() -> String { UUID().uuidString }

  /// Stamp sync bookkeeping on a row just inserted via `db.lastInsertedRowID`.
  /// Idempotent: `uuid`/`source_timezone` are only filled when still NULL, so a
  /// retried write never rewrites an existing key. `updated_at` is always bumped
  /// to "now" (the conflict-resolution hint; the CloudKit server change tag is
  /// the real ordering authority — HANDOFF/13 §16/B3).
  ///
  /// - Parameter setTimezone: pass `true` only for `timeline_cards`, the sole
  ///   table with a `source_timezone` column.
  func stampInsertedRow(
    _ db: Database, table: SyncTable, rowId: Int64, setTimezone: Bool = false
  ) throws {
    let now = Int(Date().timeIntervalSince1970)
    if setTimezone {
      try db.execute(
        sql: """
              UPDATE \(table.rawValue)
              SET uuid = COALESCE(uuid, ?),
                  updated_at = ?,
                  source_timezone = COALESCE(source_timezone, ?)
              WHERE id = ?
          """,
        arguments: [Self.newSyncUUID(), now, TimeZone.current.identifier, rowId])
    } else {
      try db.execute(
        sql: """
              UPDATE \(table.rawValue)
              SET uuid = COALESCE(uuid, ?), updated_at = ?
              WHERE id = ?
          """,
        arguments: [Self.newSyncUUID(), now, rowId])
    }
    enqueueChange(db, table: table, rowId: rowId, isDeletion: false)
  }

  /// Mark a row as a tombstone (soft delete) so the deletion propagates instead
  /// of silently vanishing on other devices (HANDOFF/13 §D1/§4). Bumps
  /// `updated_at` so last-writer-wins ordering still applies between a delete
  /// and a late edit on another device.
  func stampDeletedRow(_ db: Database, table: SyncTable, rowId: Int64) throws {
    let now = Int(Date().timeIntervalSince1970)
    try db.execute(
      sql: "UPDATE \(table.rawValue) SET deleted_at = ?, updated_at = ? WHERE id = ?",
      arguments: [now, now, rowId])
    enqueueChange(db, table: table, rowId: rowId, isDeletion: true)
  }

  /// Notify the sync engine of a pending change. A no-op while sync is disabled
  /// (the default) — the body is wired to CloudSyncManager in the sync-hooks
  /// layer. Kept as its own method so Phase 1 callers are already in place.
  func enqueueChange(_ db: Database, table: SyncTable, rowId: Int64, isDeletion: Bool) {
    CloudSyncBridge.shared.enqueue(db, table: table, rowId: rowId, isDeletion: isDeletion)
  }
}

/// Bridges the storage write path to the CloudKit engine. Reads the row's uuid
/// from the live transaction (cheap, same connection) and hands it to
/// CloudSyncManager. Fully short-circuits when sync is OFF, so the default
/// (opt-out) path does zero work beyond a bool check (HANDOFF/13 advisor note).
final class CloudSyncBridge: @unchecked Sendable {
  static var shared: CloudSyncBridge = CloudSyncBridge()

  func enqueue(
    _ db: GRDB.Database, table: StorageManager.SyncTable, rowId: Int64, isDeletion: Bool
  ) {
    guard CloudSyncManager.isEnabled else { return }
    // Phase 1–3 scope (HANDOFF/13 §10): only timeline_cards reach the engine.
    guard table == .timelineCards else { return }
    guard
      let uuid = try? String.fetchOne(
        db, sql: "SELECT uuid FROM \(table.rawValue) WHERE id = ?", arguments: [rowId]),
      !uuid.isEmpty
    else { return }
    CloudSyncManager.shared.recordLocalChange(recordName: uuid, isDeletion: isDeletion)
  }
}
