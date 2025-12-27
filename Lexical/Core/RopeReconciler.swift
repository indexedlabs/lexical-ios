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

// MARK: - RopeReconciler

/// A simplified reconciler designed to work with RopeTextStorage.
/// Replaces the complex fast-path system in OptimizedReconciler with
/// straightforward O(log N) operations on the rope.
@MainActor
public enum RopeReconciler {

  // MARK: - Public API

  /// Reconcile changes from prevState to nextState.
  /// - Parameters:
  ///   - prevState: The previous editor state.
  ///   - nextState: The next editor state.
  ///   - editor: The editor instance.
  ///   - shouldReconcileSelection: Whether to update the selection.
  public static func reconcile(
    from prevState: EditorState?,
    to nextState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool = true
  ) throws {
    guard let textStorage = editor.textStorage else { return }

    let theme = editor.getTheme()
    let dirtyNodes = editor.dirtyNodes

    // Process each dirty node
    for (key, dirtyType) in dirtyNodes {
      let prevNode = prevState?.nodeMap[key]
      let nextNode = nextState.nodeMap[key]

      switch (prevNode, nextNode, dirtyType) {
      case (nil, let next?, _):
        // Node was added
        try insertNode(next, into: textStorage, state: nextState, editor: editor, theme: theme)

      case (let prev?, nil, _):
        // Node was removed
        try removeNode(prev, from: textStorage, editor: editor)

      case (let prev?, let next?, _):
        // Node was modified
        try updateNode(from: prev, to: next, in: textStorage, state: nextState, editor: editor, theme: theme)

      case (nil, nil, _):
        // Shouldn't happen - skip
        continue
      }
    }

    // Reconcile selection
    if shouldReconcileSelection {
      try reconcileSelection(
        prevSelection: prevState?.selection,
        nextSelection: nextState.selection,
        editor: editor
      )
    }
  }

  // MARK: - Node Operations

  /// Insert a node into the text storage.
  private static func insertNode(
    _ node: Node,
    into textStorage: NSTextStorage,
    state: EditorState,
    editor: Editor,
    theme: Theme
  ) throws {
    // Only handle text-producing nodes
    guard let parent = node.getParent() else { return }

    // Get insert location from range cache or compute it
    let location = computeInsertLocation(for: node, parent: parent, editor: editor)

    // Build attributed content
    let content = buildAttributedContent(for: node, state: state, theme: theme)

    if content.length > 0 {
      textStorage.insert(content, at: location)

      // Update range cache for this node
      updateRangeCache(for: node, at: location, length: content.length, editor: editor)
    }
  }

  /// Remove a node from the text storage.
  private static func removeNode(
    _ node: Node,
    from textStorage: NSTextStorage,
    editor: Editor
  ) throws {
    guard let cacheItem = editor.rangeCache[node.key] else { return }

    let range = cacheItem.range
    if range.length > 0 && range.location + range.length <= textStorage.length {
      textStorage.deleteCharacters(in: range)
    }

    // Remove from range cache
    editor.rangeCache.removeValue(forKey: node.key)
  }

  /// Update a node that has been modified.
  private static func updateNode(
    from prev: Node,
    to next: Node,
    in textStorage: NSTextStorage,
    state: EditorState,
    editor: Editor,
    theme: Theme
  ) throws {
    // Handle text node changes
    if let prevText = prev as? TextNode, let nextText = next as? TextNode {
      try updateTextNode(from: prevText, to: nextText, in: textStorage, state: state, editor: editor, theme: theme)
      return
    }

    // Handle element node changes (children may have changed)
    if let prevElement = prev as? ElementNode, let nextElement = next as? ElementNode {
      try updateElementNode(from: prevElement, to: nextElement, in: textStorage, state: state, editor: editor, theme: theme)
      return
    }

    // Fallback: remove and reinsert
    try removeNode(prev, from: textStorage, editor: editor)
    try insertNode(next, into: textStorage, state: state, editor: editor, theme: theme)
  }

  /// Update a text node.
  private static func updateTextNode(
    from prev: TextNode,
    to next: TextNode,
    in textStorage: NSTextStorage,
    state: EditorState,
    editor: Editor,
    theme: Theme
  ) throws {
    guard let cacheItem = editor.rangeCache[prev.key] else { return }

    let newContent = buildAttributedContent(for: next, state: state, theme: theme)
    let range = NSRange(location: cacheItem.location + cacheItem.preambleLength, length: cacheItem.textLength)

    if range.location + range.length <= textStorage.length {
      textStorage.replaceCharacters(in: range, with: newContent)

      // Update range cache
      var updatedItem = cacheItem
      updatedItem.textLength = newContent.length
      editor.rangeCache[next.key] = updatedItem
    }
  }

