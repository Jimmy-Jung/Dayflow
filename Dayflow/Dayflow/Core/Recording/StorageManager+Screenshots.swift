import Foundation
import GRDB
import Sentry

extension StorageManager {
  // MARK: - Screenshot Management (new - replaces video chunks)

  func nextScreenshotURL() -> URL {
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmssSSS"
    return root.appendingPathComponent("\(df.string(from: Date())).jpg")
  }

  func saveScreenshot(
    url: URL,
    capturedAt: Date,
    idleSecondsAtCapture: Int?,
    metadata: ActivityMetadata,
    evidence: CaptureEvidence = .empty
  ) -> Int64? {
    let timestamp = Int(capturedAt.timeIntervalSince1970)
    let path = url.path
    let fileSize: Int64? = {
      if let attrs = try? fileMgr.attributesOfItem(atPath: path),
        let size = attrs[.size] as? NSNumber
      {
        return size.int64Value
      }
      return nil
    }()

    var screenshotId: Int64?
    try? timedWrite("saveScreenshot") { db in
      try db.execute(
        sql: """
              INSERT INTO screenshots(
                captured_at, file_path, file_size, idle_seconds_at_capture,
                active_app_name, bundle_id, window_title, display_id, privacy_state,
                image_hash, visible_text, visible_text_hash, is_near_duplicate,
                confidence_hint, browser_host, git_branch)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          timestamp, path, fileSize, idleSecondsAtCapture,
          metadata.activeAppName, metadata.bundleId, metadata.windowTitle,
          metadata.displayId, metadata.privacyState.rawValue,
          evidence.imageHash, evidence.visibleText, evidence.visibleTextHash,
          evidence.isNearDuplicate ? 1 : 0, evidence.confidenceHint,
          evidence.browserHost, evidence.gitBranch,
        ])
      screenshotId = db.lastInsertedRowID
    }
    return screenshotId
  }

  /// Most recent non-deleted screenshot's image hash, used by the recorder to
  /// decide whether the next frame is a near-duplicate. Returns nil when none.
  func lastScreenshotImageHash() -> String? {
    try? timedRead("lastScreenshotImageHash") { db in
      try String.fetchOne(
        db,
        sql: """
              SELECT image_hash FROM screenshots
              WHERE is_deleted = 0 AND image_hash IS NOT NULL
              ORDER BY captured_at DESC LIMIT 1
          """)
    } ?? nil
  }

  // MARK: - Category edit log (HANDOFF/12 §7-2)

  /// Appends a user category correction so the personalization engine can later
  /// derive SOFT rules from repeated patterns (never from a single edit).
  func logCategoryEdit(
    cardId: Int64?,
    bundleId: String?,
    appName: String?,
    windowTitle: String?,
    browserHost: String?,
    oldCategory: String?,
    newCategory: String
  ) {
    try? timedWrite("logCategoryEdit") { db in
      try db.execute(
        sql: """
              INSERT INTO category_edits(
                card_id, bundle_id, app_name, window_title, browser_host,
                old_category, new_category, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          cardId, bundleId, appName, windowTitle, browserHost,
          oldCategory, newCategory, Int(Date().timeIntervalSince1970),
        ])
    }
  }

  /// Returns category-edit rows for personalization rule derivation.
  func recentCategoryEdits(limit: Int = 500) -> [CategoryEdit] {
    (try? timedRead("recentCategoryEdits") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT bundle_id, app_name, window_title, browser_host, new_category
              FROM category_edits
              ORDER BY created_at DESC
              LIMIT ?
          """, arguments: [limit]
      )
      .map { row in
        CategoryEdit(
          bundleId: row["bundle_id"],
          appName: row["app_name"],
          windowTitle: row["window_title"],
          browserHost: row["browser_host"],
          newCategory: row["new_category"]
        )
      }
    }) ?? []
  }

  func screenshot(from row: Row) -> Screenshot {
    let columnNames = Set(row.columnNames)
    func value<T: DatabaseValueConvertible>(_ name: String, as type: T.Type) -> T? {
      columnNames.contains(name) ? row[name] : nil
    }
    return Screenshot(
      id: row["id"],
      capturedAt: row["captured_at"],
      filePath: row["file_path"],
      fileSize: row["file_size"],
      idleSecondsAtCapture: row["idle_seconds_at_capture"],
      isDeleted: (row["is_deleted"] as? Int ?? 0) != 0,
      activeAppName: row["active_app_name"],
      bundleId: row["bundle_id"],
      windowTitle: row["window_title"],
      displayId: row["display_id"],
      privacyState: row["privacy_state"],
      imageHash: value("image_hash", as: String.self),
      visibleText: value("visible_text", as: String.self),
      visibleTextHash: value("visible_text_hash", as: String.self),
      isNearDuplicate: (value("is_near_duplicate", as: Int.self) ?? 0) != 0,
      confidenceHint: value("confidence_hint", as: String.self),
      browserHost: value("browser_host", as: String.self),
      gitBranch: value("git_branch", as: String.self)
    )
  }

  func fetchUnprocessedScreenshots(since oldestTimestamp: Int) -> [Screenshot] {
    (try? timedRead("fetchUnprocessedScreenshots") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM screenshots
              WHERE captured_at >= ?
                AND is_deleted = 0
                AND id NOT IN (SELECT screenshot_id FROM batch_screenshots)
              ORDER BY captured_at ASC
          """, arguments: [oldestTimestamp]
      )
      .map(screenshot(from:))
    }) ?? []
  }

  func saveBatchWithScreenshots(startTs: Int, endTs: Int, screenshotIds: [Int64]) -> Int64? {
    guard !screenshotIds.isEmpty else { return nil }
    var batchId: Int64 = 0

    try? timedWrite("saveBatchWithScreenshots(\(screenshotIds.count))") { db in
      try db.execute(
        sql: """
              INSERT INTO analysis_batches(batch_start_ts, batch_end_ts)
              VALUES (?, ?)
          """, arguments: [startTs, endTs])
      batchId = db.lastInsertedRowID

      for id in screenshotIds {
        try db.execute(
          sql: """
                INSERT INTO batch_screenshots(batch_id, screenshot_id)
                VALUES (?, ?)
            """, arguments: [batchId, id])
      }
    }
    return batchId == 0 ? nil : batchId
  }

  func screenshotsForBatch(_ batchId: Int64) -> [Screenshot] {
    (try? timedRead("screenshotsForBatch") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT s.* FROM batch_screenshots bs
              JOIN screenshots s ON s.id = bs.screenshot_id
              WHERE bs.batch_id = ?
                AND s.is_deleted = 0
              ORDER BY s.captured_at ASC
          """, arguments: [batchId]
      )
      .map(screenshot(from:))
    }) ?? []
  }

  func fetchScreenshotsInTimeRange(startTs: Int, endTs: Int) -> [Screenshot] {
    (try? timedRead("fetchScreenshotsInTimeRange") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM screenshots
              WHERE captured_at >= ? AND captured_at <= ?
                AND is_deleted = 0
              ORDER BY captured_at ASC
          """, arguments: [startTs, endTs]
      )
      .map(screenshot(from:))
    }) ?? []
  }

}
