/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical
@testable import LexicalCore

// MARK: - AttributedChunk Tests

final class AttributedChunkTests: XCTestCase {

  // MARK: 2.1 - Basic AttributedChunk creation

  func testCreateEmptyChunk() {
    let chunk = AttributedChunk(text: "")
    XCTAssertEqual(chunk.length, 0)
    XCTAssertEqual(chunk.text, "")
    XCTAssertTrue(chunk.attributeRuns.isEmpty)
  }

  func testCreateChunkWithText() {
    let chunk = AttributedChunk(text: "hello")
    XCTAssertEqual(chunk.length, 5)
    XCTAssertEqual(chunk.text, "hello")
  }

  func testCreateChunkWithAttributes() {
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    let chunk = AttributedChunk(text: "hello", attributes: attrs)

    XCTAssertEqual(chunk.length, 5)
    XCTAssertEqual(chunk.attributeRuns.count, 1)
    XCTAssertEqual(chunk.attributeRuns[0].range, 0..<5)
  }

  func testChunkLengthWithEmoji() {
    let chunk = AttributedChunk(text: "👋🌍")
    // Each emoji is 2 UTF-16 code units
    XCTAssertEqual(chunk.length, 4)
  }

  // MARK: 2.2 - AttributeRun tracking

  func testMultipleAttributeRuns() {
    let runs: [AttributeRun] = [
      AttributeRun(range: 0..<3, attributes: [.foregroundColor: LexicalColor.red]),
      AttributeRun(range: 3..<5, attributes: [.foregroundColor: LexicalColor.blue]),
    ]
    let chunk = AttributedChunk(text: "hello", runs: runs)

    XCTAssertEqual(chunk.attributeRuns.count, 2)
    XCTAssertEqual(chunk.attributeRuns[0].range, 0..<3)
    XCTAssertEqual(chunk.attributeRuns[1].range, 3..<5)
  }

  func testAttributeRunsPreserved() {
    let runs: [AttributeRun] = [
      AttributeRun(range: 0..<2, attributes: [.font: LexicalFont.boldSystemFont(ofSize: 14)]),
      AttributeRun(range: 2..<5, attributes: [:]),
    ]
    let chunk = AttributedChunk(text: "hello", runs: runs)

    XCTAssertEqual(chunk.attributeRuns.count, 2)
  }

  // MARK: 2.3 - split(at:) with attrs

  func testSplitAtStart() {
    let chunk = AttributedChunk(text: "hello", attributes: [.foregroundColor: LexicalColor.red])
    let (left, right) = chunk.split(at: 0)

    XCTAssertEqual(left.length, 0)
    XCTAssertEqual(right.length, 5)
    XCTAssertEqual(right.text, "hello")
    XCTAssertEqual(right.attributeRuns.count, 1)
  }

  func testSplitAtEnd() {
    let chunk = AttributedChunk(text: "hello", attributes: [.foregroundColor: LexicalColor.red])
    let (left, right) = chunk.split(at: 5)

    XCTAssertEqual(left.length, 5)
    XCTAssertEqual(left.text, "hello")
    XCTAssertEqual(right.length, 0)
  }

  func testSplitAtMiddle() {
    let chunk = AttributedChunk(text: "hello", attributes: [.foregroundColor: LexicalColor.red])
    let (left, right) = chunk.split(at: 2)

    XCTAssertEqual(left.text, "he")
    XCTAssertEqual(right.text, "llo")

    // Both should have the same attributes
    XCTAssertEqual(left.attributeRuns.count, 1)
    XCTAssertEqual(left.attributeRuns[0].range, 0..<2)
    XCTAssertEqual(right.attributeRuns.count, 1)
    XCTAssertEqual(right.attributeRuns[0].range, 0..<3)
  }

  func testSplitPreservesMultipleRuns() {
    // "heLLO" where "he" is red and "LLO" is blue
    let runs: [AttributeRun] = [
      AttributeRun(range: 0..<2, attributes: [.foregroundColor: LexicalColor.red]),
      AttributeRun(range: 2..<5, attributes: [.foregroundColor: LexicalColor.blue]),
    ]
    let chunk = AttributedChunk(text: "heLLO", runs: runs)

    // Split at boundary
    let (left, right) = chunk.split(at: 2)

    XCTAssertEqual(left.text, "he")
    XCTAssertEqual(left.attributeRuns.count, 1)
    XCTAssertEqual(left.attributeRuns[0].range, 0..<2)

    XCTAssertEqual(right.text, "LLO")
    XCTAssertEqual(right.attributeRuns.count, 1)
    XCTAssertEqual(right.attributeRuns[0].range, 0..<3)
  }

