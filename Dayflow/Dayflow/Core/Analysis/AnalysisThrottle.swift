//
//  AnalysisThrottle.swift
//  Dayflow
//
//  Decides whether the AUTOMATIC analysis tick should be deferred based on system
//  pressure. See HANDOFF/12-screenshot-analysis-enhancement.md (§6-3).
//
//  Capture and local preprocessing (fingerprint/OCR) keep running regardless —
//  only the expensive LLM batch processing is deferred. Deferral is non-destructive:
//  unprocessed screenshots remain queued and the next tick retries once pressure
//  clears. User-initiated reprocessing is never throttled.
//

import Foundation

enum AnalysisThrottle {
  /// True when automatic LLM analysis should be skipped this tick.
  static func shouldDeferAutomaticAnalysis() -> Bool {
    deferralReason() != nil
  }

  /// Human-readable reason for deferral, or nil when analysis may proceed.
  static func deferralReason() -> String? {
    let info = ProcessInfo.processInfo
    switch info.thermalState {
    case .serious:
      return "thermal state serious"
    case .critical:
      return "thermal state critical"
    default:
      break
    }
    if info.isLowPowerModeEnabled {
      return "low power mode enabled"
    }
    return nil
  }
}
