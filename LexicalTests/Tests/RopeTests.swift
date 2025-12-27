/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import LexicalCore

// MARK: - Test Chunk (simple string-based chunk for testing)

struct TestChunk: RopeChunk, Equatable {
  let text: String

  var length: Int { text.utf16.count }

  func split(at offset: Int) -> (TestChunk, TestChunk) {
    let idx = text.utf16.index(text.startIndex, offsetBy: offset)
    let left = String(text[..<idx])
    let right = String(text[idx...])
    return (TestChunk(text: left), TestChunk(text: right))
  }

  static func concat(_ left: TestChunk, _ right: TestChunk) -> TestChunk {
    return TestChunk(text: left.text + right.text)
  }
}

// MARK: - RopeNode Tests

final class RopeNodeTests: XCTestCase {

  // MARK: 1.1 - Basic RopeNode creation

  func testLeafNodeCreation() {
    let chunk = TestChunk(text: "hello")
    let node = RopeNode.leaf(chunk)

    XCTAssertEqual(node.length, 5)
    XCTAssertEqual(node.height, 0)
  }

  func testEmptyLeafNode() {
    let chunk = TestChunk(text: "")
    let node = RopeNode.leaf(chunk)

    XCTAssertEqual(node.length, 0)
    XCTAssertEqual(node.height, 0)
  }

  func testBranchNodeCreation() {
    let left = RopeNode.leaf(TestChunk(text: "hello"))
    let right = RopeNode.leaf(TestChunk(text: " world"))

    let branch = RopeNode.branch(left: left, right: right)

    XCTAssertEqual(branch.length, 11)
    XCTAssertEqual(branch.height, 1)
  }

  func testNestedBranchNode() {
    let a = RopeNode.leaf(TestChunk(text: "a"))
    let b = RopeNode.leaf(TestChunk(text: "b"))
    let c = RopeNode.leaf(TestChunk(text: "c"))

    let left = RopeNode.branch(left: a, right: b)
    let root = RopeNode.branch(left: left, right: c)

    XCTAssertEqual(root.length, 3)
    XCTAssertEqual(root.height, 2)
  }

  // MARK: - Chunk access by index

  func testChunkAtIndexLeaf() {
    let node = RopeNode.leaf(TestChunk(text: "hello"))

    let (chunk, offset) = node.chunk(at: 2)
    XCTAssertEqual(chunk.text, "hello")
    XCTAssertEqual(offset, 2)
  }

  func testChunkAtIndexBranch() {
    let left = RopeNode.leaf(TestChunk(text: "hello"))
    let right = RopeNode.leaf(TestChunk(text: " world"))
    let branch = RopeNode.branch(left: left, right: right)

    // Index in left subtree
    let (chunk1, offset1) = branch.chunk(at: 2)
    XCTAssertEqual(chunk1.text, "hello")
    XCTAssertEqual(offset1, 2)

    // Index in right subtree
    let (chunk2, offset2) = branch.chunk(at: 7)
    XCTAssertEqual(chunk2.text, " world")
    XCTAssertEqual(offset2, 2) // 7 - 5 (left length)
  }

  func testChunkAtIndexBoundary() {
    let left = RopeNode.leaf(TestChunk(text: "hello"))
    let right = RopeNode.leaf(TestChunk(text: " world"))
    let branch = RopeNode.branch(left: left, right: right)

    // Exactly at boundary (start of right)
    let (chunk, offset) = branch.chunk(at: 5)
    XCTAssertEqual(chunk.text, " world")
    XCTAssertEqual(offset, 0)
  }
}

// MARK: - Rope Tests

final class RopeTests: XCTestCase {

  // MARK: 1.1 - Basic Rope creation

  func testEmptyRope() {
    let rope = Rope<TestChunk>()
    XCTAssertEqual(rope.length, 0)
  }

  func testRopeFromChunk() {
    let rope = Rope(chunk: TestChunk(text: "hello"))
    XCTAssertEqual(rope.length, 5)
  }

  // MARK: 1.2 - Split

  func testSplitAtStart() {
    let rope = Rope(chunk: TestChunk(text: "hello"))
    let (left, right) = rope.split(at: 0)

    XCTAssertEqual(left.length, 0)
    XCTAssertEqual(right.length, 5)
    XCTAssertEqual(right.collectText(), "hello")
  }

