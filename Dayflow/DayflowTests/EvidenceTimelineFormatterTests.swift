import XCTest

@testable import Dayflow

final class EvidenceTimelineFormatterTests: XCTestCase {
  private func shot(
    id: Int64,
    at ts: Int,
    app: String? = nil,
    title: String? = nil,
    idle: Int? = nil,
    privacy: String? = "normal"
  ) -> Screenshot {
    Screenshot(
      id: id,
      capturedAt: ts,
      filePath: "/tmp/\(id).jpg",
      fileSize: nil,
      idleSecondsAtCapture: idle,
      isDeleted: false,
      activeAppName: app,
      bundleId: nil,
      windowTitle: title,
      displayId: nil,
      privacyState: privacy
    )
  }

  func testReturnsNilWhenNoMetadata() {
    let shots = [
      shot(id: 1, at: 1000, app: nil, title: nil, privacy: nil),
      shot(id: 2, at: 1010, app: nil, title: nil, privacy: nil),
    ]
    XCTAssertNil(EvidenceTimelineFormatter.timelineText(for: shots))
  }

  func testReturnsNilForEmptyInput() {
    XCTAssertNil(EvidenceTimelineFormatter.timelineText(for: []))
  }

  func testSingleFrameProducesHeaderAndOneLine() throws {
    let text = try XCTUnwrap(
      EvidenceTimelineFormatter.timelineText(for: [
        shot(id: 1, at: 1000, app: "Visual Studio Code", title: "SidebarView.swift")
      ]))
    let lines = text.split(separator: "\n")
    XCTAssertEqual(lines.count, 2)  // header + 1 entry
    XCTAssertTrue(text.contains("Visual Studio Code — SidebarView.swift"))
    XCTAssertFalse(text.contains("continued"))
  }

  func testConsecutiveDuplicatesCollapseIntoRun() throws {
    let shots = [
      shot(id: 1, at: 1000, app: "Chrome", title: "docs.swift.org"),
      shot(id: 2, at: 1010, app: "Chrome", title: "docs.swift.org"),
      shot(id: 3, at: 1020, app: "Chrome", title: "docs.swift.org"),
    ]
    let text = try XCTUnwrap(EvidenceTimelineFormatter.timelineText(for: shots))
    let entryLines = text.split(separator: "\n").filter { $0.hasPrefix("-") }
    XCTAssertEqual(entryLines.count, 1)
    XCTAssertTrue(text.contains("continued ×3"))
  }

  func testSwitchingActivityBreaksTheRun() throws {
    let shots = [
      shot(id: 1, at: 1000, app: "Chrome", title: "docs.swift.org"),
      shot(id: 2, at: 1010, app: "Chrome", title: "docs.swift.org"),
      shot(id: 3, at: 1020, app: "Xcode", title: "Main.swift"),
    ]
    let text = try XCTUnwrap(EvidenceTimelineFormatter.timelineText(for: shots))
    let entryLines = text.split(separator: "\n").filter { $0.hasPrefix("-") }
    XCTAssertEqual(entryLines.count, 2)
    XCTAssertTrue(text.contains("continued ×2"))
    XCTAssertTrue(text.contains("Xcode — Main.swift"))
  }

  func testRedactedFramesHideAppAndTitle() throws {
    let shots = [
      shot(id: 1, at: 1000, app: nil, title: nil, privacy: "redacted")
    ]
    let text = try XCTUnwrap(EvidenceTimelineFormatter.timelineText(for: shots))
    XCTAssertTrue(text.contains("[private app hidden]"))
  }

  func testIdleSecondsAppendedWhenPositive() throws {
    let text = try XCTUnwrap(
      EvidenceTimelineFormatter.timelineText(for: [
        shot(id: 1, at: 1000, app: "Slack", title: "general", idle: 42)
      ]))
    XCTAssertTrue(text.contains("idle 42s"))
  }

  func testUnsortedInputIsOrderedBeforeFormatting() throws {
    let shots = [
      shot(id: 2, at: 2000, app: "Xcode", title: "B.swift"),
      shot(id: 1, at: 1000, app: "Chrome", title: "A.com"),
    ]
    let text = try XCTUnwrap(EvidenceTimelineFormatter.timelineText(for: shots))
    let chromeRange = try XCTUnwrap(text.range(of: "Chrome"))
    let xcodeRange = try XCTUnwrap(text.range(of: "Xcode"))
    XCTAssertLessThan(chromeRange.lowerBound, xcodeRange.lowerBound)
  }
}