  func testSplitAcrossRun() {
    // "heLLO" where "hel" is red and "LO" is blue
    let runs: [AttributeRun] = [
      AttributeRun(range: 0..<3, attributes: [.foregroundColor: LexicalColor.red]),
      AttributeRun(range: 3..<5, attributes: [.foregroundColor: LexicalColor.blue]),
    ]
    let chunk = AttributedChunk(text: "heLLO", runs: runs)

    // Split in middle of first run
    let (left, right) = chunk.split(at: 2)

    XCTAssertEqual(left.text, "he")
    XCTAssertEqual(left.attributeRuns.count, 1)
    XCTAssertEqual(left.attributeRuns[0].range, 0..<2)

    XCTAssertEqual(right.text, "LLO")
    XCTAssertEqual(right.attributeRuns.count, 2)
    // First run in right: "L" (was 2..<3, now 0..<1)
    XCTAssertEqual(right.attributeRuns[0].range, 0..<1)
    // Second run in right: "LO" (was 3..<5, now 1..<3)
    XCTAssertEqual(right.attributeRuns[1].range, 1..<3)
  }

  // MARK: 2.4 - concat with attr coalescing

  func testConcatTwoChunks() {
    let left = AttributedChunk(text: "hello")
    let right = AttributedChunk(text: " world")

    let result = AttributedChunk.concat(left, right)

    XCTAssertEqual(result.text, "hello world")
    XCTAssertEqual(result.length, 11)
  }

  func testConcatWithEmptyLeft() {
    let left = AttributedChunk(text: "")
    let right = AttributedChunk(text: "world", attributes: [.foregroundColor: LexicalColor.blue])

    let result = AttributedChunk.concat(left, right)

    XCTAssertEqual(result.text, "world")
    XCTAssertEqual(result.attributeRuns.count, 1)
  }

  func testConcatWithEmptyRight() {
    let left = AttributedChunk(text: "hello", attributes: [.foregroundColor: LexicalColor.red])
    let right = AttributedChunk(text: "")

    let result = AttributedChunk.concat(left, right)

    XCTAssertEqual(result.text, "hello")
    XCTAssertEqual(result.attributeRuns.count, 1)
  }

  func testConcatCoalescesSameAttributes() {
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    let left = AttributedChunk(text: "hel", attributes: attrs)
    let right = AttributedChunk(text: "lo", attributes: attrs)

    let result = AttributedChunk.concat(left, right)

    XCTAssertEqual(result.text, "hello")
    // Should coalesce into single run since attrs are the same
    XCTAssertEqual(result.attributeRuns.count, 1)
    XCTAssertEqual(result.attributeRuns[0].range, 0..<5)
  }

  func testConcatPreservesDifferentAttributes() {
    let left = AttributedChunk(text: "hel", attributes: [.foregroundColor: LexicalColor.red])
    let right = AttributedChunk(text: "lo", attributes: [.foregroundColor: LexicalColor.blue])

    let result = AttributedChunk.concat(left, right)

    XCTAssertEqual(result.text, "hello")
    XCTAssertEqual(result.attributeRuns.count, 2)
    XCTAssertEqual(result.attributeRuns[0].range, 0..<3)
    XCTAssertEqual(result.attributeRuns[1].range, 3..<5)
  }

  func testConcatShiftsRightRuns() {
    let left = AttributedChunk(text: "abc", attributes: [.foregroundColor: LexicalColor.red])
    let rightRuns: [AttributeRun] = [
      AttributeRun(range: 0..<2, attributes: [.foregroundColor: LexicalColor.blue]),
      AttributeRun(range: 2..<4, attributes: [.foregroundColor: LexicalColor.green]),
    ]
    let right = AttributedChunk(text: "defg", runs: rightRuns)

    let result = AttributedChunk.concat(left, right)

    XCTAssertEqual(result.text, "abcdefg")
    XCTAssertEqual(result.attributeRuns.count, 3)
    XCTAssertEqual(result.attributeRuns[0].range, 0..<3)   // "abc" red
    XCTAssertEqual(result.attributeRuns[1].range, 3..<5)   // "de" blue (shifted from 0..<2)
    XCTAssertEqual(result.attributeRuns[2].range, 5..<7)   // "fg" green (shifted from 2..<4)
  }

  // MARK: 2.5 - attributes(at:effectiveRange:)

  func testAttributesAtIndex() {
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    let chunk = AttributedChunk(text: "hello", attributes: attrs)

    var effectiveRange = 0..<0
    let result = chunk.attributes(at: 2, effectiveRange: &effectiveRange)

    XCTAssertNotNil(result[.foregroundColor])
    XCTAssertEqual(effectiveRange, 0..<5)
  }

