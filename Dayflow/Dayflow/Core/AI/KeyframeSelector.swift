//
//  KeyframeSelector.swift
//  Dayflow
//
//  Selects which screenshots to send to an image-sampling LLM provider. See
//  HANDOFF/12-screenshot-analysis-enhancement.md (§6-2).
//
//  IMPORTANT (doc §11-3, advisor): this is for IMAGE-SAMPLING providers only
//  (Ollama, Chat CLI, Dayflow Backend). The Gemini path composites frames into a
//  compressed video and expands MM:SS timestamps by a compression factor — dropping
//  frames there breaks that mapping and trips the duration-validation, so Gemini
//  must NOT use this selector.
//
//  Guarantees:
//    • Always includes the first and last frame (so the LLM timeline covers the
//      whole batch and validation does not fail on uncovered edges).
//    • Prefers "transition" frames: app switch, window-title change, OCR-text
//      change, idle in/out — these carry the most information.
//    • Avoids spending budget on near-duplicate frames, but never drops a frame
//      purely because its image diff is small when a non-image signal changed
//      (doc §11-3: small-diff coding screens must not vanish).
//

import Foundation

enum KeyframeSelector {
  /// Returns at most `maxFrames` screenshots, sorted by capture time, always
  /// including the first and last. When the batch already fits, returns all.
  static func select(from screenshots: [Screenshot], maxFrames: Int) -> [Screenshot] {
    let sorted = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    guard maxFrames >= 2, sorted.count > maxFrames else { return sorted }

    let lastIndex = sorted.count - 1

    // 1. Boundary/transition indices — always meaningful.
    var priority = Set<Int>([0, lastIndex])
    for i in 1...lastIndex where isTransition(from: sorted[i - 1], to: sorted[i]) {
      priority.insert(i)
    }

    var chosen: Set<Int>
    if priority.count >= maxFrames {
      // Too many transitions: subsample them evenly, keeping first & last.
      chosen = evenlySubsample(Array(priority).sorted(), to: maxFrames, count: sorted.count)
    } else {
      // Fill remaining budget with evenly spaced frames across the timeline.
      chosen = priority
      let grid = evenIndices(total: sorted.count, pick: maxFrames)
      for index in grid where chosen.count < maxFrames && !chosen.contains(index) {
        chosen.insert(index)
      }
      // Top up from non-near-duplicate frames if the grid collided with existing picks.
      if chosen.count < maxFrames {
        let candidates = (0...lastIndex)
          .filter { !chosen.contains($0) }
          .sorted { lhs, rhs in
            let lDup = sorted[lhs].isNearDuplicate ? 1 : 0
            let rDup = sorted[rhs].isNearDuplicate ? 1 : 0
            if lDup != rDup { return lDup < rDup }  // non-duplicates first
            return lhs < rhs
          }
        var ci = 0
        while chosen.count < maxFrames && ci < candidates.count {
          chosen.insert(candidates[ci]); ci += 1
        }
      }
    }

    chosen.insert(0)
    chosen.insert(lastIndex)

    // Observable §10 metric: LLM-input frame reduction. Real-data verification reads
    // these logs (or compares llm_calls batch timing) for the 40–70% target.
    let kept = chosen.count
    let reduction = Int((1.0 - Double(kept) / Double(sorted.count)) * 100)
    print("📐 KeyframeSelector: kept \(kept)/\(sorted.count) frames (\(reduction)% fewer to LLM)")

    return chosen.sorted().map { sorted[$0] }
  }

  /// A frame is a "transition" when any non-trivial signal changed vs. the prior
  /// frame: app, window title, OCR text, browser host, or idle state crossing.
  private static func isTransition(from prev: Screenshot, to cur: Screenshot) -> Bool {
    if prev.activeAppName != cur.activeAppName { return true }
    if prev.windowTitle != cur.windowTitle { return true }
    if prev.visibleTextHash != cur.visibleTextHash
      && (prev.visibleTextHash != nil || cur.visibleTextHash != nil) { return true }
    if prev.browserHost != cur.browserHost { return true }
    let prevIdle = (prev.idleSecondsAtCapture ?? 0) > 60
    let curIdle = (cur.idleSecondsAtCapture ?? 0) > 60
    if prevIdle != curIdle { return true }
    return false
  }

  /// Evenly subsamples a sorted index list down to `target`, forcing the first
  /// and last of the *full* range (0 and count-1) to be present.
  private static func evenlySubsample(_ indices: [Int], to target: Int, count: Int) -> Set<Int> {
    guard indices.count > target else { return Set(indices) }
    var result = Set<Int>()
    if target >= 1 { result.insert(indices.first!) }
    if target >= 2 { result.insert(indices.last!) }
    let interior = target - result.count
    if interior > 0 {
      let step = Double(indices.count - 1) / Double(interior + 1)
      for k in 1...interior {
        let idx = Int((Double(k) * step).rounded())
        result.insert(indices[min(max(idx, 0), indices.count - 1)])
      }
    }
    result.insert(0)
    result.insert(count - 1)
    return result
  }

  /// `pick` evenly spaced indices across [0, total-1].
  private static func evenIndices(total: Int, pick: Int) -> [Int] {
    guard total > 0, pick > 0 else { return [] }
    if pick >= total { return Array(0..<total) }
    let step = Double(total - 1) / Double(pick - 1)
    return (0..<pick).map { Int((Double($0) * step).rounded()) }
  }
}
