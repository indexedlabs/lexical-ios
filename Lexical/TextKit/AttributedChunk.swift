/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore

// MARK: - AttributeRun

/// A run of text with consistent attributes.
public struct AttributeRun: Sendable {
  /// The range within the chunk (in UTF-16 code units).
  public let range: Range<Int>

  /// The attributes for this run.
  public let attributes: [NSAttributedString.Key: Any]

  public init(range: Range<Int>, attributes: [NSAttributedString.Key: Any]) {
    self.range = range
    self.attributes = attributes
  }

  /// Shift this run's range by an offset.
  func shifted(by offset: Int) -> AttributeRun {
    let newRange = (range.lowerBound + offset)..<(range.upperBound + offset)
    return AttributeRun(range: newRange, attributes: attributes)
  }

  /// Check if this run's attributes are equivalent to another's.
  func attributesEqual(to other: AttributeRun) -> Bool {
    // Compare attribute dictionaries
    guard attributes.count == other.attributes.count else { return false }
    for (key, value) in attributes {
      guard let otherValue = other.attributes[key] else { return false }
      // Use NSObject comparison for attribute values
      if let v1 = value as? NSObject, let v2 = otherValue as? NSObject {
        if v1 != v2 { return false }
      } else {
        // Fallback: assume different if can't compare
        return false
      }
    }
    return true
  }
}

// MARK: - AttributedChunk

/// A chunk of attributed text that can be stored in a Rope.
/// Implements RopeChunk protocol for O(log N) text operations.
public struct AttributedChunk: RopeChunk, Sendable {

  /// The text content.
  public let text: String

  /// The attribute runs within this chunk.
  public let attributeRuns: [AttributeRun]

  /// Optional association with a Lexical NodeKey.
  public let nodeKey: NodeKey?

  /// The length in UTF-16 code units (for TextKit compatibility).
  public var length: Int {
    text.utf16.count
  }

  // MARK: - Initializers

  /// Create an empty chunk.
  public init() {
    self.text = ""
    self.attributeRuns = []
    self.nodeKey = nil
  }

  /// Create a chunk with plain text (no attributes).
  public init(text: String, nodeKey: NodeKey? = nil) {
    self.text = text
    self.attributeRuns = []
    self.nodeKey = nodeKey
  }

  /// Create a chunk with text and uniform attributes.
  public init(text: String, attributes: [NSAttributedString.Key: Any], nodeKey: NodeKey? = nil) {
    self.text = text
    if text.isEmpty || attributes.isEmpty {
      self.attributeRuns = text.isEmpty ? [] : [AttributeRun(range: 0..<text.utf16.count, attributes: [:])]
    } else {
      self.attributeRuns = [AttributeRun(range: 0..<text.utf16.count, attributes: attributes)]
    }
    self.nodeKey = nodeKey
  }

  /// Create a chunk with text and explicit attribute runs.
  public init(text: String, runs: [AttributeRun], nodeKey: NodeKey? = nil) {
    self.text = text
    self.attributeRuns = runs
    self.nodeKey = nodeKey
  }

  // MARK: - RopeChunk Protocol

  /// Split this chunk at the given offset.
  public func split(at offset: Int) -> (AttributedChunk, AttributedChunk) {
    guard offset > 0 && offset < length else {
      if offset <= 0 {
        return (AttributedChunk(text: "", nodeKey: nodeKey), self)
      } else {
        return (self, AttributedChunk(text: "", nodeKey: nodeKey))
      }
    }

    // Split the text
    let utf16 = text.utf16
    let splitIndex = utf16.index(utf16.startIndex, offsetBy: offset)
    let leftText = String(utf16[..<splitIndex])!
    let rightText = String(utf16[splitIndex...])!

    // Split the attribute runs
    var leftRuns: [AttributeRun] = []
    var rightRuns: [AttributeRun] = []

    for run in attributeRuns {
      if run.range.upperBound <= offset {
        // Entirely in left
        leftRuns.append(run)
      } else if run.range.lowerBound >= offset {
        // Entirely in right - shift to 0-based
        rightRuns.append(run.shifted(by: -offset))
      } else {
        // Spans the split point
        let leftPart = AttributeRun(
          range: run.range.lowerBound..<offset,
          attributes: run.attributes
        )
        let rightPart = AttributeRun(
          range: 0..<(run.range.upperBound - offset),
          attributes: run.attributes
        )
        leftRuns.append(leftPart)
        rightRuns.append(rightPart)
      }
    }

    let leftChunk = AttributedChunk(text: leftText, runs: leftRuns, nodeKey: nodeKey)
    let rightChunk = AttributedChunk(text: rightText, runs: rightRuns, nodeKey: nodeKey)

    return (leftChunk, rightChunk)
  }

  /// Concatenate two chunks, coalescing adjacent runs with identical attributes.
  public static func concat(_ left: AttributedChunk, _ right: AttributedChunk) -> AttributedChunk {
    if left.length == 0 { return right }
    if right.length == 0 { return left }

    let combinedText = left.text + right.text
    let leftLength = left.length

    // Shift right runs by left length
    var combinedRuns = left.attributeRuns
    for run in right.attributeRuns {
      combinedRuns.append(run.shifted(by: leftLength))
    }

    // Coalesce adjacent runs with same attributes
    combinedRuns = coalesceRuns(combinedRuns)

    // Take left's nodeKey (arbitrary choice)
    return AttributedChunk(text: combinedText, runs: combinedRuns, nodeKey: left.nodeKey)
  }

  // MARK: - Attribute Access

  /// Get attributes at a specific index.
  /// - Parameters:
  ///   - index: The index to query (in UTF-16 code units).
  ///   - effectiveRange: Output parameter for the range where these attributes apply.
  /// - Returns: The attributes at that index.
  public func attributes(at index: Int, effectiveRange: inout Range<Int>) -> [NSAttributedString.Key: Any] {
    guard length > 0 && index < length else {
      effectiveRange = 0..<0
      return [:]
    }

    for run in attributeRuns {
      if run.range.contains(index) {
        effectiveRange = run.range
        return run.attributes
      }
    }

    // No run found - return empty with full range
    effectiveRange = 0..<length
    return [:]
  }

  // MARK: - Conversion

  /// Convert to NSAttributedString for TextKit.
  public func toAttributedString() -> NSAttributedString {
    guard !text.isEmpty else {
      return NSAttributedString()
    }

    let mutable = NSMutableAttributedString(string: text)

    for run in attributeRuns {
      let nsRange = NSRange(location: run.range.lowerBound, length: run.range.count)
      mutable.addAttributes(run.attributes, range: nsRange)
    }

    return mutable
  }

  // MARK: - Private Helpers

  /// Coalesce adjacent runs with identical attributes.
  private static func coalesceRuns(_ runs: [AttributeRun]) -> [AttributeRun] {
    guard runs.count > 1 else { return runs }

    var result: [AttributeRun] = []

    for run in runs {
      if let last = result.last,
         last.range.upperBound == run.range.lowerBound,
         last.attributesEqual(to: run) {
        // Merge with previous run
        let merged = AttributeRun(
          range: last.range.lowerBound..<run.range.upperBound,
          attributes: last.attributes
        )
        result[result.count - 1] = merged
      } else {
        result.append(run)
      }
    }

    return result
  }
}
