import CloudKit
import CoreGraphics
import Foundation
import os

// HANDOFF/13 §14 — "recording lease": at most one device records at a time, and
// recording follows the device the user is actually on. This is the structural
// fix for the A1 duplicate-card blocker (two devices analysing the same span).
//
// Mechanism: a single CloudKit control record names the current `holder`. The
// active device renews it; an idle holder releases it; a newly active device
// claims it. Ordering uses the lease record's server `modificationDate`, not the
// device clock (HANDOFF/13 §B3/H-1). The lease is a control record, NOT a data
// table — it never carries timeline content.
//
// Safety + inertness:
//  - Fully gated on `CloudSyncManager.isEnabled` and an "always record this
//    device" override (H-5). When sync is OFF (default), this never runs and the
//    recorder behaves exactly as before.
//  - It only toggles recording via `AppState.setRecording(persistPreference:
//    false)` and only resumes what IT paused (`pausedByLease`), so it never
//    overrides an explicit user pause.
//  - Offline / fetch failure → leave recording as-is (H-2: local solo recording
//    allowed); the dedup safety net (§H-3, sync merge) absorbs any overlap.
//
// ⚠️ Runtime-unverifiable here: needs the provisioned CloudKit container (§8)
// and two signed-in Macs to exercise. The code compiles and is inert until a
// properly provisioned build enables sync.
final class RecordingLeaseController: @unchecked Sendable {
  static let shared = RecordingLeaseController()

  static let alwaysRecordThisDeviceKey = "cloudSync.alwaysRecordThisDevice"

  private let log = Logger(subsystem: "so.dayflow", category: "RecordingLease")
  private let leaseRecordName = "recording-lease"

  private let renewInterval: TimeInterval = 45
  private let activeIdleThreshold: TimeInterval = 120  // active if input within this
  private let staleLeaseThreshold: TimeInterval = 180  // holder considered gone after
  private let releaseIdleThreshold: TimeInterval = 300  // release our lease after

  private let queue = DispatchQueue(label: "so.dayflow.lease")
  private var timer: DispatchSourceTimer?
  private var ticking = false
  private var pausedByLease = false

  private init() {}

  static var isEnabled: Bool {
    CloudSyncManager.isEnabled
      && !UserDefaults.standard.bool(forKey: alwaysRecordThisDeviceKey)
  }

  private var database: CKDatabase {
    CKContainer(identifier: SyncSchema.containerIdentifier).privateCloudDatabase
  }

  private var leaseRecordID: CKRecord.ID {
    CKRecord.ID(recordName: leaseRecordName, zoneID: SyncSchema.zoneID)
  }

  // MARK: - Lifecycle

  /// Start the lease loop if sync + handoff are enabled. No-op otherwise — safe
  /// to call unconditionally from app launch.
  func startIfEnabled() {
    guard Self.isEnabled else { return }
    queue.async { [weak self] in self?.startTimerLocked() }
  }

  func stop() {
    queue.async { [weak self] in
      self?.timer?.cancel()
      self?.timer = nil
    }
  }

  private func startTimerLocked() {
    guard timer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 2, repeating: renewInterval)
    t.setEventHandler { [weak self] in self?.tick() }
    timer = t
    t.resume()
    log.info("Recording lease loop started")
  }

  // MARK: - Tick

  private func tick() {
    guard Self.isEnabled, !ticking else {
      if !Self.isEnabled { stop() }
      return
    }
    ticking = true
    Task { [weak self] in
      await self?.evaluate()
      self?.queue.async { self?.ticking = false }
    }
  }

  /// One lease evaluation cycle.
  private func evaluate() async {
    let idleSeconds = Self.systemIdleSeconds()
    let weAreActive = idleSeconds < activeIdleThreshold
    let myID = DeviceIdentity.deviceID

    let existing = try? await fetchLease()  // nil on missing OR offline

    if weAreActive {
      let holder = existing?["holder"] as? String
      let holderActiveAt = existing?.modificationDate ?? .distantPast
      let holderIsStale = Date().timeIntervalSince(holderActiveAt) > staleLeaseThreshold

      if holder == nil || holder == myID || holderIsStale {
        // Free, ours, or abandoned → claim/renew and make sure we are recording.
        await claimLease(existing: existing, deviceID: myID)
        await resumeIfLeasePaused()
      } else {
        // Another device is actively holding → yield.
        await yieldToLease()
      }
    } else {
      // We are idle: if we hold the lease and have been idle long enough,
      // release it so another device can take over.
      if existing?["holder"] as? String == myID, idleSeconds > releaseIdleThreshold {
        await releaseLease(existing: existing)
      }
    }
  }

  // MARK: - CloudKit lease record

  private func fetchLease() async throws -> CKRecord? {
    do {
      return try await database.record(for: leaseRecordID)
    } catch let error as CKError where error.code == .unknownItem {
      return nil  // lease not created yet
    }
  }

  private func claimLease(existing: CKRecord?, deviceID: String) async {
    let record =
      existing
      ?? CKRecord(
        recordType: SyncSchema.RecordType.recordingLease.rawValue, recordID: leaseRecordID)
    record["holder"] = deviceID as CKRecordValue
    record["holderName"] = DeviceIdentity.deviceName as CKRecordValue
    record["lastActiveAt"] = Date() as CKRecordValue
    do {
      _ = try await database.save(record)
    } catch {
      // serverRecordChanged (another device claimed first) or offline — skip;
      // the next tick re-fetches and re-decides. Don't fight over the record.
      log.debug("Lease claim deferred: \(error.localizedDescription)")
    }
  }

  private func releaseLease(existing: CKRecord?) async {
    guard let record = existing else { return }
    record["holder"] = "" as CKRecordValue
    record["lastActiveAt"] = Date() as CKRecordValue
    _ = try? await database.save(record)
  }

  // MARK: - Recording control (only what we paused)

  @MainActor
  private func yieldToLease() {
    guard AppState.shared.isRecording else { return }
    AppState.shared.setRecording(false, analyticsReason: "lease_yield", persistPreference: false)
    queue.async { self.pausedByLease = true }
  }

  @MainActor
  private func resumeIfLeasePaused() {
    let shouldResume = queue.sync { pausedByLease }
    guard shouldResume, !AppState.shared.isRecording else { return }
    AppState.shared.setRecording(true, analyticsReason: "lease_claim", persistPreference: false)
    queue.async { self.pausedByLease = false }
  }

  // MARK: - System idle

  /// Seconds since the last user input event of any type.
  static func systemIdleSeconds() -> TimeInterval {
    let anyInput = CGEventType(rawValue: ~0) ?? .null
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }
}
