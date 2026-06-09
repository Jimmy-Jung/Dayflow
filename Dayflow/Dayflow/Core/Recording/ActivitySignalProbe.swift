//
//  ActivitySignalProbe.swift
//  Dayflow
//
//  Best-effort, privacy-bounded extraction of two higher-value evidence signals
//  (HANDOFF/12 §7-3, §11-4):
//    • browser active-tab HOST (query/path always dropped), and
//    • a git branch hint derived from a dev tool's window title.
//
//  Design constraints from the doc:
//    • Browser URL collection is OPT-IN and host-only — query strings can carry
//      tokens, search terms, document ids, emails (§11-2). We parse the host and
//      discard everything else.
//    • Collection failure is NOT an error — return nil (treated as `unknown`
//      downstream) and keep image/OCR fallback (§11-4).
//    • No subprocess spawning. The git branch is a *hint* read from the window
//      title only; we cannot know an arbitrary IDE's working directory, so this is
//      deliberately conservative (doc stores dev signals as "추정"/estimated).
//

import AppKit
import Foundation

enum ActivitySignalProbe {
  /// Known browsers and the AppleScript term for their active tab.
  /// Safari uses "current tab"; Chromium browsers use "active tab".
  private static let browserScripts: [String: String] = [
    "com.apple.Safari": "tell application \"Safari\" to return URL of current tab of front window",
    "com.google.Chrome":
      "tell application \"Google Chrome\" to return URL of active tab of front window",
    "com.microsoft.edgemac":
      "tell application \"Microsoft Edge\" to return URL of active tab of front window",
    "com.brave.Browser":
      "tell application \"Brave Browser\" to return URL of active tab of front window",
    "company.thebrowser.Browser":
      "tell application \"Arc\" to return URL of active tab of front window",
  ]

  /// Returns the active-tab host for a frontmost browser, or nil when collection
  /// is disabled, the app is not a known browser, or extraction fails.
  /// Only the host is returned — query and path are discarded.
  @MainActor
  static func browserHost(bundleId: String?) -> String? {
    guard RecordingPrivacyPreferences.isBrowserURLCollectionEnabled else { return nil }
    guard let bundleId, let script = browserScripts[bundleId] else { return nil }

    var errorInfo: NSDictionary?
    guard
      let appleScript = NSAppleScript(source: script),
      let output = appleScript.executeAndReturnError(&errorInfo).stringValue,
      errorInfo == nil,
      let components = URLComponents(string: output),
      let host = components.host?.lowercased(),
      !host.isEmpty
    else {
      return nil
    }
    return host
  }

  /// Common dev-tool bundle ids for which a branch hint is worth extracting.
  private static let devToolBundlePrefixes = [
    "com.microsoft.vscode",
    "com.todesktop",          // Cursor
    "com.apple.dt.xcode",
    "dev.zed.zed",
    "com.googlecode.iterm2",
    "com.apple.terminal",
    "com.sublimetext",
    "com.jetbrains",
  ]

  /// Extracts a git branch hint from a dev tool's window title, e.g. titles that
  /// embed "(branch)". Returns nil for non-dev apps or no match. This is a
  /// heuristic hint only (doc §11-4: store dev signals as estimated).
  static func gitBranchHint(bundleId: String?, windowTitle: String?) -> String? {
    guard let bundleId = bundleId?.lowercased(),
      devToolBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }),
      let title = windowTitle, !title.isEmpty
    else { return nil }

    // Match a parenthesized token that looks like a branch, e.g. "repo (main)".
    if let range = title.range(of: #"\(([\w./\-]+)\)"#, options: .regularExpression) {
      let inner = title[range].dropFirst().dropLast()
      let candidate = String(inner)
      if isPlausibleBranch(candidate) { return candidate }
    }
    return nil
  }

  private static func isPlausibleBranch(_ token: String) -> Bool {
    guard token.count >= 2, token.count <= 60 else { return false }
    // Branch-like: letters/digits and / . _ - only.
    let allowed = CharacterSet(charactersIn:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
    return token.unicodeScalars.allSatisfy { allowed.contains($0) }
  }
}
