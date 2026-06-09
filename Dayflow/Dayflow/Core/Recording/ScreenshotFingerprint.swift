//
//  ScreenshotFingerprint.swift
//  Dayflow
//
//  Cheap perceptual hash (average hash / aHash) for detecting near-duplicate
//  screen frames. See HANDOFF/12-screenshot-analysis-enhancement.md (§6-1).
//
//  The hash is a 64-bit fingerprint of an 8×8 grayscale downscale, serialized as
//  16 hex chars. Two frames are "near-duplicate" when their Hamming distance is
//  small. This NEVER deletes source frames — it only tags rows so the analysis
//  input can collapse runs (doc edge case §11-3: small image diff alone must not
//  hide meaningful work, so callers also weigh window title / OCR / idle).
//

import CoreGraphics
import Foundation

enum ScreenshotFingerprint {
  /// Default Hamming-distance threshold below which two frames count as duplicates.
  /// 64-bit hash; ≤6 differing bits ≈ visually identical.
  static let nearDuplicateThreshold = 6

  /// Computes a 64-bit average hash from a CGImage, as 16 lowercase hex chars.
  /// Returns nil if the image cannot be rasterized.
  static func averageHash(of image: CGImage) -> String? {
    let side = 8
    let bytesPerRow = side
    var pixels = [UInt8](repeating: 0, count: side * side)
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
      let ctx = CGContext(
        data: &pixels,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else {
      return nil
    }

    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

    let total = pixels.reduce(0) { $0 + Int($1) }
    let average = total / pixels.count

    var bits: UInt64 = 0
    for (index, pixel) in pixels.enumerated() where Int(pixel) >= average {
      bits |= (UInt64(1) << UInt64(index))
    }
    return String(format: "%016llx", bits)
  }

  /// Hamming distance between two hex-encoded hashes, or nil if either is malformed.
  static func hammingDistance(_ lhs: String, _ rhs: String) -> Int? {
    guard let a = UInt64(lhs, radix: 16), let b = UInt64(rhs, radix: 16) else { return nil }
    return (a ^ b).nonzeroBitCount
  }

  /// True when `current` is a near-duplicate of `previous`. Unknown/malformed
  /// hashes are treated as NOT duplicate (fail open — keep the frame).
  static func isNearDuplicate(
    current: String?,
    previous: String?,
    threshold: Int = nearDuplicateThreshold
  ) -> Bool {
    guard let current, let previous,
      let distance = hammingDistance(current, previous)
    else { return false }
    return distance <= threshold
  }
}
