/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical
@testable import LexicalCore

// MARK: - RopeTextStorage Tests

final class RopeTextStorageTests: XCTestCase {

  // MARK: 3.1 - NSTextStorage subclass skeleton

  func testBasicInstantiation() {
    let storage = RopeTextStorage()
    XCTAssertNotNil(storage)
    XCTAssertEqual(storage.length, 0)
  }

  func testInstantiationWithContent() {
    let storage = RopeTextStorage(string: "hello")
    XCTAssertEqual(storage.length, 5)
    XCTAssertEqual(storage.string, "hello")
  }

  // MARK: 3.2 - length property

  func testLengthEmpty() {
    let storage = RopeTextStorage()
    XCTAssertEqual(storage.length, 0)
  }

  func testLengthAfterInsert() {
    let storage = RopeTextStorage()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")
    XCTAssertEqual(storage.length, 5)
  }

  func testLengthAfterDelete() {
    let storage = RopeTextStorage(string: "hello world")
    storage.replaceCharacters(in: NSRange(location: 5, length: 6), with: "")
    XCTAssertEqual(storage.length, 5)
    XCTAssertEqual(storage.string, "hello")
  }

  func testLengthWithEmoji() {
    let storage = RopeTextStorage(string: "👋🌍")
    XCTAssertEqual(storage.length, 4) // 2 UTF-16 code units per emoji
  }

  // MARK: 3.3 - replaceCharacters(in:with:)

  func testReplaceAtStart() {
    let storage = RopeTextStorage(string: "world")
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello ")
    XCTAssertEqual(storage.string, "hello world")
  }

  func testReplaceAtEnd() {
    let storage = RopeTextStorage(string: "hello")
    storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")
    XCTAssertEqual(storage.string, "hello world")
  }

  func testReplaceInMiddle() {
    let storage = RopeTextStorage(string: "hello world")
    storage.replaceCharacters(in: NSRange(location: 6, length: 5), with: "there")
    XCTAssertEqual(storage.string, "hello there")
  }

  func testReplaceWithShorter() {
    let storage = RopeTextStorage(string: "hello world")
    storage.replaceCharacters(in: NSRange(location: 6, length: 5), with: "!")
    XCTAssertEqual(storage.string, "hello !")
    XCTAssertEqual(storage.length, 7)
  }

