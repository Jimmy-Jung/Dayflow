import Foundation
import ScreenCaptureKit

enum RecordingControlMode: Equatable {
  case active
  case pausedTimed(endTime: Date)
  case pausedIndefinite
  case stopped
}

@MainActor
enum RecordingControl {
  static func currentMode() -> RecordingControlMode {
    currentMode(appState: .shared, pauseManager: .shared)
  }

  static func currentMode(
    appState: AppState,
    pauseManager: PauseManager
  ) -> RecordingControlMode {
    if appState.isRecording && pauseManager.isPaused {
      assertionFailure("Recording cannot be active while pause metadata is still set")
      return .active
    }

    if let endTime = pauseManager.pauseEndTime {
      return .pausedTimed(endTime: endTime)
    }

    if pauseManager.isPausedIndefinitely {
      return .pausedIndefinite
    }

    return appState.isRecording ? .active : .stopped
  }

  static func start(reason: String) {
    Task { @MainActor in
      guard await hasScreenRecordingPermission() else {
        print("[RecordingControl] Screen recording permission not granted; start ignored")
        ScreenRecordingPermissionNotice.post(reason: "recording_control_start")
        return
      }

      PauseManager.shared.clearPauseState()
      AppState.shared.setRecording(true, analyticsReason: reason)
    }
  }

  static func stop(reason: String) {
    PauseManager.shared.clearPauseState()
    AppState.shared.setRecording(false, analyticsReason: reason)
  }

  /// Resumes recording from a paused state in response to an explicit user action.
  /// Verifies screen-recording permission first; if it is missing, the resume is
  /// blocked and the permission notice is surfaced (forced) so the user can jump
  /// to System Settings instead of silently failing to capture.
  /// - Returns: `true` if recording resumed, `false` if blocked by missing permission.
  @discardableResult
  static func resumeFromPause(source: ResumeSource, noticeReason: String) -> Bool {
    guard ScreenRecordingPermissionNotice.isGranted else {
      ScreenRecordingPermissionNotice.post(reason: noticeReason, force: true)
      return false
    }

    PauseManager.shared.resume(source: source)
    return true
  }

  /// Starts recording in response to an explicit user action (a Resume/Start tap).
  /// Performs a synchronous permission preflight so the caller can decide, in the
  /// same run loop turn, whether to advance its UI. If permission is missing the
  /// start is blocked and the permission notice is surfaced (forced); the caller
  /// must keep its UI in the not-recording state.
  /// - Returns: `true` if the start was dispatched, `false` if blocked.
  @discardableResult
  static func startFromUser(reason: String, noticeReason: String) -> Bool {
    guard ScreenRecordingPermissionNotice.isGranted else {
      ScreenRecordingPermissionNotice.post(reason: noticeReason, force: true)
      return false
    }

    start(reason: reason)
    return true
  }

  private static func hasScreenRecordingPermission() async -> Bool {
    guard CGPreflightScreenCaptureAccess() else { return false }

    do {
      _ = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
      return true
    } catch {
      return false
    }
  }
}
