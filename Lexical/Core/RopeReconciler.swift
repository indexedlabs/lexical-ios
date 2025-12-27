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
    try reconcileInternal(
      from: prevState,
      to: nextState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection,
      markedTextOperation: nil
    )
  }

  /// Internal reconcile with marked text operation support.
  /// Called from Editor.swift during update cycle.
  @MainActor
  internal static func updateEditorState(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    markedTextOperation: MarkedTextOperation?
  ) throws {
    try reconcileInternal(
      from: currentEditorState,
      to: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection,
      markedTextOperation: markedTextOperation
    )
  }

  /// Internal implementation of reconciliation.
  private static func reconcileInternal(
    from prevState: EditorState?,
    to nextState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    markedTextOperation: MarkedTextOperation?
  ) throws {
    guard let textStorage = editor.textStorage else { return }

    // Composition (marked text) fast path first
    if let mto = markedTextOperation, mto.createMarkedText {
      if try handleComposition(
        nextState: nextState,
        editor: editor,
        textStorage: textStorage,
        operation: mto
      ) {
        return
      }
    }

    let theme = editor.getTheme()
    let dirtyNodes = editor.dirtyNodes

    // Categorize dirty nodes
    var inserts: [(key: NodeKey, node: Node)] = []
    var removes: [(key: NodeKey, node: Node)] = []
    var updates: [(key: NodeKey, prev: Node, next: Node)] = []

    for (key, _) in dirtyNodes {
      let prevNode = prevState?.nodeMap[key]
      let nextNode = nextState.nodeMap[key]

      // Check if this is actually a remove: node exists in both states but
      // has no parent in nextState (was detached)
      if let prev = prevNode, let next = nextNode {
        if next.parent == nil && !(next is RootNode) {
          // Node was detached from tree - treat as remove
          removes.append((key, prev))
          continue
        }
      }

      switch (prevNode, nextNode) {
      case (nil, let next?):
        inserts.append((key, next))
      case (let prev?, nil):
        removes.append((key, prev))
      case (let prev?, let next?):
        updates.append((key, prev, next))
      case (nil, nil):
        continue
      }
    }

    // Batch all text storage edits in a single editing session
    // This prevents layout manager from generating glyphs mid-edit
    let hasEdits = !removes.isEmpty || !inserts.isEmpty || !updates.isEmpty
    if hasEdits {
      textStorage.beginEditing()
    }

    defer {
      if hasEdits {
        textStorage.endEditing()
      }
    }

    // Process removes first (in reverse document order to avoid shifting issues)
    removes.sort { a, b in
      let aLoc = editor.rangeCache[a.key]?.location ?? 0
      let bLoc = editor.rangeCache[b.key]?.location ?? 0
      return aLoc > bLoc  // Reverse order
    }
    for (_, node) in removes {
      try removeNode(node, from: textStorage, editor: editor)
    }

    // Process inserts in document order
    inserts.sort { a, b in
      let posA = documentPosition(of: a.node, in: nextState)
      let posB = documentPosition(of: b.node, in: nextState)
      return comparePaths(posA, posB)
    }
    for (_, node) in inserts {
      try insertNode(node, into: textStorage, state: nextState, editor: editor, theme: theme)
    }

    // Process updates
    for (_, prev, next) in updates {
      try updateNode(from: prev, to: next, in: textStorage, state: nextState, editor: editor, theme: theme)
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
    }

    // Always update range cache for the node, even if empty.
    // This is needed because children will reference parent's cache.
    updateRangeCache(for: node, at: location, length: content.length, editor: editor)
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
    let oldLength = cacheItem.textLength
    let newLength = newContent.length
    let delta = newLength - oldLength

    let range = NSRange(location: cacheItem.location + cacheItem.preambleLength, length: oldLength)

    if range.location + range.length <= textStorage.length {
      textStorage.replaceCharacters(in: range, with: newContent)

      // Update range cache for this node
      var updatedItem = cacheItem
      updatedItem.textLength = newLength
      editor.rangeCache[next.key] = updatedItem

      // Shift all nodes after this one if length changed
      if delta != 0 {
        let afterLocation = cacheItem.location + cacheItem.preambleLength + newLength
        shiftRangeCacheAfter(location: afterLocation, delta: delta, excludingKeys: [next.key], editor: editor)

        // Update parent's childrenLength
        if let parent = next.getParent(), var parentCache = editor.rangeCache[parent.key] {
          parentCache.childrenLength += delta
          editor.rangeCache[parent.key] = parentCache
        }
      }
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

  // MARK: - Document Position

  /// Compute a comparable document position for a node.
  /// Returns an array of indices representing the path from root to the node.
  private static func documentPosition(of node: Node, in state: EditorState) -> [Int] {
    var path: [Int] = []
    var current: Node? = node

    while let cur = current, let parent = cur.getParent() {
      let siblings = parent.getChildrenKeys()
      if let index = siblings.firstIndex(of: cur.key) {
        path.insert(index, at: 0)
      }
      current = parent
    }

    return path
  }

  /// Compare two document paths. Returns true if a comes before b.
  private static func comparePaths(_ a: [Int], _ b: [Int]) -> Bool {
    for i in 0..<min(a.count, b.count) {
      if a[i] < b[i] { return true }
      if a[i] > b[i] { return false }
    }
    // Shorter path comes first (parent before children)
    return a.count < b.count
  }

  // MARK: - Location Computation

  /// Compute where to insert a node in the text storage.
  /// Assumes nodes are processed in document order, so preceding siblings are already in cache.
  private static func computeInsertLocation(
    for node: Node,
    parent: ElementNode,
    editor: Editor
  ) -> Int {
    // Get parent's cache item
    guard let parentCache = editor.rangeCache[parent.key] else { return 0 }

    // Find the index of this node in parent's children
    let children = parent.getChildrenKeys()
    guard let nodeIndex = children.firstIndex(of: node.key) else {
      // Append at end of parent's content
      return parentCache.location + parentCache.preambleLength + parentCache.childrenLength
    }

    // Sum lengths of preceding siblings (should all be in cache since we process in order)
    var offset = parentCache.location + parentCache.preambleLength

    for i in 0..<nodeIndex {
      if let siblingCache = editor.rangeCache[children[i]] {
        offset += siblingCache.entireLength
      }
    }

    return offset
  }

  /// Update range cache for a newly inserted node.
  /// Shifts all nodes after the insertion point and updates parent's childrenLength.
  private static func updateRangeCache(
    for node: Node,
    at location: Int,
    length: Int,
    editor: Editor
  ) {
    // Collect ancestor keys - we shouldn't shift ancestors since the insertion is inside them
    var ancestorKeys = Set<NodeKey>()
    var ancestor = node.getParent()
    while let a = ancestor {
      ancestorKeys.insert(a.key)
      ancestor = a.getParent()
    }

    // Shift all existing nodes that come after this insertion point (excluding ancestors)
    shiftRangeCacheAfter(location: location, delta: length, excludingKeys: ancestorKeys, editor: editor)

    // Create cache item for the new node
    var cacheItem = RangeCacheItem()
    cacheItem.location = location

    if let textNode = node as? TextNode {
      cacheItem.textLength = textNode.getTextPart().utf16.count
    } else if let elementNode = node as? ElementNode {
      cacheItem.preambleLength = elementNode.getPreamble().utf16.count
      cacheItem.postambleLength = elementNode.getPostamble().utf16.count
      // For element nodes, we need to compute childrenLength from the content
      // The length includes preamble + children + postamble
      let preambleLen = cacheItem.preambleLength
      let postambleLen = cacheItem.postambleLength
      cacheItem.childrenLength = length - preambleLen - postambleLen
    }

    editor.rangeCache[node.key] = cacheItem

    // Update parent's childrenLength
    if let parent = node.getParent(), var parentCache = editor.rangeCache[parent.key] {
      parentCache.childrenLength += length
      editor.rangeCache[parent.key] = parentCache
    }
  }

  /// Shift all range cache entries after the given location by delta.
  /// - Parameters:
  ///   - location: The insertion point
  ///   - delta: The length change
  ///   - excludingKeys: Keys to exclude from shifting (typically ancestors of the inserted node)
  ///   - editor: The editor instance
  private static func shiftRangeCacheAfter(
    location: Int,
    delta: Int,
    excludingKeys: Set<NodeKey> = [],
    editor: Editor
  ) {
    guard delta != 0 else { return }

    for (key, var item) in editor.rangeCache {
      if !excludingKeys.contains(key) && item.location >= location {
        item.location += delta
        editor.rangeCache[key] = item
      }
    }
  }

  // MARK: - Composition (Marked Text) Handling

  /// Handle composition (marked text / IME) operations.
  /// - Returns: `true` if the composition was handled, `false` to fall through to normal reconciliation.
  private static func handleComposition(
    nextState: EditorState,
    editor: Editor,
    textStorage: NSTextStorage,
    operation: MarkedTextOperation
  ) throws -> Bool {
    // Locate Point at replacement start if possible
    let startLocation = operation.selectionRangeToReplace.location
    let point = try? pointAtStringLocation(
      startLocation,
      searchDirection: .forward,
      rangeCache: editor.rangeCache
    )

    // Prepare attributed marked text with styles from owning node if available
    var attrs: [NSAttributedString.Key: Any] = [:]
    if let p = point, let node = nextState.nodeMap[p.key] {
      attrs = AttributeUtils.attributedStringStyles(
        from: node,
        state: nextState,
        theme: editor.getTheme()
      )
    }
    let markedAttr = NSAttributedString(string: operation.markedTextString, attributes: attrs)

    // Replace characters in storage at requested range
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: operation.selectionRangeToReplace, with: markedAttr)
    textStorage.fixAttributes(
      in: NSRange(location: operation.selectionRangeToReplace.location, length: markedAttr.length)
    )
    textStorage.endEditing()

    // Update range cache if we can resolve to a TextNode
    if let p = point, let _ = nextState.nodeMap[p.key] as? TextNode {
      let delta = markedAttr.length - operation.selectionRangeToReplace.length
      updateRangeCacheForTextChange(nodeKey: p.key, delta: delta, editor: editor)
    }

    // Set marked text via frontend API
    if let p = point {
      let startPoint = p
      let endPoint = Point(key: p.key, offset: p.offset + markedAttr.length, type: .text)
      try updateNativeSelection(
        editor: editor,
        selection: RangeSelection(anchor: startPoint, focus: endPoint, format: TextFormat())
      )
    }
    setMarkedTextFromReconciler(
      editor: editor,
      markedText: markedAttr,
      selectedRange: operation.markedTextInternalSelection
    )

    return true
  }

  /// Update range cache after a text change.
  private static func updateRangeCacheForTextChange(
    nodeKey: NodeKey,
    delta: Int,
    editor: Editor
  ) {
    guard delta != 0 else { return }
    guard var cacheItem = editor.rangeCache[nodeKey] else { return }

    cacheItem.textLength += delta
    editor.rangeCache[nodeKey] = cacheItem

    // Shift all nodes after this one
    for (key, var item) in editor.rangeCache where key != nodeKey {
      if item.location > cacheItem.location {
        item.location += delta
        editor.rangeCache[key] = item
      }
    }
  }

  /// Set marked text via frontend.
  private static func setMarkedTextFromReconciler(
    editor: Editor,
    markedText: NSAttributedString,
    selectedRange: NSRange
  ) {
    #if canImport(UIKit)
    editor.frontend?.setMarkedTextFromReconciler(markedText, selectedRange: selectedRange)
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    editor.frontendAppKit?.setMarkedTextFromReconciler(markedText, selectedRange: selectedRange)
    #endif
  }
}