  func testReplaceWithLonger() {
    let storage = RopeTextStorage(string: "hi")
    storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "hello world")
    XCTAssertEqual(storage.string, "hello world")
    XCTAssertEqual(storage.length, 11)
  }

  func testDeleteAll() {
    let storage = RopeTextStorage(string: "hello")
    storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "")
    XCTAssertEqual(storage.string, "")
    XCTAssertEqual(storage.length, 0)
  }

  func testReplaceWithAttributedString() {
    let storage = RopeTextStorage(string: "hello")
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    let attrStr = NSAttributedString(string: " world", attributes: attrs)

    storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: attrStr)

    XCTAssertEqual(storage.string, "hello world")

    var range = NSRange()
    let resultAttrs = storage.attributes(at: 6, effectiveRange: &range)
    XCTAssertNotNil(resultAttrs[.foregroundColor])
  }

  // MARK: 3.4 - attributes(at:effectiveRange:)

  func testAttributesAtIndexEmpty() {
    let storage = RopeTextStorage()
    // Empty storage - should not crash
    XCTAssertEqual(storage.length, 0)
  }

  func testAttributesAtIndexSimple() {
    let storage = RopeTextStorage()
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(string: "hello", attributes: attrs))

    var range = NSRange()
    let resultAttrs = storage.attributes(at: 2, effectiveRange: &range)

    XCTAssertNotNil(resultAttrs[.foregroundColor])
    XCTAssertEqual(range.location, 0)
    XCTAssertEqual(range.length, 5)
  }

  func testAttributesAtIndexMultipleRuns() {
    let storage = RopeTextStorage()
    let redAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    let blueAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.blue]

    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(string: "hel", attributes: redAttrs))
    storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: NSAttributedString(string: "lo", attributes: blueAttrs))

    XCTAssertEqual(storage.string, "hello")

    var range1 = NSRange()
    _ = storage.attributes(at: 1, effectiveRange: &range1)
    XCTAssertEqual(range1.location, 0)
    XCTAssertEqual(range1.length, 3)

    var range2 = NSRange()
    _ = storage.attributes(at: 4, effectiveRange: &range2)
    XCTAssertEqual(range2.location, 3)
    XCTAssertEqual(range2.length, 2)
  }

  // MARK: 3.5 - setAttributes(_:range:)

  func testSetAttributesOnRange() {
    let storage = RopeTextStorage(string: "hello world")
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]

    storage.setAttributes(attrs, range: NSRange(location: 0, length: 5))

    var range = NSRange()
    let resultAttrs = storage.attributes(at: 2, effectiveRange: &range)

    XCTAssertNotNil(resultAttrs[.foregroundColor])
    XCTAssertEqual(range.location, 0)
  }

  func testSetAttributesDoesNotAffectOtherRanges() {
    let storage = RopeTextStorage(string: "hello world")
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]

    storage.setAttributes(attrs, range: NSRange(location: 0, length: 5))

    // Check that "world" doesn't have the color
    var range = NSRange()
    let resultAttrs = storage.attributes(at: 8, effectiveRange: &range)

    // Should either be nil or different range
    XCTAssertTrue(range.location >= 5 || resultAttrs[.foregroundColor] == nil)
  }

  func testAddAttributesOnRange() {
    let storage = RopeTextStorage(string: "hello")
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.blue]

    storage.addAttributes(attrs, range: NSRange(location: 0, length: 5))

    var range = NSRange()
    let resultAttrs = storage.attributes(at: 2, effectiveRange: &range)

    XCTAssertNotNil(resultAttrs[.foregroundColor])
  }

  // MARK: 3.6 - string lazy materialization

  func testStringProperty() {
    let storage = RopeTextStorage(string: "hello world")
    XCTAssertEqual(storage.string, "hello world")
  }

  func testStringAfterModification() {
    let storage = RopeTextStorage(string: "hello")
    storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")
    XCTAssertEqual(storage.string, "hello world")
  }

  func testStringMultipleModifications() {
    let storage = RopeTextStorage()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")
    storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " ")
    storage.replaceCharacters(in: NSRange(location: 6, length: 0), with: "world")

    XCTAssertEqual(storage.string, "hello world")
  }

  // MARK: 3.7 - edited notifications

  func testEditedNotificationFires() {
    let storage = RopeTextStorage(string: "hello")

    var notificationReceived = false
    let observer = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification,
      object: storage,
      queue: nil
    ) { _ in
      notificationReceived = true
    }

    storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")

    // Give notification time to fire
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    NotificationCenter.default.removeObserver(observer)

    XCTAssertTrue(notificationReceived)
  }

  // MARK: 3.8 - Integration with Rope

  func testRopeIntegration() {
    let storage = RopeTextStorage()

    // Multiple inserts at different positions
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "world")
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello ")
    storage.replaceCharacters(in: NSRange(location: 11, length: 0), with: "!")

    XCTAssertEqual(storage.string, "hello world!")
    XCTAssertEqual(storage.length, 12)
  }

  func testMultipleEditsPerformance() {
    let storage = RopeTextStorage()

    // Keep this modest so the simulator doesn't watchdog-kill the test process.
    let insertCount = 200
    for i in 0..<insertCount {
      storage.replaceCharacters(in: NSRange(location: i, length: 0), with: "a")
    }

    XCTAssertEqual(storage.length, insertCount)

    // Delete from middle
    storage.replaceCharacters(in: NSRange(location: 80, length: 40), with: "")

    XCTAssertEqual(storage.length, 160)
  }

  // MARK: - NSTextStorage contract

  func testMutableStringReturnsCorrectValue() {
    let storage = RopeTextStorage(string: "hello")
    XCTAssertEqual(storage.mutableString.length, 5)
  }

  func testAttributedSubstring() {
    let storage = RopeTextStorage()
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(string: "hello world", attributes: attrs))

    let sub = storage.attributedSubstring(from: NSRange(location: 0, length: 5))
    XCTAssertEqual(sub.string, "hello")
    XCTAssertNotNil(sub.attributes(at: 0, effectiveRange: nil)[.foregroundColor])
  }
}
