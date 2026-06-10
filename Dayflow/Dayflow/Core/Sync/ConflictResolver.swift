import Foundation

// HANDOFF/13 §6, §16/B3 — conflict resolution policy for timeline_cards.
//
// Ordering authority is the CloudKit server change tag: the engine only hands
// us a remote record once the server has accepted an ordering, and on a
// rejected upload it returns `serverRecord` (handled in CloudSyncManager). The
// `updated_at` hint here is the tie-breaker / guard used when applying a fetched
// record over a local row — last-writer-wins (HANDOFF/13 §6: cards are AI
// output, minor overwrites acceptable).
//
// §A2 (preserve manual user edits over AI re-analysis) is a documented Phase-3+
// refinement; it needs a `user_edited` flag the schema does not yet carry, so
// for now LWW-by-updated_at applies uniformly — a manual edit that bumped
// updated_at most recently still wins by virtue of being the last writer.
enum ConflictResolver {
  enum Decision {
    case applyRemote
    case keepLocal
  }

  /// Decide whether an incoming remote version should overwrite the local row.
  /// `nil` local means there is no local row yet → always apply. Ties resolve to
  /// the remote (server authority).
  static func decide(localUpdatedAt: Int?, remoteUpdatedAt: Int) -> Decision {
    guard let localUpdatedAt else { return .applyRemote }
    return remoteUpdatedAt >= localUpdatedAt ? .applyRemote : .keepLocal
  }
}
