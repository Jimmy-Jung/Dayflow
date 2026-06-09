//
//  ConfidenceEstimator.swift
//  Dayflow
//
//  Aggregates per-frame evidence quality into a per-card confidence score and a
//  human-readable source summary. See HANDOFF/12-screenshot-analysis-enhancement.md
//  (§5-3, §8). Low-confidence cards are flagged needs_review so the UI can surface
//  re-analysis without forcing the user to inspect every card.
//

import Foundation

enum ConfidenceEstimator {
  /// Cards scoring below this are flagged for review.
  static let reviewThreshold = 0.5

  struct Result: Sendable, Equatable {
    let score: Double          // [0, 1]
    let summary: String        // e.g. "apps 90% · titles 70% · ocr 40% · dup 10%"
    let needsReview: Bool
  }

  /// Estimates confidence for a card spanning the given evidence screenshots.
  static func estimate(for screenshots: [Screenshot]) -> Result {
    guard !screenshots.isEmpty else {
      return Result(score: 0.3, summary: "no evidence frames", needsReview: true)
    }

    let count = Double(screenshots.count)
    let appCoverage = ratio(screenshots) { $0.activeAppName != nil }
    let titleCoverage = ratio(screenshots) { $0.windowTitle != nil }
    let ocrCoverage = ratio(screenshots) { $0.visibleText != nil }
    let redactedRatio = ratio(screenshots) { $0.privacyState == "redacted" }
    let dupRatio = ratio(screenshots) { $0.isNearDuplicate }

    // Mean per-frame hint score.
    let hintScore = screenshots.reduce(0.0) { $0 + frameScore($1) } / count

    // Blend signals; penalize heavy duplication and redaction.
    var score =
      0.45 * hintScore
      + 0.25 * appCoverage
      + 0.15 * titleCoverage
      + 0.15 * ocrCoverage
    score -= 0.20 * dupRatio
    score -= 0.30 * redactedRatio
    score = min(1.0, max(0.0, score))

    let summary =
      "apps \(pct(appCoverage)) · titles \(pct(titleCoverage)) · "
      + "ocr \(pct(ocrCoverage)) · dup \(pct(dupRatio))"
      + (redactedRatio > 0 ? " · private \(pct(redactedRatio))" : "")

    return Result(score: score, summary: summary, needsReview: score < reviewThreshold)
  }

  /// Per-frame evidence-quality score in [0, 1].
  /// A NULL hint means the frame was captured BEFORE the hint feature existed — it
  /// must NOT be scored as "low" (0.25) when it still carries app/window metadata,
  /// or reprocessing historical days spuriously flags metadata-rich cards for
  /// review. Fall back to metadata presence instead. (Found via real-data review.)
  private static func frameScore(_ shot: Screenshot) -> Double {
    switch shot.confidenceHint {
    case "high": return 1.0
    case "medium": return 0.6
    case "low": return 0.25
    default:
      let hasApp = shot.activeAppName != nil
      let hasTitle = shot.windowTitle != nil
      if hasApp && hasTitle { return 0.6 }
      if hasApp || hasTitle { return 0.45 }
      return 0.25
    }
  }

  private static func ratio(_ shots: [Screenshot], _ predicate: (Screenshot) -> Bool) -> Double {
    guard !shots.isEmpty else { return 0 }
    return Double(shots.filter(predicate).count) / Double(shots.count)
  }

  private static func pct(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }
}