  /// Update an element node.
  private static func updateElementNode(
    from prev: ElementNode,
    to next: ElementNode,
    in textStorage: NSTextStorage,
    state: EditorState,
    editor: Editor,
    theme: Theme
  ) throws {
    // For element nodes, we mainly care about preamble/postamble changes
    // Children are handled separately via their own dirty tracking

    // Check if preamble changed
    let prevPreamble = prev.getPreamble()
    let nextPreamble = next.getPreamble()

    if prevPreamble != nextPreamble {
      // Update preamble in text storage
      if let cacheItem = editor.rangeCache[prev.key] {
        let preambleRange = NSRange(location: cacheItem.location, length: cacheItem.preambleLength)
        if preambleRange.location + preambleRange.length <= textStorage.length {
          textStorage.replaceCharacters(in: preambleRange, with: nextPreamble)
        }
      }
    }

    // Check if postamble changed
    let prevPostamble = prev.getPostamble()
    let nextPostamble = next.getPostamble()

    if prevPostamble != nextPostamble {
      if let cacheItem = editor.rangeCache[prev.key] {
        let postambleStart = cacheItem.location + cacheItem.preambleLength + cacheItem.childrenLength + cacheItem.textLength
        let postambleRange = NSRange(location: postambleStart, length: cacheItem.postambleLength)
        if postambleRange.location + postambleRange.length <= textStorage.length {
          textStorage.replaceCharacters(in: postambleRange, with: nextPostamble)
        }
      }
    }
  }

  // MARK: - Selection Reconciliation

  /// Reconcile the selection after node changes.
  /// Maps Lexical selection to native text view selection via the frontend.
  private static func reconcileSelection(
    prevSelection: BaseSelection?,
    nextSelection: BaseSelection?,
    editor: Editor
  ) throws {
    // If no next selection, reset if previous was dirty
    guard let nextSelection else {
      if let prevSelection {
        if !prevSelection.dirty {
          return
        }
        resetSelectedRange(editor: editor)
      }
      return
    }

    // Update the native selection to match the Lexical selection
    try updateNativeSelection(editor: editor, selection: nextSelection)
  }

  /// Reset the native selection (clear it).
  private static func resetSelectedRange(editor: Editor) {
    #if canImport(UIKit)
    editor.frontend?.resetSelectedRange()
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    editor.frontendAppKit?.resetSelectedRange()
    #endif
  }

  /// Update the native selection to match a Lexical selection.
  private static func updateNativeSelection(editor: Editor, selection: BaseSelection) throws {
    #if canImport(UIKit)
    try editor.frontend?.updateNativeSelection(from: selection)
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    try editor.frontendAppKit?.updateNativeSelection(from: selection)
    #endif
  }

  // MARK: - Content Building

  /// Build attributed string content for a node.
  public static func buildAttributedContent(
    for node: Node,
    state: EditorState,
    theme: Theme
  ) -> NSAttributedString {
    if let textNode = node as? TextNode {
      return buildTextNodeContent(textNode, state: state, theme: theme)
    }

    if let elementNode = node as? ElementNode {
      return buildElementNodeContent(elementNode, state: state, theme: theme)
    }

    // For other node types, return their text representation
    let text = node.getTextPart()
    return NSAttributedString(string: text)
  }

  /// Build content for a text node.
  private static func buildTextNodeContent(
    _ node: TextNode,
    state: EditorState,
    theme: Theme
  ) -> NSAttributedString {
    let text = node.getTextPart()
    let attributes = AttributeUtils.attributedStringStyles(from: node, state: state, theme: theme)
    return NSAttributedString(string: text, attributes: attributes)
  }

  /// Build content for an element node (preamble + children + postamble).
  private static func buildElementNodeContent(
    _ node: ElementNode,
    state: EditorState,
    theme: Theme
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()

    // Add preamble
    let preamble = node.getPreamble()
    if !preamble.isEmpty {
      result.append(NSAttributedString(string: preamble))
    }

    // Add children content
    for childKey in node.getChildrenKeys() {
      if let child = state.nodeMap[childKey] {
        result.append(buildAttributedContent(for: child, state: state, theme: theme))
      }
    }

    // Add postamble
    let postamble = node.getPostamble()
    if !postamble.isEmpty {
      result.append(NSAttributedString(string: postamble))
    }

    return result
  }

  // MARK: - Location Computation

  /// Compute where to insert a node in the text storage.
  private static func computeInsertLocation(
    for node: Node,
    parent: ElementNode,
    editor: Editor
  ) -> Int {
    // Get parent's cache item
    guard let parentCache = editor.rangeCache[parent.key] else {
      return 0
    }

    // Find the index of this node in parent's children
    let children = parent.getChildrenKeys()
    guard let nodeIndex = children.firstIndex(of: node.key) else {
      // Append at end of parent's content
      return parentCache.location + parentCache.preambleLength + parentCache.childrenLength
    }

    // Sum lengths of preceding siblings
    var offset = parentCache.location + parentCache.preambleLength

    for i in 0..<nodeIndex {
      if let siblingCache = editor.rangeCache[children[i]] {
        offset += siblingCache.entireLength
      }
    }

    return offset
  }

  /// Update range cache for a newly inserted node.
  private static func updateRangeCache(
    for node: Node,
    at location: Int,
    length: Int,
    editor: Editor
  ) {
    var cacheItem = RangeCacheItem()
    cacheItem.location = location

    if let textNode = node as? TextNode {
      cacheItem.textLength = textNode.getTextPart().utf16.count
    } else if let elementNode = node as? ElementNode {
      cacheItem.preambleLength = elementNode.getPreamble().utf16.count
      cacheItem.postambleLength = elementNode.getPostamble().utf16.count
      // Children lengths are tracked separately
    }

    editor.rangeCache[node.key] = cacheItem
  }
}
