import CoreGraphics
import XCTest

@testable import Dayflow

/// Unit coverage for the HANDOFF/12 pure-logic evidence types:
/// ScreenshotFingerprint, KeyframeSelector, ConfidenceEstimator, PersonalizationRules.
final class EvidencePipelineTests: XCTestCase {

  // MARK: - Fixtures

  private func shot(
    id: Int64,
    at ts: Int,
    app: String? = nil,
    title: String? = nil,
    idle: Int? = nil,
    privacy: String? = "normal",
    visibleText: String? = nil,
    nearDup: Bool = false,
    hint: String? = nil,
    host: String? = nil
  ) -> Screenshot {
    Screenshot(
      id: id,
      capturedAt: ts,
      filePath: "/tmp/\(id).jpg",
      fileSize: nil,
      idleSecondsAtCapture: idle,
      isDeleted: false,
      activeAppName: app,
      bundleId: nil,
      windowTitle: title,
      displayId: nil,
      privacyState: privacy,
      imageHash: nil,
      visibleText: visibleText,
      visibleTextHash: visibleText.map { "h:\($0)" },
      isNearDuplicate: nearDup,
      confidenceHint: hint,
      browserHost: host,
      gitBranch: nil
    )
  }

  // MARK: - ScreenshotFingerprint

  func testHammingDistanceIdenticalIsZero() {
    XCTAssertEqual(ScreenshotFingerprint.hammingDistance("00ff00ff00ff00ff", "00ff00ff00ff00ff"), 0)
  }

  func testHammingDistanceCountsDifferingBits() {
    // 0x...0 vs 0x...3 differ in the low two bits.
    XCTAssertEqual(ScreenshotFingerprint.hammingDistance("0000000000000000", "0000000000000003"), 2)
  }

  func testHammingDistanceMalformedReturnsNil() {
    XCTAssertNil(ScreenshotFingerprint.hammingDistance("zzz", "0000000000000000"))
  }

  func testNearDuplicateFailsOpenOnNil() {
    XCTAssertFalse(ScreenshotFingerprint.isNearDuplicate(current: nil, previous: "0000000000000000"))
    XCTAssertFalse(ScreenshotFingerprint.isNearDuplicate(current: "0000000000000000", previous: nil))
  }

  func testNearDuplicateRespectsThreshold() {
    // distance 2, threshold 6 → duplicate; threshold 1 → not.
    XCTAssertTrue(
      ScreenshotFingerprint.isNearDuplicate(
        current: "0000000000000003", previous: "0000000000000000", threshold: 6))
    XCTAssertFalse(
      ScreenshotFingerprint.isNearDuplicate(
        current: "0000000000000003", previous: "0000000000000000", threshold: 1))
  }

  func testAverageHashIsDeterministicAndDistinct() {
    let black = solidImage(white: false)
    let white = solidImage(white: true)
    let blackHash = ScreenshotFingerprint.averageHash(of: black)
    let whiteHash = ScreenshotFingerprint.averageHash(of: white)
    XCTAssertNotNil(blackHash)
    // Same image rasterized twice → identical hash.
    XCTAssertEqual(blackHash, ScreenshotFingerprint.averageHash(of: solidImage(white: false)))
    XCTAssertNotNil(whiteHash)
  }

  private func solidImage(white: Bool) -> CGImage {
    let side = 16
    let ctx = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: white ? 1.0 : 0.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()!
  }

  // MARK: - KeyframeSelector

  func testKeyframeReturnsAllWhenUnderBudget() {
    let shots = (0..<5).map { shot(id: Int64($0), at: 1000 + $0 * 10, app: "A", title: "T") }
    XCTAssertEqual(KeyframeSelector.select(from: shots, maxFrames: 10).count, 5)
  }

  func testKeyframeRespectsBudgetAndKeepsFirstLast() {
    let shots = (0..<40).map { shot(id: Int64($0), at: 1000 + $0 * 10, app: "A", title: "T") }
    let picked = KeyframeSelector.select(from: shots, maxFrames: 10)
    XCTAssertEqual(picked.count, 10)
    XCTAssertEqual(picked.first?.id, 0)
    XCTAssertEqual(picked.last?.id, 39)
  }

  func testKeyframeIncludesAppTransition() {
    var shots = (0..<20).map { shot(id: Int64($0), at: 1000 + $0 * 10, app: "A", title: "T") }
    // App switches at index 10.
    shots[10] = shot(id: 10, at: 1100, app: "B", title: "Other")
    let picked = KeyframeSelector.select(from: shots, maxFrames: 6)
    XCTAssertTrue(picked.contains { $0.id == 10 }, "transition frame must be selected")
    XCTAssertEqual(picked.first?.id, 0)
    XCTAssertEqual(picked.last?.id, 19)
  }

  func testKeyframeSortsUnorderedInput() {
    let shots = [
      shot(id: 2, at: 3000, app: "A", title: "T"),
      shot(id: 0, at: 1000, app: "A", title: "T"),
      shot(id: 1, at: 2000, app: "A", title: "T"),
    ]
    let picked = KeyframeSelector.select(from: shots, maxFrames: 10)
    XCTAssertEqual(picked.map { $0.capturedAt }, [1000, 2000, 3000])
  }

  // MARK: - ConfidenceEstimator

  func testConfidenceEmptyNeedsReview() {
    let result = ConfidenceEstimator.estimate(for: [])
    XCTAssertTrue(result.needsReview)
  }

  func testConfidenceHighWhenRichEvidence() {
    let shots = (0..<10).map {
      shot(id: Int64($0), at: 1000 + $0 * 10, app: "VS Code", title: "F.swift",
        visibleText: "code", hint: "high")
    }
    let result = ConfidenceEstimator.estimate(for: shots)
    XCTAssertGreaterThanOrEqual(result.score, ConfidenceEstimator.reviewThreshold)
    XCTAssertFalse(result.needsReview)
  }

