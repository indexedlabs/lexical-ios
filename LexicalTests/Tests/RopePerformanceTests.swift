/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import LexicalCore

// MARK: - Rope Performance Characterization Tests

/// These tests document current Rope performance characteristics and will
/// serve as regression tests after optimization.
/// Focuses on chunk iteration performance (to be implemented).
final class RopeChunkIterationTests: XCTestCase {

  // MARK: - Test 1: Position-based Chunk Access

  /// Measures current position-based chunk lookup.
  /// Current: O(log N) per lookup, O(M * log N) total for M chunks
  /// Target: O(M) total with chunk iteration
  func testPositionBasedChunkAccess() {
    // Build a rope with many chunks
    var rope = Rope<TestChunk>()
    let chunkCount = 1000
    let chunkSize = 100

    for i in 0..<chunkCount {
      let chunk = TestChunk(text: String(repeating: Character(UnicodeScalar(65 + (i % 26))!), count: chunkSize))
      rope.insert(chunk, at: i * chunkSize)
    }

    XCTAssertEqual(rope.length, chunkCount * chunkSize)

    // Measure position-based iteration (current approach)
    var position = 0
    var accessCount = 0

    let start = CFAbsoluteTimeGetCurrent()
    while position < rope.length {
      let (chunk, offset) = rope.chunk(at: position)
      position += chunk.length - offset
      accessCount += 1
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    print("Position-based: \(accessCount) chunk accesses in \(elapsed * 1000)ms")
    print("Expected: ~\(chunkCount) chunks")
  }

  // MARK: - Test 2: Rope Height vs Operations

  /// Measures rope height after many insertions.
  /// AVL-like balancing should keep height at O(log N).
  func testRopeHeightAfterInsertions() {
    var rope = Rope<TestChunk>()
    let insertCount = 1000

    for i in 0..<insertCount {
      let chunk = TestChunk(text: "chunk\(i)")
      // Insert at random-ish positions to stress balancing
      let position = (i * 37) % max(1, rope.length + 1)
      rope.insert(chunk, at: position)
    }

    let height = rope.height
    let expectedMaxHeight = Int(ceil(1.44 * log2(Double(insertCount + 1)))) // AVL worst case

    print("Rope height after \(insertCount) inserts: \(height)")
    print("Expected max (AVL): ~\(expectedMaxHeight)")

    XCTAssertLessThanOrEqual(height, expectedMaxHeight + 5, "Rope should be balanced")
  }

  // MARK: - Test 3: Split Performance

  /// Measures split performance at different positions.
  /// Should be O(log N) regardless of position.
  func testSplitPerformance() {
    var rope = Rope<TestChunk>()
    let totalLength = 100_000

    // Build a large rope
    let chunkSize = 1000
    for i in 0..<(totalLength / chunkSize) {
      rope.insert(TestChunk(text: String(repeating: "a", count: chunkSize)), at: i * chunkSize)
    }

    let positions = [0, totalLength / 4, totalLength / 2, 3 * totalLength / 4, totalLength]

    for position in positions {
      let start = CFAbsoluteTimeGetCurrent()
      for _ in 0..<1000 {
        _ = rope.split(at: position)
      }
      let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 1000.0

      print("Split at \(position) / \(totalLength): \(elapsed * 1_000_000)µs")
    }
  }

  // MARK: - Test 4: Insert Performance at Different Positions

  /// Measures insert performance at start, middle, and end.
  /// Rope should provide O(log N) at all positions.
  func testInsertPositionPerformance() {
    let positions = ["start", "middle", "end"]

    for name in positions {
      var rope = Rope<TestChunk>()
      let insertCount = 1000
      let chunk = TestChunk(text: String(repeating: "a", count: 100))

      let start = CFAbsoluteTimeGetCurrent()
      for i in 0..<insertCount {
        let position: Int
        switch name {
        case "start": position = 0
        case "end": position = rope.length
        default: position = rope.length / 2
        }
        rope.insert(chunk, at: position)
      }
      let elapsed = (CFAbsoluteTimeGetCurrent() - start) / Double(insertCount)

      print("Insert at \(name): \(elapsed * 1_000_000)µs per op")
    }
  }

  // MARK: - Test 5: Delete Performance

  /// Measures delete performance.
  /// Should be O(log N) for range deletion.
  func testDeletePerformance() {
    // Setup
    var rope = Rope<TestChunk>()
    let totalLength = 100_000
    let chunkSize = 1000

    for i in 0..<(totalLength / chunkSize) {
      rope.insert(TestChunk(text: String(repeating: "a", count: chunkSize)), at: i * chunkSize)
    }

    // Measure delete from middle
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<1000 {
      let middle = rope.length / 2
      rope.delete(range: middle..<(middle + 100))
      // Reinsert to maintain size
      rope.insert(TestChunk(text: String(repeating: "a", count: 100)), at: middle)
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 1000.0

    print("Delete+reinsert 100 chars at middle: \(elapsed * 1000)ms per op")
  }

  // MARK: - XCTest measure() Benchmarks

  func testMeasureChunkLookup() {
    var rope = Rope<TestChunk>()
    for i in 0..<100 {
      rope.insert(TestChunk(text: String(repeating: "a", count: 1000)), at: i * 1000)
    }

    measure {
      for i in stride(from: 0, to: rope.length, by: 1000) {
        _ = rope.chunk(at: i)
      }
    }
  }

  func testMeasureInsertAtMiddle() {
    let chunk = TestChunk(text: String(repeating: "a", count: 100))

    measure {
      var rope = Rope<TestChunk>()
      for _ in 0..<1000 {
        rope.insert(chunk, at: rope.length / 2)
      }
    }
  }

  func testMeasureSplit() {
    var rope = Rope<TestChunk>()
    for i in 0..<100 {
      rope.insert(TestChunk(text: String(repeating: "a", count: 1000)), at: i * 1000)
    }

    measure {
      for i in 0..<100 {
        _ = rope.split(at: i * 500)
      }
    }
  }
}

// MARK: - Chunk for Testing

/// Performance test chunk - reuses TestChunk from RopeTests via extension.
/// TestChunk is defined in RopeTests.swift
