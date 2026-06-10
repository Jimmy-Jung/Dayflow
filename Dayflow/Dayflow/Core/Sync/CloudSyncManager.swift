import CloudKit
import Foundation
import os

// HANDOFF/13 §5, §7 — CKSyncEngine wrapper that drives offline-first sync of
// `timeline_cards`. Writes always land in local GRDB first (StorageManager);
// this engine pushes them to the user's private CloudKit database in the
// background and applies remote changes back through StorageManager+SyncData.
//
// Sync is OPT-IN and default-OFF (HANDOFF/13 §15/§G2): `isEnabled` gates engine
// creation and every enqueue, so a user who never turns it on pays nothing and
// no text ever leaves the device.
//
// Phase 1–3 scope (HANDOFF/13 §10): timeline_cards only. The lease control
// record (§14) is managed separately by RecordingLeaseController.
//
// NOTE: requires the iCloud/CloudKit entitlement + provisioned container to
// actually reach the network (HANDOFF/13 §8 — a manual provisioning step). The
// code compiles and runs without it; sync simply stays inert until enabled in a
// properly provisioned build.
final class CloudSyncManager: CKSyncEngineDelegate, @unchecked Sendable {
  static let shared = CloudSyncManager()

  static let enabledDefaultsKey = "cloudSyncEnabled"
  private let stateDefaultsKey = "cloudSync.stateSerialization"

  private let log = Logger(subsystem: "so.dayflow", category: "CloudSync")
  private let mapper = RecordMapper()
  private let lock = NSLock()
  private var _engine: CKSyncEngine?

  private init() {}