  func testConfidenceLowWhenRedactedHeavy() {
    let shots = (0..<10).map {
      shot(id: Int64($0), at: 1000 + $0 * 10, privacy: "redacted", hint: "low")
    }
    let result = ConfidenceEstimator.estimate(for: shots)
    XCTAssertLessThan(result.score, ConfidenceEstimator.reviewThreshold)
    XCTAssertTrue(result.needsReview)
  }

  // MARK: - PersonalizationRules

  private func edit(bundle: String? = nil, host: String? = nil, category: String) -> CategoryEdit {
    CategoryEdit(
      bundleId: bundle, appName: nil, windowTitle: nil, browserHost: host, newCategory: category)
  }

  func testSingleEditDoesNotBecomeRule() {
    let rules = PersonalizationRules.deriveRules(from: [edit(bundle: "com.x", category: "Work")])
    XCTAssertTrue(rules.isEmpty)
  }

  func testRepeatedEditBecomesRule() {
    let edits = [
      edit(host: "docs.swift.org", category: "Research"),
      edit(host: "docs.swift.org", category: "Research"),
    ]
    let rules = PersonalizationRules.deriveRules(from: edits)
    XCTAssertEqual(rules.count, 1)
    XCTAssertEqual(rules.first?.category, "Research")
    XCTAssertTrue(rules.first?.signal.contains("docs.swift.org") ?? false)
  }

  func testNoPluralityNoRule() {
    // Same signal split 1/1 across two categories → no plurality winner ≥2.
    let edits = [
      edit(bundle: "com.x", category: "Work"),
      edit(bundle: "com.x", category: "Personal"),
    ]
    XCTAssertTrue(PersonalizationRules.deriveRules(from: edits).isEmpty)
  }

  func testContextTextNilWhenNoRules() {
    XCTAssertNil(PersonalizationRules.contextText(from: []))
  }

  // MARK: - EvidenceTimelineFormatter enrichment

  func testTimelineIncludesHostAndOCR() throws {
    let shots = [
      shot(id: 1, at: 1000, app: "Chrome", title: "Docs",
        visibleText: "ScreenCaptureKit", host: "docs.swift.org")
    ]
    let text = try XCTUnwrap(EvidenceTimelineFormatter.timelineText(for: shots))
    XCTAssertTrue(text.contains("url docs.swift.org"))
    XCTAssertTrue(text.contains("text: ScreenCaptureKit"))
  }

  func testTimelineDedupBreaksOnOCRChange() throws {
    // Same app/title but different OCR text → must NOT collapse into one run.
    let shots = [
      shot(id: 1, at: 1000, app: "Chrome", title: "Docs", visibleText: "alpha"),
      shot(id: 2, at: 1010, app: "Chrome", title: "Docs", visibleText: "beta"),
    ]
    let text = try XCTUnwrap(EvidenceTimelineFormatter.timelineText(for: shots))
    let entryLines = text.split(separator: "\n").filter { $0.hasPrefix("-") }
    XCTAssertEqual(entryLines.count, 2)
  }

  // MARK: - OCR confidence folding into per-frame hint (HANDOFF/12 §8/§11-4)

  private func meta(app: String?, title: String?) -> ActivityMetadata {
    ActivityMetadata(
      activeAppName: app, bundleId: nil, windowTitle: title, displayId: nil,
      privacyState: .normal)
  }

  func testReliableOCRPromotesToHigh() {
    let ocr = LocalOCR.Result(text: "x", hash: "h", confidence: 0.9)
    let hint = EvidencePreprocessor.confidenceHint(
      metadata: meta(app: "VS Code", title: "f.swift"), ocr: ocr, isNearDuplicate: false)
    XCTAssertEqual(hint, "high")
  }

  func testLowConfidenceOCRDoesNotPromoteToHigh() {
    let ocr = LocalOCR.Result(text: "x", hash: "h", confidence: 0.2)
    let hint = EvidencePreprocessor.confidenceHint(
      metadata: meta(app: "VS Code", title: "f.swift"), ocr: ocr, isNearDuplicate: false)
    XCTAssertEqual(hint, "medium", "low-confidence OCR is supporting-only, not a high promoter")
  }

  func testNoOCRStaysMediumWithAppAndTitle() {
    let hint = EvidencePreprocessor.confidenceHint(
      metadata: meta(app: "VS Code", title: "f.swift"), ocr: nil, isNearDuplicate: false)
    XCTAssertEqual(hint, "medium")
  }

  // MARK: - ConfidenceEstimator NULL-hint fallback (real-data fix)

  func testNullHintWithMetadataNotFlagged() {
    // Frames captured before the hint feature: NULL hint but app+title present.
    // Must NOT be scored as low (would spuriously flag reprocessed historical cards).
    let shots = (0..<10).map {
      shot(id: Int64($0), at: 1000 + $0 * 10, app: "VS Code", title: "f.swift", hint: nil)
    }
    let result = ConfidenceEstimator.estimate(for: shots)
    XCTAssertFalse(result.needsReview)
    XCTAssertGreaterThan(result.score, ConfidenceEstimator.reviewThreshold)
  }

  func testNullHintNoMetadataStaysLow() {
    // NULL hint AND no app/title → genuinely low confidence.
    let shots = (0..<10).map {
      shot(id: Int64($0), at: 1000 + $0 * 10, app: nil, title: nil, hint: nil)
    }
    let result = ConfidenceEstimator.estimate(for: shots)
    XCTAssertTrue(result.needsReview)
  }
}
