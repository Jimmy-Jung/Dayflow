//
//  ChatCLIProvider.swift
//  Dayflow
//
//  High-level LLM provider that uses ChatCLIRunner for CLI execution.
//

import AppKit
import Foundation

enum ChatCLIModelDefaults {
  static let codexAnalyticsModelName = "codex-default"

  static func model(for tool: ChatCLITool, claudeModel: String) -> String? {
    switch tool {
    case .codex:
      return nil
    case .claude:
      return claudeModel
    }
  }

  static func reasoningEffort(for tool: ChatCLITool, codexEffort: String?) -> String? {
    switch tool {
    case .codex:
      return codexEffort
    case .claude:
      return nil
    }
  }

  static func analyticsModelName(for tool: ChatCLITool, model: String?) -> String {
    if let model, !model.isEmpty {
      return model
    }

    switch tool {
    case .codex:
      return codexAnalyticsModelName
    case .claude:
      return "claude-default"
    }
  }
}

struct ChatCLIObservationsEnvelope: Codable {
  struct Item: Codable {
    let start: String
    let end: String
    let text: String
  }
  let observations: [Item]
}

struct ChatCLICardsEnvelope: Codable {
  struct Item: Codable {
    let start: String?
    let end: String?
    let startTime: String?
    let endTime: String?
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String?
    let distractions: [Distraction]?
    let appSites: AppSites?

    var normalizedStart: String? { start ?? startTime }
    var normalizedEnd: String? { end ?? endTime }
  }
  let cards: [Item]
}
