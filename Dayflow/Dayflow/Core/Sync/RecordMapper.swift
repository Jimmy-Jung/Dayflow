import CloudKit
import Foundation

// HANDOFF/13 §7 — GRDB row ⇄ CKRecord translation for `timeline_cards`.
//
// `SyncCardPayload` is the storage-neutral shape the engine moves around;
// StorageManager+SyncData builds it from a row and writes it back. RecordMapper
// only knows CloudKit + crypto, never SQLite. Sensitive text is encrypted here
// (HANDOFF/13 §15); timestamps/day/category stay plaintext for dedup/ordering.

/// The syncable projection of a `timeline_cards` row. `ckSystemFields` is the
/// locally cached encoded CKRecord metadata (change tag) and never leaves the
/// device — it lets us update the existing server record instead of clobbering.
struct SyncCardPayload {
  var uuid: String
  var startTs: Int
  var endTs: Int
  var day: String
  var category: String
  var subcategory: String
  var sourceTimezone: String?
  var isDeleted: Bool
  var deletedAt: Int?
  var updatedAt: Int
  var startClock: String
  var endClock: String
  var title: String
  var summary: String?
  var detailedSummary: String?
  var metadata: String?
  var ckSystemFields: Data?
}

enum RecordMapperError: Error {
  case missingField(String)
}

struct RecordMapper {
  private let crypto: SyncCrypto

  init(crypto: SyncCrypto = .shared) {
    self.crypto = crypto
  }

  // MARK: - Local → CloudKit

  /// Build a CKRecord ready for upload. Reuses cached system fields so an update
  /// carries the server's change tag (avoids "record to update was not found"
  /// and accidental overwrites — HANDOFF/13 §F4).
  func record(from payload: SyncCardPayload) throws -> CKRecord {
    let record = baseRecord(uuid: payload.uuid, systemFields: payload.ckSystemFields)

    record[SyncSchema.CardField.startTs] = payload.startTs as CKRecordValue
    record[SyncSchema.CardField.endTs] = payload.endTs as CKRecordValue
    record[SyncSchema.CardField.day] = payload.day as CKRecordValue
    record[SyncSchema.CardField.category] = payload.category as CKRecordValue
    record[SyncSchema.CardField.subcategory] = payload.subcategory as CKRecordValue
    record[SyncSchema.CardField.sourceTimezone] = payload.sourceTimezone as CKRecordValue?
    record[SyncSchema.CardField.isDeleted] = (payload.isDeleted ? 1 : 0) as CKRecordValue
    record[SyncSchema.CardField.deletedAt] = payload.deletedAt as CKRecordValue?
    record[SyncSchema.CardField.updatedAt] = payload.updatedAt as CKRecordValue

    record[SyncSchema.CardField.titleEnc] = try crypto.encrypt(payload.title) as CKRecordValue?
    record[SyncSchema.CardField.summaryEnc] = try crypto.encrypt(payload.summary) as CKRecordValue?
    record[SyncSchema.CardField.detailedSummaryEnc] =
      try crypto.encrypt(payload.detailedSummary) as CKRecordValue?
    record[SyncSchema.CardField.metadataEnc] =
      try crypto.encrypt(payload.metadata) as CKRecordValue?
    record[SyncSchema.CardField.startClockEnc] =
      try crypto.encrypt(payload.startClock) as CKRecordValue?
    record[SyncSchema.CardField.endClockEnc] =
      try crypto.encrypt(payload.endClock) as CKRecordValue?

    return record
  }

  // MARK: - CloudKit → Local

  /// Decode a fetched CKRecord back into a payload for local upsert. Re-encodes
  /// the record's system fields so the next local edit can update it in place.
  func payload(from record: CKRecord) throws -> SyncCardPayload {
    func plaintextString(_ key: String) -> String? { record[key] as? String }
    func int(_ key: String) -> Int? { (record[key] as? Int64).map(Int.init) ?? record[key] as? Int }

    guard let startTs = int(SyncSchema.CardField.startTs),
      let endTs = int(SyncSchema.CardField.endTs),
      let day = plaintextString(SyncSchema.CardField.day),
      let category = plaintextString(SyncSchema.CardField.category)
    else {
      throw RecordMapperError.missingField("startTs/endTs/day/category")
    }

    let updatedAt = int(SyncSchema.CardField.updatedAt) ?? Int(Date().timeIntervalSince1970)
    let isDeleted = (int(SyncSchema.CardField.isDeleted) ?? 0) != 0

    return SyncCardPayload(
      uuid: record.recordID.recordName,
      startTs: startTs,
      endTs: endTs,
      day: day,
      category: category,
      subcategory: plaintextString(SyncSchema.CardField.subcategory) ?? "",
      sourceTimezone: plaintextString(SyncSchema.CardField.sourceTimezone),
      isDeleted: isDeleted,
      deletedAt: int(SyncSchema.CardField.deletedAt),
      updatedAt: updatedAt,
      startClock: try crypto.decrypt(record[SyncSchema.CardField.startClockEnc] as? Data) ?? "",
      endClock: try crypto.decrypt(record[SyncSchema.CardField.endClockEnc] as? Data) ?? "",
      title: try crypto.decrypt(record[SyncSchema.CardField.titleEnc] as? Data) ?? "",
      summary: try crypto.decrypt(record[SyncSchema.CardField.summaryEnc] as? Data),
      detailedSummary: try crypto.decrypt(
        record[SyncSchema.CardField.detailedSummaryEnc] as? Data),
      metadata: try crypto.decrypt(record[SyncSchema.CardField.metadataEnc] as? Data),
      ckSystemFields: Self.encodeSystemFields(record)
    )
  }

  // MARK: - System fields (server change-tag preservation)

  private func baseRecord(uuid: String, systemFields: Data?) -> CKRecord {
    if let systemFields, let decoded = Self.decodeSystemFields(systemFields) {
      return decoded
    }
    return CKRecord(
      recordType: SyncSchema.RecordType.timelineCard.rawValue,
      recordID: SyncSchema.recordID(forUUID: uuid))
  }

  /// Archive only the CKRecord system fields (id, change tag, zone) — not the
  /// user data — for local persistence.
  static func encodeSystemFields(_ record: CKRecord) -> Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    return coder.encodedData
  }

  static func decodeSystemFields(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    let record = CKRecord(coder: coder)
    coder.finishDecoding()
    return record
  }
}
