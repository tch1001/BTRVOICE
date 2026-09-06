// Persistence tests for the cross-process insertion history used by app and keyboard.

import XCTest
@testable import Better_Voice

final class SharedTranscriptStoreTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var historyURL: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    historyURL = temporaryDirectory.appendingPathComponent("history.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  func testAnInsertionIsTrimmedPersistedAndLoadedNewestFirst() {
    let earlier = Date(timeIntervalSince1970: 10)
    let later = Date(timeIntervalSince1970: 20)

    let first = SharedTranscriptStore.recordInsertion("  first draft\n", at: earlier, to: historyURL)
    let second = SharedTranscriptStore.recordInsertion("second draft", at: later, to: historyURL)
    let loaded = SharedTranscriptStore.loadInsertionHistory(from: historyURL)

    XCTAssertEqual(first?.text, "first draft")
    XCTAssertEqual(second?.text, "second draft")
    XCTAssertEqual(loaded.map(\.text), ["second draft", "first draft"])
  }

  func testBlankTextIsNeverRecorded() {
    XCTAssertNil(SharedTranscriptStore.recordInsertion(" \n\t ", at: Date(), to: historyURL))
    XCTAssertTrue(SharedTranscriptStore.loadInsertionHistory(from: historyURL).isEmpty)
  }

  func testHistoryKeepsOnlyTheMostRecentEntries() {
    for index in 0..<(SharedTranscriptStore.insertionHistoryLimit + 4) {
      SharedTranscriptStore.recordInsertion(
        "entry \(index)",
        at: Date(timeIntervalSince1970: TimeInterval(index)),
        to: historyURL
      )
    }

    let loaded = SharedTranscriptStore.loadInsertionHistory(from: historyURL)
    XCTAssertEqual(loaded.count, SharedTranscriptStore.insertionHistoryLimit)
    XCTAssertEqual(loaded.first?.text, "entry 103")
    XCTAssertEqual(loaded.last?.text, "entry 4")
  }

  func testInvalidHistoryDataFailsClosed() throws {
    try Data("not json".utf8).write(to: historyURL)
    XCTAssertTrue(SharedTranscriptStore.loadInsertionHistory(from: historyURL).isEmpty)
  }
}