  func testSplitAtEnd() {
    let rope = Rope(chunk: TestChunk(text: "hello"))
    let (left, right) = rope.split(at: 5)

    XCTAssertEqual(left.length, 5)
    XCTAssertEqual(left.collectText(), "hello")
    XCTAssertEqual(right.length, 0)
  }

  func testSplitAtMiddle() {
    let rope = Rope(chunk: TestChunk(text: "hello"))
    let (left, right) = rope.split(at: 2)

    XCTAssertEqual(left.length, 2)
    XCTAssertEqual(left.collectText(), "he")
    XCTAssertEqual(right.length, 3)
    XCTAssertEqual(right.collectText(), "llo")
  }

  func testSplitMultiChunk() {
    var rope = Rope(chunk: TestChunk(text: "hello"))
    rope.insert(TestChunk(text: " world"), at: 5)

    let (left, right) = rope.split(at: 7)

    XCTAssertEqual(left.collectText(), "hello w")
    XCTAssertEqual(right.collectText(), "orld")
  }

  // MARK: 1.3 - Concat

  func testConcatEmptyRopes() {
    let left = Rope<TestChunk>()
    let right = Rope<TestChunk>()

    let result = Rope.concat(left, right)
    XCTAssertEqual(result.length, 0)
  }

  func testConcatLeftEmpty() {
    let left = Rope<TestChunk>()
    let right = Rope(chunk: TestChunk(text: "hello"))

    let result = Rope.concat(left, right)
    XCTAssertEqual(result.length, 5)
    XCTAssertEqual(result.collectText(), "hello")
  }

  func testConcatRightEmpty() {
    let left = Rope(chunk: TestChunk(text: "hello"))
    let right = Rope<TestChunk>()

    let result = Rope.concat(left, right)
    XCTAssertEqual(result.length, 5)
    XCTAssertEqual(result.collectText(), "hello")
  }

  func testConcatTwoRopes() {
    let left = Rope(chunk: TestChunk(text: "hello"))
    let right = Rope(chunk: TestChunk(text: " world"))

    let result = Rope.concat(left, right)
    XCTAssertEqual(result.length, 11)
    XCTAssertEqual(result.collectText(), "hello world")
  }

  // MARK: 1.4 - Height balancing

  func testBalanceAfterManyInserts() {
    var rope = Rope(chunk: TestChunk(text: "a"))

    // Insert many single-char chunks to stress the tree
    for i in 0..<100 {
      let char = String(Character(UnicodeScalar(65 + (i % 26))!))
      rope.insert(TestChunk(text: char), at: rope.length)
    }

    // Height should be O(log N), not O(N)
    // For 101 elements, log2(101) ≈ 7, so height should be reasonable
    XCTAssertLessThanOrEqual(rope.height, 15)
    XCTAssertEqual(rope.length, 101)
  }

  func testBalanceAfterRandomInserts() {
    var rope = Rope(chunk: TestChunk(text: "initial"))

    // Insert at random positions
    for i in 0..<50 {
      let pos = i % (rope.length + 1)
      rope.insert(TestChunk(text: "x"), at: pos)
    }

    // Tree should stay balanced
    XCTAssertLessThanOrEqual(rope.height, 12)
    XCTAssertEqual(rope.length, 7 + 50)
  }

  // MARK: 1.5 - Insert

  func testInsertAtStart() {
    var rope = Rope(chunk: TestChunk(text: "world"))
    rope.insert(TestChunk(text: "hello "), at: 0)

    XCTAssertEqual(rope.length, 11)
    XCTAssertEqual(rope.collectText(), "hello world")
  }

  func testInsertAtEnd() {
    var rope = Rope(chunk: TestChunk(text: "hello"))
    rope.insert(TestChunk(text: " world"), at: 5)

    XCTAssertEqual(rope.length, 11)
    XCTAssertEqual(rope.collectText(), "hello world")
  }

  func testInsertAtMiddle() {
    var rope = Rope(chunk: TestChunk(text: "helloworld"))
    rope.insert(TestChunk(text: " "), at: 5)

    XCTAssertEqual(rope.length, 11)
    XCTAssertEqual(rope.collectText(), "hello world")
  }

  func testInsertIntoEmpty() {
    var rope = Rope<TestChunk>()
    rope.insert(TestChunk(text: "hello"), at: 0)

    XCTAssertEqual(rope.length, 5)
    XCTAssertEqual(rope.collectText(), "hello")
  }

