//
//  ActivityMetadataCollector.swift
//  Dayflow
//
//  Collects lightweight activity metadata (frontmost app, window title, display)
//  alongside each screenshot so the analysis pipeline has structured evidence in
//  addition to the image. See HANDOFF/12-screenshot-analysis-enhancement.md (Phase 1).
//
//  Privacy: the collector consults RecordingPrivacyPreferences FIRST. When the
//  frontmost application is blocked, it returns a redacted record that carries no
//  app name, bundle id, or window title — only `privacyState == .redacted`.
//
//  Permission: window titles are read via CGWindowListCopyWindowInfo + kCGWindowName.
//  This is EXPECTED to require only the Screen Recording permission Dayflow already
//  holds (not the separate Accessibility permission) — VERIFY AT RUNTIME by confirming a
//  non-redacted `screenshots` row gets a populated `window_title`. If titles are always
//  nil, the mechanism is wrong; only `window_title` is affected — `active_app_name` /
//  `bundle_id` come from NSWorkspace and are unaffected.
//

import AppKit
import CoreGraphics
import Foundation

/// Per-screenshot activity metadata. All fields are optional so historical rows
/// (captured before this feature) and redacted captures remain representable.
struct ActivityMetadata: Sendable, Equatable {
  enum PrivacyState: String, Sendable {
    case normal
    case redacted
  }

  let activeAppName: String?
  let bundleId: String?
  let windowTitle: String?
  let displayId: Int?
  let privacyState: PrivacyState
  // Higher-value evidence signals (HANDOFF/12 §7-3). Both opt-in and nil for
  // redacted captures; routed into CaptureEvidence by the recorder.
  let browserHost: String?
  let gitBranch: String?

  init(
    activeAppName: String?,
    bundleId: String?,
    windowTitle: String?,
    displayId: Int?,
    privacyState: PrivacyState,
    browserHost: String? = nil,
    gitBranch: String? = nil
  ) {
    self.activeAppName = activeAppName
    self.bundleId = bundleId
    self.windowTitle = windowTitle
    self.displayId = displayId
    self.privacyState = privacyState
    self.browserHost = browserHost
    self.gitBranch = gitBranch
  }

  static let empty = ActivityMetadata(
    activeAppName: nil,
    bundleId: nil,
    windowTitle: nil,
    displayId: nil,
    privacyState: .normal
  )
}

enum ActivityMetadataCollector {
  /// Collects metadata for the current frontmost application.
  ///
  /// Must run on the main actor because it reads `NSWorkspace.frontmostApplication`.
  /// - Parameter displayID: The display currently being captured (recorder-supplied).
  @MainActor
  static func collect(displayID: CGDirectDisplayID?) -> ActivityMetadata {
    let displayIdValue = displayID.map { Int($0) }

    guard let app = NSWorkspace.shared.frontmostApplication else {
      return ActivityMetadata(
        activeAppName: nil,
        bundleId: nil,
        windowTitle: nil,
        displayId: displayIdValue,
        privacyState: .normal
      )
    }

    let bundleId = app.bundleIdentifier
    let appName = app.localizedName

    // Privacy gate first: never read or store details for a blocked app.
    if RecordingPrivacyPreferences.isApplicationBlocked(
      bundleIdentifier: bundleId,
      applicationName: appName
    ) {
      return ActivityMetadata(
        activeAppName: nil,
        bundleId: nil,
        windowTitle: nil,
        displayId: displayIdValue,
        privacyState: .redacted
      )
    }

    let windowTitle = frontmostWindowTitle(pid: app.processIdentifier)?.nonEmpty

    // Higher-value signals (opt-in, fail-safe to nil). Only collected on the
    // normal (non-redacted) path so blocked apps never leak a URL or branch.
    let browserHost = ActivitySignalProbe.browserHost(bundleId: bundleId?.nonEmpty)
    let gitBranch = ActivitySignalProbe.gitBranchHint(
      bundleId: bundleId?.nonEmpty, windowTitle: windowTitle)

    return ActivityMetadata(
      activeAppName: appName?.nonEmpty,
      bundleId: bundleId?.nonEmpty,
      windowTitle: windowTitle,
      displayId: displayIdValue,
      privacyState: .normal,
      browserHost: browserHost,
      gitBranch: gitBranch
    )
  }

  /// Reads the title of the frontmost on-screen window owned by `pid`.
  ///
  /// On-screen windows are returned front-to-back, so the first layer-0 window
  /// belonging to the app is its top window. Returns nil when the title is
  /// unavailable (empty, or the app exposes no named window).
  private static func frontmostWindowTitle(pid: pid_t) -> String? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
      let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else {
      return nil
    }

    for info in infoList {
      guard
        let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
        ownerPID == pid
      else { continue }

      // Layer 0 is the normal window layer; skip menus, status items, etc.
      let layer = info[kCGWindowLayer as String] as? Int ?? 0
      guard layer == 0 else { continue }

      if let name = (info[kCGWindowName as String] as? String)?.nonEmpty {
        return name
      }
    }
    return nil
  }
}

private extension String {
  /// Trims whitespace and returns nil if nothing remains.
  var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