  /// Whether the user has opted into device-to-device sync.
  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }

  private var container: CKContainer {
    CKContainer(identifier: SyncSchema.containerIdentifier)
  }

  // MARK: - Lifecycle

  /// Turn sync on: persist the preference, build the engine, and queue the first
  /// full upload of existing cards. Safe to call repeatedly.
  func enable() {
    UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
    let isFirstRun = UserDefaults.standard.data(forKey: stateDefaultsKey) == nil
    let engine = ensureEngine()
    if isFirstRun {
      engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncSchema.zoneID))])
      let saves = StorageManager.shared.allSyncCardRecordNames().map {
        CKSyncEngine.PendingRecordZoneChange.saveRecord(SyncSchema.recordID(forUUID: $0))
      }
      engine.state.add(pendingRecordZoneChanges: saves)
      log.info("Sync enabled; queued initial upload of \(saves.count) cards")
    }
  }

  /// Turn sync off. Local data is untouched; the engine stops pushing/pulling.
  func disable() {
    UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
    lock.lock()
    _engine = nil
    lock.unlock()
    log.info("Sync disabled")
  }

  /// Recreate the engine on launch if the user previously enabled sync.
  func startIfEnabled() {
    guard Self.isEnabled else { return }
    _ = ensureEngine()
  }

  // MARK: - Local change intake

  /// Queue a local row change for upload. Called from the storage write path
  /// (StorageManager+Sync) once a card row's sync columns are stamped.
  func recordLocalChange(recordName: String, isDeletion: Bool) {
    guard Self.isEnabled else { return }
    let engine = ensureEngine()
    let id = SyncSchema.recordID(forUUID: recordName)
    engine.state.add(
      pendingRecordZoneChanges: [isDeletion ? .deleteRecord(id) : .saveRecord(id)])
  }

  private func ensureEngine() -> CKSyncEngine {
    lock.lock()
    defer { lock.unlock() }
    if let _engine { return _engine }
    var config = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase,
      stateSerialization: loadState(),
      delegate: self)
    config.automaticallySync = true
    let engine = CKSyncEngine(config)
    _engine = engine
    return engine
  }

  // MARK: - State persistence

  private func loadState() -> CKSyncEngine.State.Serialization? {
    guard let data = UserDefaults.standard.data(forKey: stateDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  private func saveState(_ serialization: CKSyncEngine.State.Serialization) {
    if let data = try? JSONEncoder().encode(serialization) {
      UserDefaults.standard.set(data, forKey: stateDefaultsKey)
    }
  }

  // MARK: - CKSyncEngineDelegate

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    switch event {
    case .stateUpdate(let event):
      saveState(event.stateSerialization)
    case .accountChange(let event):
      handleAccountChange(event)
    case .fetchedRecordZoneChanges(let event):
      handleFetchedRecordZoneChanges(event)
    case .sentRecordZoneChanges(let event):
      handleSentRecordZoneChanges(event, syncEngine: syncEngine)
    case .fetchedDatabaseChanges, .sentDatabaseChanges,
      .willFetchChanges, .willFetchRecordZoneChanges,
      .didFetchRecordZoneChanges, .didFetchChanges,
      .willSendChanges, .didSendChanges:
      break
    @unknown default:
      log.info("Unknown sync event")
    }
  }

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let scope = context.options.scope
    let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
    let mapper = self.mapper
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
      guard let payload = StorageManager.shared.syncFetchCardPayload(uuid: recordID.recordName)
      else {
        // Row vanished before upload — drop the stale pending change.
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
      }
      return try? mapper.record(from: payload)
    }
  }

  // MARK: - Event handlers

  private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
    // HANDOFF/13 §E2: on sign-out / account switch, drop the engine so cached
    // zone tokens for the old account are discarded. Local data stays put.
    switch event.changeType {
    case .signOut, .switchAccounts:
      disable()
    case .signIn:
      if Self.isEnabled { _ = ensureEngine() }
    @unknown default:
      break
    }
  }

  private func handleFetchedRecordZoneChanges(
    _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
  ) {
    for modification in event.modifications {
      guard modification.record.recordType == SyncSchema.RecordType.timelineCard.rawValue else {
        continue
      }
      if let payload = try? mapper.payload(from: modification.record) {
        StorageManager.shared.syncUpsertRemoteCard(payload)
      }
    }
    for deletion in event.deletions {
      StorageManager.shared.syncApplyRemoteDeletion(uuid: deletion.recordID.recordName)
    }
  }

  private func handleSentRecordZoneChanges(
    _ event: CKSyncEngine.Event.SentRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) {
    for saved in event.savedRecords {
      StorageManager.shared.syncSaveSystemFields(
        uuid: saved.recordID.recordName, data: RecordMapper.encodeSystemFields(saved))
    }

    var retry = [CKSyncEngine.PendingRecordZoneChange]()
    var retryZones = [CKSyncEngine.PendingDatabaseChange]()
    for failed in event.failedRecordSaves {
      let recordID = failed.record.recordID
      switch failed.error.code {
      case .serverRecordChanged:
        // Merge the authoritative server version locally (LWW), then re-queue our
        // save so a genuinely newer local edit still wins (HANDOFF/13 §6/§F4).
        if let server = failed.error.serverRecord {
          if let payload = try? mapper.payload(from: server) {
            StorageManager.shared.syncUpsertRemoteCard(payload)
          }
          StorageManager.shared.syncSaveSystemFields(
            uuid: server.recordID.recordName, data: RecordMapper.encodeSystemFields(server))
        }
        retry.append(.saveRecord(recordID))
      case .zoneNotFound:
        retryZones.append(.saveZone(CKRecordZone(zoneID: recordID.zoneID)))
        retry.append(.saveRecord(recordID))
      case .unknownItem:
        retry.append(.saveRecord(recordID))
      case .networkFailure, .networkUnavailable, .zoneBusy,
        .serviceUnavailable, .notAuthenticated, .operationCancelled:
        break  // engine retries automatically
      default:
        log.error("Unhandled sync save error: \(failed.error.code.rawValue)")
      }
    }
    if !retryZones.isEmpty { syncEngine.state.add(pendingDatabaseChanges: retryZones) }
    if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
  }
}