  // MARK: 1.6 - Delete

  func testDeleteFromStart() {
    var rope = Rope(chunk: TestChunk(text: "hello world"))
    rope.delete(range: 0..<6)

    XCTAssertEqual(rope.length, 5)
    XCTAssertEqual(rope.collectText(), "world")
  }

  func testDeleteFromEnd() {
    var rope = Rope(chunk: TestChunk(text: "hello world"))
    rope.delete(range: 5..<11)

    XCTAssertEqual(rope.length, 5)
    XCTAssertEqual(rope.collectText(), "hello")
  }

  func testDeleteFromMiddle() {
    var rope = Rope(chunk: TestChunk(text: "hello world"))
    rope.delete(range: 5..<6)

    XCTAssertEqual(rope.length, 10)
    XCTAssertEqual(rope.collectText(), "helloworld")
  }

  func testDeleteAll() {
    var rope = Rope(chunk: TestChunk(text: "hello"))
    rope.delete(range: 0..<5)

    XCTAssertEqual(rope.length, 0)
    XCTAssertEqual(rope.collectText(), "")
  }

  func testDeleteNothing() {
    var rope = Rope(chunk: TestChunk(text: "hello"))
    rope.delete(range: 2..<2)

    XCTAssertEqual(rope.length, 5)
    XCTAssertEqual(rope.collectText(), "hello")
  }

  // MARK: 1.7 - Replace

  func testReplaceMiddle() {
    var rope = Rope(chunk: TestChunk(text: "hello world"))
    rope.replace(range: 6..<11, with: TestChunk(text: "there"))

    XCTAssertEqual(rope.collectText(), "hello there")
  }

  func testReplaceShorter() {
    var rope = Rope(chunk: TestChunk(text: "hello world"))
    rope.replace(range: 6..<11, with: TestChunk(text: "!"))

    XCTAssertEqual(rope.collectText(), "hello !")
    XCTAssertEqual(rope.length, 7)
  }

  func testReplaceLonger() {
    var rope = Rope(chunk: TestChunk(text: "hi"))
    rope.replace(range: 0..<2, with: TestChunk(text: "hello world"))

    XCTAssertEqual(rope.collectText(), "hello world")
    XCTAssertEqual(rope.length, 11)
  }

  func testReplaceEmpty() {
    var rope = Rope(chunk: TestChunk(text: "helloworld"))
    rope.replace(range: 5..<5, with: TestChunk(text: " "))

    XCTAssertEqual(rope.collectText(), "hello world")
  }

  // MARK: 1.8 - Random access

  func testChunkAtValidIndex() {
    let rope = Rope(chunk: TestChunk(text: "hello world"))

    let (chunk, offset) = rope.chunk(at: 6)
    XCTAssertEqual(chunk.text, "hello world")
    XCTAssertEqual(offset, 6)
  }

  func testChunkAtStartIndex() {
    let rope = Rope(chunk: TestChunk(text: "hello"))

    let (chunk, offset) = rope.chunk(at: 0)
    XCTAssertEqual(chunk.text, "hello")
    XCTAssertEqual(offset, 0)
  }

  func testChunkAfterInserts() {
    var rope = Rope(chunk: TestChunk(text: "hello"))
    rope.insert(TestChunk(text: " world"), at: 5)
    rope.insert(TestChunk(text: "!"), at: 11)

    // Access in different chunks
    let (chunk1, _) = rope.chunk(at: 3)
    XCTAssertEqual(chunk1.text, "hello")

    let (chunk2, _) = rope.chunk(at: 8)
    XCTAssertEqual(chunk2.text, " world")

    let (chunk3, _) = rope.chunk(at: 11)
    XCTAssertEqual(chunk3.text, "!")
  }

  // MARK: - Collect text helper

  func testCollectTextEmpty() {
    let rope = Rope<TestChunk>()
    XCTAssertEqual(rope.collectText(), "")
  }

  func testCollectTextSingle() {
    let rope = Rope(chunk: TestChunk(text: "hello"))
    XCTAssertEqual(rope.collectText(), "hello")
  }

  func testCollectTextMultiple() {
    var rope = Rope(chunk: TestChunk(text: "hello"))
    rope.insert(TestChunk(text: " "), at: 5)
    rope.insert(TestChunk(text: "world"), at: 6)

    XCTAssertEqual(rope.collectText(), "hello world")
  }
}

