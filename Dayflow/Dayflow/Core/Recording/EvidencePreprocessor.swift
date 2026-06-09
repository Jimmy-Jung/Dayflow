//
//  EvidencePreprocessor.swift
//  Dayflow
//
//  Assembles per-frame CaptureEvidence from the captured image and activity
//  metadata: perceptual hash, near-duplicate flag, local OCR, browser/dev signals,
//  and a coarse per-frame confidence hint. See HANDOFF/12 (§5/§6).
//
//  This runs off the main actor inside the capture task. It performs no DB writes;
//  it only reads the previous frame's hash (passed in) to decide near-duplicate.
//

import CoreGraphics
import Foundation

enum EvidencePreprocessor {
  /// Builds evidence for a normal (non-redacted) capture.
  /// - Parameters:
  ///   - image: the captured frame (full screenshot, pre-JPEG).
  ///   - metadata: frontmost-app metadata (already privacy-gated).
  ///   - previousHash: most recent stored image hash, for near-duplicate detection.
  static func process(
    image: CGImage,
    metadata: ActivityMetadata,
    previousHash: String?
  ) -> CaptureEvidence {
    let imageHash = ScreenshotFingerprint.averageHash(of: image)
    let isNearDuplicate = ScreenshotFingerprint.isNearDuplicate(
      current: imageHash, previous: previousHash)

    // OCR only on the normal path (collector already redacts blocked apps, but be
    // defensive — never OCR a redacted frame).
    let ocr: LocalOCR.Result? =
      metadata.privacyState == .normal ? LocalOCR.extractText(from: image) : nil

    let hint = confidenceHint(
      metadata: metadata, ocr: ocr, isNearDuplicate: isNearDuplicate)

    return CaptureEvidence(
      imageHash: imageHash,
      visibleText: ocr?.text,
      visibleTextHash: ocr?.hash,
      isNearDuplicate: isNearDuplicate,
      confidenceHint: hint,
      browserHost: metadata.browserHost,
      gitBranch: metadata.gitBranch
    )
  }

  /// Coarse per-frame evidence-quality hint (doc §5-3). Aggregated later by
  /// ConfidenceEstimator into a per-card confidence.
  static func confidenceHint(
    metadata: ActivityMetadata,
    ocr: LocalOCR.Result?,
    isNearDuplicate: Bool
  ) -> String {
    if metadata.privacyState == .redacted { return "low" }
    let hasApp = metadata.activeAppName != nil
    let hasTitle = metadata.windowTitle != nil
    // Low-confidence OCR is supporting evidence only (doc §11-4): it does not count
    // toward "high". Only reliable OCR promotes the frame.
    let hasReliableOCR = (ocr?.confidence ?? 0) >= LocalOCR.minReliableConfidence

    if hasApp && hasTitle && hasReliableOCR && !isNearDuplicate { return "high" }
    if hasApp || hasTitle { return "medium" }
    return "low"
  }
}