  func testAttributesAtIndexMultipleRuns() {
    let runs: [AttributeRun] = [
      AttributeRun(range: 0..<3, attributes: [.foregroundColor: LexicalColor.red]),
      AttributeRun(range: 3..<5, attributes: [.foregroundColor: LexicalColor.blue]),
    ]
    let chunk = AttributedChunk(text: "hello", runs: runs)

    // Check first run
    var range1 = 0..<0
    let attrs1 = chunk.attributes(at: 1, effectiveRange: &range1)
    XCTAssertEqual(range1, 0..<3)
    XCTAssertNotNil(attrs1[.foregroundColor])

    // Check second run
    var range2 = 0..<0
    let attrs2 = chunk.attributes(at: 4, effectiveRange: &range2)
    XCTAssertEqual(range2, 3..<5)
    XCTAssertNotNil(attrs2[.foregroundColor])
  }

  func testAttributesAtBoundary() {
    let runs: [AttributeRun] = [
      AttributeRun(range: 0..<3, attributes: [.foregroundColor: LexicalColor.red]),
      AttributeRun(range: 3..<5, attributes: [.foregroundColor: LexicalColor.blue]),
    ]
    let chunk = AttributedChunk(text: "hello", runs: runs)

    // At boundary (index 3 is start of second run)
    var range = 0..<0
    _ = chunk.attributes(at: 3, effectiveRange: &range)
    XCTAssertEqual(range, 3..<5)
  }

  func testAttributesEmptyChunk() {
    let chunk = AttributedChunk(text: "")

    var range = 0..<0
    let attrs = chunk.attributes(at: 0, effectiveRange: &range)

    XCTAssertTrue(attrs.isEmpty)
    XCTAssertEqual(range, 0..<0)
  }

  // MARK: 2.6 - NodeKey association

  func testNodeKeyAssociation() {
    let chunk = AttributedChunk(text: "hello", nodeKey: "node_1")
    XCTAssertEqual(chunk.nodeKey, "node_1")
  }

  func testNodeKeyNil() {
    let chunk = AttributedChunk(text: "hello")
    XCTAssertNil(chunk.nodeKey)
  }

  func testNodeKeyPreservedOnSplit() {
    let chunk = AttributedChunk(text: "hello", nodeKey: "node_1")
    let (left, right) = chunk.split(at: 2)

    // Both halves should preserve the nodeKey
    XCTAssertEqual(left.nodeKey, "node_1")
    XCTAssertEqual(right.nodeKey, "node_1")
  }

  func testNodeKeyOnConcat() {
    let left = AttributedChunk(text: "hel", nodeKey: "node_1")
    let right = AttributedChunk(text: "lo", nodeKey: "node_2")

    let result = AttributedChunk.concat(left, right)

    // Concat takes left's nodeKey (arbitrary choice, can be nil if they differ)
    // For our use case, chunks from the same node will have same key
    XCTAssertEqual(result.nodeKey, "node_1")
  }

  // MARK: - RopeChunk conformance

  func testRopeChunkConformance() {
    let chunk = AttributedChunk(text: "hello", attributes: [.foregroundColor: LexicalColor.red])

    // Test that it works with Rope
    var rope = Rope(chunk: chunk)
    XCTAssertEqual(rope.length, 5)

    rope.insert(AttributedChunk(text: " world"), at: 5)
    XCTAssertEqual(rope.length, 11)

    let (left, right) = rope.split(at: 5)
    XCTAssertEqual(left.length, 5)
    XCTAssertEqual(right.length, 6)
  }

  // MARK: - toAttributedString conversion

  func testToAttributedStringEmpty() {
    let chunk = AttributedChunk(text: "")
    let attrStr = chunk.toAttributedString()

    XCTAssertEqual(attrStr.length, 0)
  }

  func testToAttributedStringSimple() {
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    let chunk = AttributedChunk(text: "hello", attributes: attrs)
    let attrStr = chunk.toAttributedString()

    XCTAssertEqual(attrStr.string, "hello")
    XCTAssertEqual(attrStr.length, 5)

    var range = NSRange()
    let resultAttrs = attrStr.attributes(at: 0, effectiveRange: &range)
    XCTAssertNotNil(resultAttrs[.foregroundColor])
    XCTAssertEqual(range, NSRange(location: 0, length: 5))
  }

  func testToAttributedStringMultipleRuns() {
    let runs: [AttributeRun] = [
      AttributeRun(range: 0..<3, attributes: [.foregroundColor: LexicalColor.red]),
      AttributeRun(range: 3..<5, attributes: [.foregroundColor: LexicalColor.blue]),
    ]
    let chunk = AttributedChunk(text: "hello", runs: runs)
    let attrStr = chunk.toAttributedString()

    XCTAssertEqual(attrStr.string, "hello")

    var range1 = NSRange()
    _ = attrStr.attributes(at: 0, effectiveRange: &range1)
    XCTAssertEqual(range1, NSRange(location: 0, length: 3))

    var range2 = NSRange()
    _ = attrStr.attributes(at: 4, effectiveRange: &range2)
    XCTAssertEqual(range2, NSRange(location: 3, length: 2))
  }
}
