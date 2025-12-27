/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - RopeTextStorage

/// An NSTextStorage subclass backed by a Rope data structure.
/// Provides O(log N) insert/delete operations instead of O(N).
@MainActor
public class RopeTextStorage: NSTextStorage {

  // MARK: - Properties

  /// The rope backing store.
  private var rope: Rope<AttributedChunk>

  /// Cached materialized string (invalidated on edit).
  private var cachedString: String?

  /// Whether the cached string is valid.
  private var cacheValid: Bool = false

  // MARK: - Initialization

  /// Create an empty RopeTextStorage.
  public override init() {
    self.rope = Rope()
    super.init()
  }

  /// Create a RopeTextStorage with initial content.
  public override convenience init(string str: String) {
    self.init()
    if !str.isEmpty {
      replaceCharacters(in: NSRange(location: 0, length: 0), with: str)
    }
  }

  /// Create a RopeTextStorage from an attributed string.
  public override convenience init(attributedString attrStr: NSAttributedString) {
    self.init()
    if attrStr.length > 0 {
      replaceCharacters(in: NSRange(location: 0, length: 0), with: attrStr)
    }
  }

  public required init?(coder: NSCoder) {
    self.rope = Rope()
    super.init(coder: coder)
  }

  #if os(macOS)
  public required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
    self.rope = Rope()
    super.init(pasteboardPropertyList: propertyList, ofType: type)
  }
  #endif

  // MARK: - NSTextStorage Primitives (Required Overrides)

  /// The string content (materialized from rope).
  public override var string: String {
    ensureMaterialized()
    return cachedString ?? ""
  }

  /// The length in UTF-16 code units.
  public override var length: Int {
    rope.length
  }

  /// Get attributes at a location.
  public override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
    guard location < rope.length else {
      range?.pointee = NSRange(location: location, length: 0)
      return [:]
    }

    // Find the chunk containing this location
    let (chunk, offsetInChunk) = rope.chunk(at: location)

    // Get attributes from the chunk
    var swiftRange = 0..<0
    let attrs = chunk.attributes(at: offsetInChunk, effectiveRange: &swiftRange)

    // Convert to NSRange, accounting for chunk's position in the rope
    if let range = range {
      // We need to find the chunk's absolute position
      // For now, return the effective range within what we know
      let chunkStart = location - offsetInChunk
      range.pointee = NSRange(location: chunkStart + swiftRange.lowerBound, length: swiftRange.count)
    }

    return attrs
  }

  /// Replace characters in a range.
  public override func replaceCharacters(in range: NSRange, with str: String) {
    let attrStr = NSAttributedString(string: str)
    replaceCharacters(in: range, with: attrStr)
  }

  /// Replace characters with an attributed string.
  public override func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
    let delta = attrString.length - range.length

    beginEditing()

    // Delete the range first
    if range.length > 0 {
      rope.delete(range: range.location..<(range.location + range.length))
    }

    // Insert the new content
    if attrString.length > 0 {
      let chunk = chunkFromAttributedString(attrString)
      rope.insert(chunk, at: range.location)
    }

    invalidateCache()

    edited(.editedCharacters, range: range, changeInLength: delta)

    endEditing()
  }

  /// Set attributes on a range.
  public override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
    guard range.length > 0 && range.location + range.length <= rope.length else { return }

    beginEditing()

    // Extract the affected portion, modify attributes, and reinsert
    let rangeEnd = range.location + range.length

    // Split at end first, then at start
    let (beforeEnd, afterEnd) = rope.split(at: rangeEnd)
    let (before, middle) = beforeEnd.split(at: range.location)

    // Create new chunk with updated attributes
    if middle.length > 0 {
      let text = collectText(from: middle)
      let newChunk = AttributedChunk(text: text, attributes: attrs ?? [:])

      // Reconstruct the rope
      var newRope = before
      newRope.insert(newChunk, at: before.length)
      if afterEnd.length > 0 {
        // Concat with the rest
        for i in 0..<afterEnd.length {
          let (chunk, offset) = afterEnd.chunk(at: i)
          if offset == 0 {
            newRope.insert(chunk, at: newRope.length)
          }
          break // We just need to copy the chunks, not iterate through chars
        }
        // Actually, let's just rebuild properly
        rope = Rope.concat(Rope.concat(before, Rope(chunk: newChunk)), afterEnd)
      } else {
        rope = Rope.concat(before, Rope(chunk: newChunk))
      }
    }

    invalidateCache()

    edited(.editedAttributes, range: range, changeInLength: 0)

    endEditing()
  }

  // MARK: - Cache Management

  /// Ensure the string cache is up to date.
  private func ensureMaterialized() {
    guard !cacheValid else { return }
    cachedString = collectText(from: rope)
    cacheValid = true
  }

  /// Invalidate the string cache.
  private func invalidateCache() {
    cacheValid = false
    cachedString = nil
  }

  // MARK: - Helpers

  /// Convert an NSAttributedString to an AttributedChunk.
  private func chunkFromAttributedString(_ attrStr: NSAttributedString) -> AttributedChunk {
    guard attrStr.length > 0 else {
      return AttributedChunk(text: "")
    }

    var runs: [AttributeRun] = []
    var index = 0

    while index < attrStr.length {
      var effectiveRange = NSRange()
      let attrs = attrStr.attributes(at: index, effectiveRange: &effectiveRange)

      let run = AttributeRun(
        range: effectiveRange.location..<(effectiveRange.location + effectiveRange.length),
        attributes: attrs
      )
      runs.append(run)

      index = effectiveRange.location + effectiveRange.length
    }

    return AttributedChunk(text: attrStr.string, runs: runs)
  }

  /// Collect all text from a rope into a single string.
  private func collectText(from rope: Rope<AttributedChunk>) -> String {
    guard rope.length > 0 else { return "" }

    var result = ""
    var seen = Set<Int>()
    var position = 0

    while position < rope.length {
      let (chunk, offset) = rope.chunk(at: position)
      let chunkStart = position - offset

      if !seen.contains(chunkStart) {
        result += chunk.text
        seen.insert(chunkStart)
        position = chunkStart + chunk.length
      } else {
        position += 1
      }
    }

    return result
  }
}
