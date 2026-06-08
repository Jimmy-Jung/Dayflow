//
//  EvidenceTimelineFormatter.swift
//  Dayflow
//
//  Builds a compact text timeline of per-screenshot activity metadata (app name,
//  window title, idle, privacy state) to give the LLM structured evidence alongside
//  the screen frames. See HANDOFF/12-screenshot-analysis-enhancement.md (Phase 1, §5/§6).
//
//  IMPORTANT: this only produces *text*. It never drops or reorders frames, so it does
//  not affect any provider's frame↔timestamp mapping (e.g. Gemini's compressed-video
//  timestamp expansion). Near-duplicate runs are collapsed in the text as
//  "continued ×N" rather than by removing frames (doc §6-1, edge case 11-3).
//

import Foundation

enum EvidenceTimelineFormatter {
  /// Builds a metadata timeline block, or nil when there is no useful metadata
  /// (e.g. only historical rows captured before this feature existed).
  ///
  /// - Parameter screenshots: screenshots for the batch (any order; sorted internally).
  static func timelineText(for screenshots: [Screenshot]) -> String? {
    let ordered = screenshots.sorted { $0.capturedAt < $1.capturedAt }
    guard !ordered.isEmpty else { return nil }

    // Skip entirely if no row carries any activity metadata.
    let hasAnyMetadata = ordered.contains { shot in
      shot.activeAppName != nil || shot.windowTitle != nil || shot.privacyState == "redacted"
    }
    guard hasAnyMetadata else { return nil }

    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm:ss a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current

    var lines: [String] = []
    var index = 0
    while index < ordered.count {
      let shot = ordered[index]
      let key = dedupKey(for: shot)

      // Collapse consecutive frames that share the same dedup key.
      var runEnd = index
      while runEnd + 1 < ordered.count, dedupKey(for: ordered[runEnd + 1]) == key {
        runEnd += 1
      }
      let runCount = runEnd - index + 1

      let time = formatter.string(from: shot.capturedDate)
      let descriptor = descriptorText(for: shot)
      if runCount > 1 {
        lines.append("- \(time) | \(descriptor) (continued ×\(runCount))")
      } else {
        lines.append("- \(time) | \(descriptor)")
      }

      index = runEnd + 1
    }

    let header =
      "Local activity metadata captured on-device alongside the frames "
      + "(supporting evidence — the screen frames remain authoritative; entries may be "
      + "incomplete or stale, and private apps are hidden):"
    return ([header] + lines).joined(separator: "\n")
  }

  /// Identity used to collapse consecutive near-duplicate frames.
  private static func dedupKey(for shot: Screenshot) -> String {
    if shot.privacyState == "redacted" { return "redacted" }
    let app = shot.activeAppName ?? "?"
    let title = shot.windowTitle ?? "?"
    return "\(app)\u{1F}\(title)"
  }

  /// Human-readable single-frame descriptor.
  private static func descriptorText(for shot: Screenshot) -> String {
    if shot.privacyState == "redacted" {
      return "[private app hidden]"
    }

    var parts: [String] = []
    if let app = shot.activeAppName { parts.append(app) }
    if let title = shot.windowTitle { parts.append(title) }
    if parts.isEmpty { parts.append("unknown app") }

    var descriptor = parts.joined(separator: " — ")
    if let idle = shot.idleSecondsAtCapture, idle > 0 {
      descriptor += " | idle \(idle)s"
    }
    return descriptor
  }
}