// MARK: - RopeChunk Protocol Tests

final class RopeChunkTests: XCTestCase {

  func testChunkLength() {
    let chunk = TestChunk(text: "hello")
    XCTAssertEqual(chunk.length, 5)
  }

  func testChunkLengthEmoji() {
    let chunk = TestChunk(text: "👋🌍")
    XCTAssertEqual(chunk.length, 4) // Each emoji is 2 UTF-16 code units
  }

  func testChunkSplit() {
    let chunk = TestChunk(text: "hello")
    let (left, right) = chunk.split(at: 2)

    XCTAssertEqual(left.text, "he")
    XCTAssertEqual(right.text, "llo")
  }

  func testChunkSplitAtStart() {
    let chunk = TestChunk(text: "hello")
    let (left, right) = chunk.split(at: 0)

    XCTAssertEqual(left.text, "")
    XCTAssertEqual(right.text, "hello")
  }

  func testChunkSplitAtEnd() {
    let chunk = TestChunk(text: "hello")
    let (left, right) = chunk.split(at: 5)

    XCTAssertEqual(left.text, "hello")
    XCTAssertEqual(right.text, "")
  }

  func testChunkConcat() {
    let left = TestChunk(text: "hello")
    let right = TestChunk(text: " world")

    let result = TestChunk.concat(left, right)
    XCTAssertEqual(result.text, "hello world")
  }
}

// MARK: - Extension to collect text for testing

extension Rope where T == TestChunk {
  func collectText() -> String {
    guard let root = root else { return "" }
    return root.collectText()
  }
}

extension RopeNode where T == TestChunk {
  func collectText() -> String {
    switch self {
    case .leaf(let chunk):
      return chunk.text
    case .branch(let left, let right, _, _):
      return left.collectText() + right.collectText()
    }
  }
}

// MARK: - Performance Tests
//
// NOTE: Current rope implementation is functionally correct but needs performance
// optimization. The balancing strategy creates too many small nodes. Future work:
// - Coalesce adjacent small leaves
// - Use weight-balanced trees instead of height-balanced
// - Consider B-tree variant for better cache locality

final class RopePerformanceTests: XCTestCase {

  // MARK: 1.9 - Performance benchmarks

  func testMiddleInsertPerformance() {
    // Middle inserts are the worst case for O(N) data structures
    // This tests the basic rope structure works for typical editing

    var rope = Rope(chunk: TestChunk(text: String(repeating: "a", count: 10_000)))

    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<1_000 {
      // Always insert in the middle
      rope.insert(TestChunk(text: "x"), at: rope.length / 2)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    // 1000 middle inserts should be reasonably fast
    XCTAssertLessThan(elapsed, 1.0, "1000 middle inserts should complete in < 1s")
  }

  func testTreeHeightStaysLogarithmic() {
    // Verify tree doesn't degrade to linear height
    var rope = Rope<TestChunk>()

    for i in 0..<1_000 {
      rope.insert(TestChunk(text: "x"), at: i)
    }

    // For 1000 elements, log2(1000) ≈ 10, so height should be bounded
    // Allow some slack for imperfect balancing
    XCTAssertLessThanOrEqual(rope.height, 25, "Height should be O(log N) for 1000 elements")
  }

  func testChunkAccessIsEfficient() {
    // Random access should be fast regardless of position
    var rope = Rope<TestChunk>()

    // Build a rope with 1000 chunks
    for _ in 0..<1_000 {
      let pos = rope.length
      rope.insert(TestChunk(text: "hello"), at: pos)
    }

    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<10_000 {
      let idx = Int.random(in: 0..<rope.length)
      _ = rope.chunk(at: idx)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    // 10K random accesses should be reasonably fast
    XCTAssertLessThan(elapsed, 3.0, "10K random accesses should complete in < 3s")
  }

  func testSplitAndConcatPreserveContent() {
    // Verify split/concat don't lose data under stress
    var rope = Rope(chunk: TestChunk(text: "abcdefghij"))

    for _ in 0..<100 {
      let mid = rope.length / 2
      let (left, right) = rope.split(at: mid)
      rope = Rope.concat(left, right)
    }

    XCTAssertEqual(rope.collectText(), "abcdefghij")
  }
}
