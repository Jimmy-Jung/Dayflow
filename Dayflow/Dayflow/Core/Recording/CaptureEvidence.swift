//
//  CaptureEvidence.swift
//  Dayflow
//
//  Carrier for per-screenshot evidence produced by on-device preprocessing
//  (fingerprint, OCR, browser/dev signals). See HANDOFF/12-screenshot-analysis-enhancement.md
//  (Phase 2/3, §5/§6/§8). Persisted alongside the screenshot row by
//  StorageManager.saveScreenshot(evidence:).
//
//  Privacy: the recorder must NOT populate visibleText / browserHost / gitBranch
//  for a redacted (privacy-blocked) capture. The collector/preprocessor enforce
//  this; `.redacted` is the safe default carrier for blocked frames.
//

import Foundation

struct CaptureEvidence: Sendable, Equatable {
  var imageHash: String?
  var visibleText: String?
  var visibleTextHash: String?
  var isNearDuplicate: Bool
  var confidenceHint: String?
  var browserHost: String?
  var gitBranch: String?

  static let empty = CaptureEvidence(
    imageHash: nil,
    visibleText: nil,
    visibleTextHash: nil,
    isNearDuplicate: false,
    confidenceHint: nil,
    browserHost: nil,
    gitBranch: nil
  )

  /// Carrier for a privacy-blocked capture: no text, URL, or dev signal is stored.
  /// An image hash is still allowed (the placeholder image carries no private data).
  static func redacted(imageHash: String?) -> CaptureEvidence {
    CaptureEvidence(
      imageHash: imageHash,
      visibleText: nil,
      visibleTextHash: nil,
      isNearDuplicate: false,
      confidenceHint: nil,
      browserHost: nil,
      gitBranch: nil
    )
  }
}

/// One user category correction, read back for personalization rule derivation
/// (HANDOFF/12 §7-2). Carries only the signals a rule keys on.
struct CategoryEdit: Sendable, Equatable {
  let bundleId: String?
  let appName: String?
  let windowTitle: String?
  let browserHost: String?
  let newCategory: String
}
