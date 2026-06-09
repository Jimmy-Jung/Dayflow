//
//  LocalOCR.swift
//  Dayflow
//
//  On-device text extraction via the Vision framework. See
//  HANDOFF/12-screenshot-analysis-enhancement.md (§5-2).
//
//  Purpose: give the LLM (and change-detection) a cheap, local read of on-screen
//  text so it doesn't have to read tiny text out of the image, and so we can
//  detect "screen changed" without a vision model.
//
//  Privacy (doc §11-2, §11-4): OCR turns on-screen private data into searchable
//  text — higher leakage risk than the image. Callers MUST gate on privacy state
//  BEFORE calling this (blocked apps never reach here), and OCR text is treated as
//  opt-in / local-only by RecordingPrivacyPreferences. Output is length-capped to
//  bound DB growth and WAL churn (§11-6).
//

import CoreGraphics
import CryptoKit
import Foundation
import Vision

enum LocalOCR {
  /// Hard cap on stored OCR text length (chars). Bounds DB size and WAL cost.
  static let maxTextLength = 2_000

  /// Mean per-line OCR confidence at/above which the text is treated as a reliable
  /// signal (HANDOFF/12 §11-4: low-confidence OCR is supporting-only). Tunable.
  static let minReliableConfidence = 0.5

  struct Result: Sendable, Equatable {
    let text: String
    let hash: String
    /// Mean Vision recognition confidence across the collected lines, [0, 1].
    let confidence: Double
  }

  /// Extracts visible text from a CGImage. Returns nil when OCR is disabled by
  /// preference, finds nothing, or fails. Uses the fast recognition path — this
  /// is supporting evidence, not authoritative (doc §5-2 caveat).
  static func extractText(from image: CGImage) -> Result? {
    guard RecordingPrivacyPreferences.isLocalOCREnabled else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return nil
    }

    guard let observations = request.results, !observations.isEmpty else { return nil }

    var collected: [String] = []
    var confidenceSum = 0.0
    var length = 0
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      collected.append(line)
      confidenceSum += Double(candidate.confidence)
      length += line.count + 1
      if length >= maxTextLength { break }
    }

    guard !collected.isEmpty else { return nil }
    var text = collected.joined(separator: "\n")
    if text.count > maxTextLength {
      text = String(text.prefix(maxTextLength))
    }

    // Mean per-line confidence (mean, not min — min is over-sensitive to a single
    // noisy line). Aggregated later into the per-frame confidence hint.
    let confidence = confidenceSum / Double(collected.count)

    let digest = SHA256.hash(data: Data(text.utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return Result(text: text, hash: hash, confidence: confidence)
  }
}
