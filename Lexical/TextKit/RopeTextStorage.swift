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
// MARK: - CacheRegion

/// A cached region of materialized text.
private struct CacheRegion {
  /// Range in the document (UTF-16 code units).
  var range: Range<Int>
  /// The cached string content for this region.
  let content: String

  /// Shift this region's range by a delta.
  func shifted(by delta: Int) -> CacheRegion {
    let newRange = (range.lowerBound + delta)..<(range.upperBound + delta)
    return CacheRegion(range: newRange, content: content)
  }
}

@MainActor
public class RopeTextStorage: NSTextStorage {

  // MARK: - Properties

  /// The rope backing store.
  private var rope: Rope<AttributedChunk>

  /// Cached regions of materialized text, sorted by range.lowerBound.
  /// On edit, only overlapping regions are invalidated; others are shifted.
  private var cacheRegions: [CacheRegion] = []

  /// Full cached string (built on demand from regions + gaps).
  private var cachedString: String?

  /// Whether the full cached string is valid.
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
    let affectedRange = range.location..<(range.location + range.length)

    beginEditing()

    // Delete the range first
    if range.length > 0 {
      rope.delete(range: affectedRange)
    }

    // Insert the new content
    if attrString.length > 0 {
      let chunk = chunkFromAttributedString(attrString)
      rope.insert(chunk, at: range.location)
    }

    // Incremental cache invalidation: only invalidate affected region
    invalidateCache(affectedRange: affectedRange, delta: delta)

    edited(.editedCharacters, range: range, changeInLength: delta)

