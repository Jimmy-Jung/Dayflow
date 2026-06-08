import AppKit
import CoreGraphics
import Foundation

enum ScreenRecordingPermissionNotice {
  static var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Posts a request to surface the in-app permission notice.
  /// - Parameters:
  ///   - reason: Analytics/debug tag describing the trigger.
  ///   - force: When `true`, the notice is shown even if the user dismissed it
  ///     earlier this session. Use for explicit user actions (e.g. tapping Resume).
  static func post(reason: String, force: Bool = false) {
    let notification = {
      NotificationCenter.default.post(
        name: .showScreenRecordingPermissionNotice,
        object: nil,
        userInfo: ["reason": reason, "force": force]
      )
    }

    if Thread.isMainThread {
      notification()
    } else {
      DispatchQueue.main.async(execute: notification)
    }
  }

  private static let didRequestAccessKey = "didRequestScreenRecordingAccess"

  static func openSystemSettings() {
    // The native TCC request must fire at most once. Its only job here is to
    // register the app with TCC so it appears in the Screen Recording list (and
    // to show the system prompt on first run). A screen-recording grant does NOT
    // take effect in a running process — the app must be relaunched — so after
    // the user grants, this process keeps reporting "not granted". Re-issuing the
    // request on every tap would therefore re-show the system prompt in a loop.
    if !CGPreflightScreenCaptureAccess(),
      !UserDefaults.standard.bool(forKey: didRequestAccessKey)
    {
      UserDefaults.standard.set(true, forKey: didRequestAccessKey)
      _ = CGRequestScreenCaptureAccess()
    }

    // If access is already effective, there is no need to send the user to
    // System Settings at all.
    guard !CGPreflightScreenCaptureAccess() else { return }

    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    else { return }

    NSWorkspace.shared.open(url)
  }

  /// Quits and relaunches the app. A Screen Recording grant only takes effect in
  /// a freshly launched process, so once the user enables the toggle in System
  /// Settings the running instance still reports "not granted" until it restarts.
  @MainActor
  static func relaunch() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let bundlePath = Bundle.main.bundlePath
    let quoted = "'" + bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    // Wait for this process to fully exit, then open a fresh instance.
    let script =
      "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \(quoted)"

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", script]
    try? task.run()

    AppDelegate.allowTermination = true
    NSApp.terminate(nil)
  }
}
