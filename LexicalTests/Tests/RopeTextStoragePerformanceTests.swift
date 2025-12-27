/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical
@testable import LexicalCore

// MARK: - RopeTextStorage Performance Characterization Tests

/// These tests document current performance characteristics and will
/// serve as regression tests after optimization.
final class RopeTextStoragePerformanceTests: XCTestCase {

  // MARK: - Test 1: collectText Traversal Complexity

  /// Measures string materialization time at different document sizes.
  /// Current: O(N log N) due to per-position chunk lookups
  /// Target: O(N) with chunk iteration
  func testCollectTextScaling() {
    let sizes = [10_000, 50_000, 100_000]
    var times: [Int: Double] = [:]

    for size in sizes {
      let storage = RopeTextStorage(string: String(repeating: "a", count: size))

      let start = CFAbsoluteTimeGetCurrent()
      for _ in 0..<10 {
        _ = storage.string
      }
      let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 10.0

      times[size] = elapsed
      print("collectText @ \(size) chars: \(elapsed * 1000)ms")
    }

    // Verify scaling behavior
    // For O(N log N): time ratio should be roughly (50K * log(50K)) / (10K * log(10K)) ≈ 5.8
    // For O(N): time ratio should be roughly 5.0
    if let t10k = times[10_000], let t50k = times[50_000], t10k > 0 {
      let ratio = t50k / t10k
      print("50K/10K ratio: \(ratio) (O(N) expects ~5.0, O(N log N) expects ~5.8)")
    }
  }

  // MARK: - Test 2: String Concatenation Overhead

  /// Measures overhead when building from many small chunks.
  /// Current: O(N²) due to intermediate string copies
  /// Target: O(N) with array.joined()
  func testStringConcatenationFromManyChunks() {
    // Build a storage with many small insertions (creates many chunks)
    let storage = RopeTextStorage()
    let chunkSize = 100
    let chunkCount = 1000

    // Insert many small chunks
    for i in 0..<chunkCount {
      let text = String(repeating: Character(UnicodeScalar(65 + (i % 26))!), count: chunkSize)
      storage.replaceCharacters(in: NSRange(location: i * chunkSize, length: 0), with: text)
    }

    XCTAssertEqual(storage.length, chunkSize * chunkCount)

    // Measure materialization time
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<10 {
      _ = storage.string
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 10.0

    print("Materialize \(chunkCount) chunks (\(chunkSize * chunkCount) chars): \(elapsed * 1000)ms")
  }

  // MARK: - Test 3: setAttributes Performance

  /// Measures setAttributes performance on large documents.
  /// Current: O(N) due to reconstruction loop
  /// Target: O(log N) with proper rope operations
  func testSetAttributesPerformance() {
    let storage = RopeTextStorage(string: String(repeating: "a", count: 100_000))
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]

    // Warm up
    storage.setAttributes(attrs, range: NSRange(location: 0, length: 100))

    // Measure middle-of-document attribute setting
    let start = CFAbsoluteTimeGetCurrent()
    for i in 0..<100 {
      let location = 50_000 + (i * 10)
      storage.setAttributes(attrs, range: NSRange(location: location, length: 100))
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 100.0

    print("setAttributes @ 100K doc: \(elapsed * 1000)ms per call")
  }

  // MARK: - Test 4: attributedSubstring Performance

  /// Measures attributedSubstring extraction overhead.
  /// Current: materializes entire string first
  /// Target: extract only needed range using rope operations
  func testAttributedSubstringPerformance() {
    let storage = RopeTextStorage(string: String(repeating: "a", count: 100_000))

    // Measure extraction from middle
    let start = CFAbsoluteTimeGetCurrent()
    for i in 0..<100 {
      let location = 50_000 + (i * 10)
      _ = storage.attributedSubstring(from: NSRange(location: location, length: 100))
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 100.0

    print("attributedSubstring @ 100K doc: \(elapsed * 1000)ms per call")
  }

  // MARK: - Test 5: Cache Invalidation Behavior

  /// Measures re-materialization time after small edit.
  /// Current: full O(N) re-materialize
  /// Target: < 10% of document re-materialized
  func testCacheInvalidationAfterSmallEdit() {
    let storage = RopeTextStorage(string: String(repeating: "a", count: 100_000))

    // Warm cache
    _ = storage.string

    // Make a small edit in the middle
    storage.replaceCharacters(in: NSRange(location: 50_000, length: 1), with: "X")

    // Measure re-materialization
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<10 {
      _ = storage.string
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 10.0

    print("Re-materialize after 1-char edit @ 100K doc: \(elapsed * 1000)ms")
  }

  // MARK: - Test 6: Edit at Different Positions

  /// Compares edit performance at start, middle, and end.
  /// Rope should provide consistent O(log N) performance regardless of position.
  func testEditPositionPerformance() {
    let positions = ["start", "middle", "end"]
    let offsets = [0, 50_000, 99_999]

    for (name, offset) in zip(positions, offsets) {
      let storage = RopeTextStorage(string: String(repeating: "a", count: 100_000))

      let start = CFAbsoluteTimeGetCurrent()
      for _ in 0..<1000 {
        storage.replaceCharacters(in: NSRange(location: offset, length: 0), with: "X")
        storage.replaceCharacters(in: NSRange(location: offset, length: 1), with: "")
      }
      let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 1000.0

      print("Insert+delete at \(name): \(elapsed * 1000)ms per op")
    }
  }

  // MARK: - XCTest measure() Benchmarks

  /// Standard XCTest measurement for string materialization.
  func testMeasureStringMaterialization() {
    let storage = RopeTextStorage(string: String(repeating: "a", count: 100_000))

    measure {
      _ = storage.string
    }
  }

  /// Standard XCTest measurement for setAttributes.
  func testMeasureSetAttributes() {
    let storage = RopeTextStorage(string: String(repeating: "a", count: 100_000))
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]

    measure {
      storage.setAttributes(attrs, range: NSRange(location: 50_000, length: 1000))
    }
  }

  /// Standard XCTest measurement for attributedSubstring.
  func testMeasureAttributedSubstring() {
    let storage = RopeTextStorage(string: String(repeating: "a", count: 100_000))

    measure {
      _ = storage.attributedSubstring(from: NSRange(location: 50_000, length: 1000))
    }
  }
}