    endEditing()
  }

  /// Set attributes on a range.
  /// Uses O(log N) rope operations.
  public override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
    guard range.length > 0 && range.location + range.length <= rope.length else { return }

    beginEditing()

    // Split rope into: [before | middle | after]
    let rangeEnd = range.location + range.length
    let (beforeEnd, afterEnd) = rope.split(at: rangeEnd)
    let (before, middle) = beforeEnd.split(at: range.location)

    // Create new chunk with updated attributes
    if middle.length > 0 {
      let text = collectText(from: middle)
      let newChunk = AttributedChunk(text: text, attributes: attrs ?? [:])

      // Reconstruct: before + newChunk + afterEnd (all O(log N) operations)
      let withNew = Rope.concat(before, Rope(chunk: newChunk))
      rope = Rope.concat(withNew, afterEnd)
    }

    invalidateCache()

    edited(.editedAttributes, range: range, changeInLength: 0)

    endEditing()
  }

  // MARK: - Optimized Accessors

  /// Extract a substring without materializing the entire string.
  /// When cache is valid, uses default implementation (fast string subscript).
  /// When cache is invalid, uses rope to avoid full materialization.
  public override func attributedSubstring(from range: NSRange) -> NSAttributedString {
    guard range.length > 0 && range.location + range.length <= rope.length else {
      return NSAttributedString()
    }

    // If cache is valid, use default implementation (it's fast with cached string)
    if cacheValid {
      return super.attributedSubstring(from: range)
    }

    // Cache invalid: use rope to extract only needed range (avoids full materialization)
    let rangeEnd = range.location + range.length
    let (beforeEnd, _) = rope.split(at: rangeEnd)
    let (_, middle) = beforeEnd.split(at: range.location)

    // Fast path: single chunk - return directly
    let chunks = middle.chunks
    if chunks.count == 1 {
      return chunks[0].toAttributedString()
    }

    if chunks.isEmpty {
      return NSAttributedString()
    }

    // Collect text and attribute runs
    var combinedText = ""
    var allRuns: [(range: NSRange, attrs: [NSAttributedString.Key: Any])] = []
    var offset = 0

    for chunk in chunks {
      combinedText += chunk.text
      for run in chunk.attributeRuns {
        let adjustedRange = NSRange(
          location: offset + run.range.lowerBound,
          length: run.range.count
        )
        allRuns.append((adjustedRange, run.attributes))
      }
      offset += chunk.length
    }

    // Fast path: no attributes → immutable string directly
    if allRuns.isEmpty {
      return NSAttributedString(string: combinedText)
    }

    // Fast path: single run covering everything → immutable string with attributes
    if allRuns.count == 1 && allRuns[0].range.location == 0 && allRuns[0].range.length == combinedText.utf16.count {
      return NSAttributedString(string: combinedText, attributes: allRuns[0].attrs)
    }

    // Multiple runs: need mutable to apply different attributes to different ranges
    let result = NSMutableAttributedString(string: combinedText)
    for (range, attrs) in allRuns {
      result.addAttributes(attrs, range: range)
    }
    return result
  }

  // MARK: - Cache Management

  /// Ensure the string cache is up to date.
  /// Uses incremental materialization: only fills gaps between cached regions.
  private func ensureMaterialized() {
    guard !cacheValid else { return }

    if cacheRegions.isEmpty {
      // No cached regions - materialize everything and cache the whole thing
      let text = collectText(from: rope)
      cachedString = text
      if rope.length > 0 {
        cacheRegions.append(CacheRegion(range: 0..<rope.length, content: text))
      }
    } else {
      // Build from cached regions + gap fills
      cachedString = buildStringFromRegions()
      // After building, we have a complete cache, so replace regions with one full region
      if let text = cachedString, rope.length > 0 {
        cacheRegions = [CacheRegion(range: 0..<rope.length, content: text)]
      }
    }
    cacheValid = true
  }

  /// Invalidate cache for an edit at the given range with the given length change.
  /// Only invalidates overlapping regions; shifts others appropriately.
  private func invalidateCache(affectedRange: Range<Int>, delta: Int) {
    cacheValid = false
    cachedString = nil

    // Remove regions that overlap with the edit
    // Shift regions after the edit by delta
    var newRegions: [CacheRegion] = []

    for region in cacheRegions {
      if region.range.upperBound <= affectedRange.lowerBound {
        // Region is entirely before the edit - keep it
        newRegions.append(region)
      } else if region.range.lowerBound >= affectedRange.upperBound {
        // Region is entirely after the edit - shift it
        if delta != 0 {
          newRegions.append(region.shifted(by: delta))
        } else {
          newRegions.append(region)
        }
      }
      // Regions overlapping the edit are dropped (not added to newRegions)
    }

    cacheRegions = newRegions
  }

  /// Simple full invalidation (used by setAttributes which changes content in-place).
  private func invalidateCache() {
    cacheValid = false
    cachedString = nil
    cacheRegions.removeAll()
  }

  /// Build the full string from cached regions plus gap fills.
  private func buildStringFromRegions() -> String {
    guard rope.length > 0 else { return "" }

    var result: [String] = []
    var position = 0

    for region in cacheRegions {
      // Fill gap before this region if needed
      if position < region.range.lowerBound {
        let gapText = collectTextRange(from: position, to: region.range.lowerBound)
        result.append(gapText)
      }

      // Add cached region
      result.append(region.content)
      position = region.range.upperBound
    }

    // Fill gap after last region
    if position < rope.length {
      let gapText = collectTextRange(from: position, to: rope.length)
      result.append(gapText)
    }

    return result.joined()
  }

  /// Collect text for a specific range using rope operations.
  private func collectTextRange(from start: Int, to end: Int) -> String {
    guard start < end && end <= rope.length else { return "" }

    let (beforeEnd, _) = rope.split(at: end)
    let (_, middle) = beforeEnd.split(at: start)

    var parts: [String] = []
    middle.forEachChunk { parts.append($0.text) }
    return parts.joined()
  }

  /// Add a cache region after materialization.
  private func addCacheRegion(_ content: String, range: Range<Int>) {
    let region = CacheRegion(range: range, content: content)
    // Insert in sorted order
    if let index = cacheRegions.firstIndex(where: { $0.range.lowerBound > range.lowerBound }) {
      cacheRegions.insert(region, at: index)
    } else {
      cacheRegions.append(region)
    }
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
  /// Uses O(N) chunk iteration instead of O(N log N) position lookups.
  private func collectText(from rope: Rope<AttributedChunk>) -> String {
    guard rope.length > 0 else { return "" }

    var parts: [String] = []
    rope.forEachChunk { parts.append($0.text) }
    return parts.joined()
  }
}
