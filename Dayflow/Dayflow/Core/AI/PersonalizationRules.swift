//
//  PersonalizationRules.swift
//  Dayflow
//
//  Derives SOFT personalization hints from the user's category-edit history and
//  renders them as prompt context. See HANDOFF/12-screenshot-analysis-enhancement.md
//  (§7-2, §11-5).
//
//  Safety constraints from the doc (advisor-confirmed):
//    • Never a hard override in front of the LLM — these are weak priors injected
//      as prompt context; the screen content still decides (§12).
//    • Never promote a single edit to a rule — require a REPEATED pattern, and key
//      on stable signals (bundle id / host) rather than the volatile app name when
//      available (§11-5: same app serves many purposes).
//

import Foundation

enum PersonalizationRules {
  /// Minimum repeats before a corrected signal→category mapping becomes a hint.
  static let minOccurrences = 2

  struct Rule: Sendable, Equatable {
    let signal: String     // e.g. "host docs.swift.org" or "app com.microsoft.VSCode"
    let category: String
    let count: Int
  }

  /// Derives soft rules: for each stable signal, the category it was corrected to
  /// at least `minOccurrences` times AND that is the plurality choice for it.
  static func deriveRules(from edits: [CategoryEdit]) -> [Rule] {
    // signal -> (category -> count)
    var tally: [String: [String: Int]] = [:]
    for edit in edits {
      guard let signal = signalKey(for: edit) else { continue }
      tally[signal, default: [:]][edit.newCategory, default: 0] += 1
    }

    var rules: [Rule] = []
    for (signal, categories) in tally {
      guard let top = categories.max(by: { $0.value < $1.value }) else { continue }
      guard top.value >= minOccurrences else { continue }
      // Require plurality (more than half of edits for this signal agree).
      let total = categories.values.reduce(0, +)
      guard Double(top.value) > Double(total) / 2.0 else { continue }
      rules.append(Rule(signal: signal, category: top.key, count: top.value))
    }
    return rules.sorted { $0.count > $1.count }
  }

  /// Prompt context block of soft hints, or nil when there are none.
  static func contextText(from edits: [CategoryEdit], maxRules: Int = 12) -> String? {
    let rules = Array(deriveRules(from: edits).prefix(maxRules))
    guard !rules.isEmpty else { return nil }

    let lines = rules.map { rule in
      "- When \(rule.signal), the user usually labels it \"\(rule.category)\" "
        + "(corrected \(rule.count)×)."
    }
    let header =
      "User personalization hints (SOFT priors only — the on-screen activity still "
      + "decides the category; use these only to break ties or disambiguate):"
    return ([header] + lines).joined(separator: "\n")
  }

  /// Stable signal key for an edit: prefer host, then bundle id, then app name.
  private static func signalKey(for edit: CategoryEdit) -> String? {
    if let host = edit.browserHost, !host.isEmpty { return "host \(host)" }
    if let bundle = edit.bundleId, !bundle.isEmpty { return "app \(bundle)" }
    if let app = edit.appName, !app.isEmpty { return "app \(app)" }
    return nil
  }
}
