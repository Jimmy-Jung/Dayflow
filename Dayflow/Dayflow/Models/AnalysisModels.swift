//
//  AnalysisModels.swift
//  Dayflow
//
//  Created on 5/1/2025.
//

import Foundation

/// Represents a recording chunk from the database (legacy - video-based)
struct RecordingChunk: Codable {
  let id: Int64
  let startTs: Int
  let endTs: Int
  let fileUrl: String
  let status: String

  var duration: TimeInterval {
    TimeInterval(endTs - startTs)
  }
}

/// Represents a screenshot capture from the database (new - replaces video chunks)
struct Screenshot: Codable, Sendable {
  let id: Int64
  let capturedAt: Int  // Unix timestamp (instant of capture)
  let filePath: String
  let fileSize: Int64?
  let idleSecondsAtCapture: Int?
  let isDeleted: Bool

  // Activity metadata (Phase 1, HANDOFF/12). Nullable — absent for historical rows
  // and for redacted (privacy-blocked) captures.
  let activeAppName: String?
  let bundleId: String?
  let windowTitle: String?
  let displayId: Int?
  let privacyState: String?  // "normal" | "redacted"

  // Evidence fields (Phase 2/3, HANDOFF/12 §5/§6/§8). All nullable; populated by
  // local preprocessing (fingerprint, OCR) and the extended metadata collector.
  let imageHash: String?            // perceptual hash (aHash/dHash) for near-duplicate detection
  let visibleText: String?          // local Vision OCR text (length-capped, privacy-gated)
  let visibleTextHash: String?      // hash of OCR text for cheap change detection
  let isNearDuplicate: Bool         // true when frame is a near-duplicate of the previous
  let confidenceHint: String?       // "high" | "medium" | "low" — per-frame evidence quality
  let browserHost: String?          // browser active-tab host (query redacted), or nil/"unknown"
  let gitBranch: String?            // current git branch when a dev tool is frontmost

  /// Explicit initializer with defaults for the metadata fields so existing
  /// call sites (e.g. VideoProcessingService URL fallback) remain valid.
  init(
    id: Int64,
    capturedAt: Int,
    filePath: String,
    fileSize: Int64?,
    idleSecondsAtCapture: Int?,
    isDeleted: Bool,
    activeAppName: String? = nil,
    bundleId: String? = nil,
    windowTitle: String? = nil,
    displayId: Int? = nil,
    privacyState: String? = nil,
    imageHash: String? = nil,
    visibleText: String? = nil,
    visibleTextHash: String? = nil,
    isNearDuplicate: Bool = false,
    confidenceHint: String? = nil,
    browserHost: String? = nil,
    gitBranch: String? = nil
  ) {
    self.id = id
    self.capturedAt = capturedAt
    self.filePath = filePath
    self.fileSize = fileSize
    self.idleSecondsAtCapture = idleSecondsAtCapture
    self.isDeleted = isDeleted
    self.activeAppName = activeAppName
    self.bundleId = bundleId
    self.windowTitle = windowTitle
    self.displayId = displayId
    self.privacyState = privacyState
    self.imageHash = imageHash
    self.visibleText = visibleText
    self.visibleTextHash = visibleTextHash
    self.isNearDuplicate = isNearDuplicate
    self.confidenceHint = confidenceHint
    self.browserHost = browserHost
    self.gitBranch = gitBranch
  }

  var fileURL: URL {
    URL(fileURLWithPath: filePath)
  }

  var capturedDate: Date {
    Date(timeIntervalSince1970: TimeInterval(capturedAt))
  }
}
