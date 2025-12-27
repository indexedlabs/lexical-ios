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

    let shouldRecordMetrics =
      editor.metricsContainer != nil
      && (editor.dirtyType != .noDirtyNodes || markedTextOperation != nil)

    let metricsStart = CFAbsoluteTimeGetCurrent()
    let dirtyNodesCount = editor.dirtyNodes.count
    let rangeCacheCountBefore = editor.rangeCache.count
    let treatedAllNodesAsDirty = editor.dirtyType == .fullReconcile
    var pathLabel: String? = nil
    var planningDuration: TimeInterval = 0
    var applyDuration: TimeInterval = 0
    var didReconcile = false

    defer {
      if shouldRecordMetrics, didReconcile, let metrics = editor.metricsContainer {
        let duration = CFAbsoluteTimeGetCurrent() - metricsStart
        let rangeCacheCountAfter = editor.rangeCache.count
        let rangesAdded = max(0, rangeCacheCountAfter - rangeCacheCountBefore)
        let rangesDeleted = max(0, rangeCacheCountBefore - rangeCacheCountAfter)

        metrics.record(.reconcilerRun(
          ReconcilerMetric(
            duration: duration,
            dirtyNodes: dirtyNodesCount,
            rangesAdded: rangesAdded,
            rangesDeleted: rangesDeleted,
            treatedAllNodesAsDirty: treatedAllNodesAsDirty,
            pathLabel: pathLabel,
            planningDuration: planningDuration,
            applyDuration: applyDuration
          )
        ))
      }
    }

    // Composition (marked text) fast path first
    if let mto = markedTextOperation, mto.createMarkedText {
      pathLabel = "rope-composition"
      if try handleComposition(
        nextState: nextState,
        editor: editor,
        textStorage: textStorage,
        operation: mto
      ) {
        didReconcile = true
        applyDuration = CFAbsoluteTimeGetCurrent() - metricsStart
        return
      }
    }

    // Full-editor-state swaps (e.g. `Editor.setEditorState`) must rebuild the entire TextStorage.
    if editor.dirtyType == .fullReconcile {
      didReconcile = true
      pathLabel = "rope-full-reconcile"
      let applyStart = CFAbsoluteTimeGetCurrent()
      planningDuration = applyStart - metricsStart
      try fullReconcile(
        nextState: nextState,
        editor: editor,
        textStorage: textStorage,
        shouldReconcileSelection: shouldReconcileSelection
      )
      applyDuration = CFAbsoluteTimeGetCurrent() - applyStart
      return
    }

    // Fresh-document fast hydration: build full string + cache in one pass
    if shouldHydrateFreshDocument(pendingState: nextState, editor: editor, textStorage: textStorage) {
      didReconcile = true
      pathLabel = "rope-hydrate-fresh"
      let applyStart = CFAbsoluteTimeGetCurrent()
      planningDuration = applyStart - metricsStart
      try hydrateFreshDocumentFully(
        pendingState: nextState,
        editor: editor,
        textStorage: textStorage,
        shouldReconcileSelection: shouldReconcileSelection
      )
      applyDuration = CFAbsoluteTimeGetCurrent() - applyStart
      return
    }

    // Selection-only updates should not pay the cost of diffing/reconciling the entire document.
    if editor.dirtyType == .noDirtyNodes {
      if shouldReconcileSelection {
        let prevSelection = prevState?.selection
        let nextSelection = nextState.selection
        var selectionsAreDifferent = false
        if let nextSelection, let prevSelection {
          selectionsAreDifferent = !nextSelection.isSelection(prevSelection)
        }
        if nextSelection == nil || selectionsAreDifferent {
          try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
        }
      }
      return
    }

    let theme = editor.getTheme()
    let dirtyNodes = editor.dirtyNodes

    // Categorize dirty nodes
    var inserts: [(key: NodeKey, node: Node)] = []
    var removes: [(key: NodeKey, node: Node)] = []
    var updates: [(key: NodeKey, prev: Node, next: Node)] = []

    // Track which keys are being inserted so we can skip children of inserted parents
    var insertedKeys = Set<NodeKey>()

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
        insertedKeys.insert(key)
      case (let prev?, nil):
        removes.append((key, prev))
      case (let prev?, let next?):
        updates.append((key, prev, next))
      case (nil, nil):
        continue
      }
    }

    // Filter inserts: skip nodes whose parent is also being inserted
    // (parent's buildAttributedContent already includes children)
    inserts = inserts.filter { (_, node) in
      guard let parentKey = node.parent else { return true }
      return !insertedKeys.contains(parentKey)
    }

    // Batch all text storage edits in a single editing session
    // This prevents layout manager from generating glyphs mid-edit
    let hasEdits = !removes.isEmpty || !inserts.isEmpty || !updates.isEmpty

    didReconcile = true
    if !inserts.isEmpty && removes.isEmpty && updates.isEmpty {
      pathLabel = "rope-insert-only"
    } else if inserts.isEmpty && !removes.isEmpty && updates.isEmpty {
      pathLabel = "rope-remove-only"
    } else if inserts.isEmpty && removes.isEmpty && updates.allSatisfy({ $0.prev is TextNode && $0.next is TextNode }) {
      pathLabel = "rope-text-only"
    } else {
      pathLabel = "rope-mixed"
    }

    let applyStart = CFAbsoluteTimeGetCurrent()
    planningDuration = applyStart - metricsStart

    // Set mode to controllerMode so TextStorage accepts our attributed strings
    #if canImport(UIKit)
    var previousMode: TextStorageEditingMode = .none
    if hasEdits {
      previousMode = (textStorage as? ReconcilerTextStorage)?.mode ?? .none
      (textStorage as? ReconcilerTextStorage)?.mode = .controllerMode
    }
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    var previousMode: TextStorageEditingMode = .none
    if hasEdits {
      previousMode = (textStorage as? ReconcilerTextStorageAppKit)?.mode ?? .none
      (textStorage as? ReconcilerTextStorageAppKit)?.mode = .controllerMode
    }
    #endif

    if hasEdits {
      textStorage.beginEditing()
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

    // End editing BEFORE selection reconciliation to avoid glyph generation crash
    if hasEdits {
      textStorage.endEditing()

      // Restore previous mode
      #if canImport(UIKit)
      (textStorage as? ReconcilerTextStorage)?.mode = previousMode
      #elseif os(macOS) && !targetEnvironment(macCatalyst)
      (textStorage as? ReconcilerTextStorageAppKit)?.mode = previousMode
      #endif
    }
    applyDuration = CFAbsoluteTimeGetCurrent() - applyStart

    // Reconcile decorator operations
    if let prevState = prevState {
      reconcileDecoratorOpsForSubtree(
        ancestorKey: kRootNodeKey,
        prevState: prevState,
        nextState: nextState,
        editor: editor
      )
    }
    syncDecoratorPositionCacheWithRangeCache(editor: editor)

    // Reconcile selection (must happen AFTER endEditing to avoid layout manager crash)
    if shouldReconcileSelection {
      try reconcileSelection(
        prevSelection: prevState?.selection,
        nextSelection: nextState.selection,
        editor: editor
      )
    }
  }

  // MARK: - Fresh Document Hydration

  /// Check if we should hydrate a fresh document (empty textStorage, non-empty pending state).
  private static func shouldHydrateFreshDocument(
    pendingState: EditorState,
    editor: Editor,
    textStorage: NSTextStorage
  ) -> Bool {
    // Only hydrate if textStorage is empty
    guard textStorage.length == 0 else { return false }

    // Check if pending state has actual content
    guard let root = pendingState.getRootNode() else { return false }
    let children = root.getChildrenKeys(fromLatest: false)
    if children.isEmpty { return false }

    // Compute total content length
    var totalLength = 0
    for childKey in children {
      totalLength += subtreeTotalLength(nodeKey: childKey, state: pendingState)
    }

    // Only hydrate if there's actual content
    return totalLength > 0
  }

  /// Compute the total text length of a subtree.
  private static func subtreeTotalLength(nodeKey: NodeKey, state: EditorState) -> Int {
    guard let node = state.nodeMap[nodeKey] else { return 0 }
    var length = node.getPreamble().utf16.count + node.getTextPart().utf16.count + node.getPostamble().utf16.count

    if let element = node as? ElementNode {
      for childKey in element.getChildrenKeys(fromLatest: false) {
        length += subtreeTotalLength(nodeKey: childKey, state: state)
      }
    }

    return length
  }

  /// Hydrate a fresh document by building the full attributed string and range cache.
  private static func hydrateFreshDocumentFully(
    pendingState: EditorState,
    editor: Editor,
    textStorage: NSTextStorage,
    shouldReconcileSelection: Bool
  ) throws {
    let theme = editor.getTheme()

    // Build full attributed content for root's children
    let built = NSMutableAttributedString()
    if let root = pendingState.getRootNode() {
      for childKey in root.getChildrenKeys(fromLatest: false) {
        appendAttributedSubtree(into: built, nodeKey: childKey, state: pendingState, theme: theme)
      }
    }

    // Set mode to controllerMode so TextStorage accepts our attributed string
    #if canImport(UIKit)
    let previousMode = (textStorage as? ReconcilerTextStorage)?.mode ?? .none
    (textStorage as? ReconcilerTextStorage)?.mode = .controllerMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    let previousMode: TextStorageEditingMode = (textStorage as? ReconcilerTextStorageAppKit)?.mode ?? .none
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = .controllerMode
    #endif

    // Replace textStorage contents
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: built)
    textStorage.fixAttributes(in: NSRange(location: 0, length: built.length))
    textStorage.endEditing()

    // Restore previous mode
    #if canImport(UIKit)
    (textStorage as? ReconcilerTextStorage)?.mode = previousMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = previousMode
    #endif

    // Recompute range cache from root
    _ = recomputeRangeCacheSubtree(nodeKey: kRootNodeKey, state: pendingState, startLocation: 0, editor: editor)
    editor.invalidateDFSOrderCache()

    // Reconcile decorator operations
    reconcileDecoratorOpsForSubtree(
      ancestorKey: kRootNodeKey,
      prevState: editor.getEditorState(),
      nextState: pendingState,
      editor: editor
    )
    syncDecoratorPositionCacheWithRangeCache(editor: editor)

    // Reconcile selection after textStorage is fully updated
    if shouldReconcileSelection {
      try reconcileSelection(
        prevSelection: nil,
        nextSelection: pendingState.selection,
        editor: editor
      )
    }
  }

  /// Full reconcile fallback - rebuild entire textStorage from pending state.
  private static func fullReconcile(
    nextState: EditorState,
    editor: Editor,
    textStorage: NSTextStorage,
    shouldReconcileSelection: Bool
  ) throws {
    let theme = editor.getTheme()
    let currentState = editor.getEditorState()

    // Build full attributed content
    let built = NSMutableAttributedString()
    if let root = nextState.getRootNode() {
      for childKey in root.getChildrenKeys(fromLatest: false) {
        appendAttributedSubtree(into: built, nodeKey: childKey, state: nextState, theme: theme)
      }
    }

    // Set mode to controllerMode so TextStorage accepts our attributed string
    #if canImport(UIKit)
    let previousMode = (textStorage as? ReconcilerTextStorage)?.mode ?? .none
    (textStorage as? ReconcilerTextStorage)?.mode = .controllerMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    let previousMode: TextStorageEditingMode = (textStorage as? ReconcilerTextStorageAppKit)?.mode ?? .none
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = .controllerMode
    #endif

    // Replace textStorage contents
    textStorage.beginEditing()
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.replaceCharacters(in: fullRange, with: built)
    textStorage.fixAttributes(in: NSRange(location: 0, length: built.length))
    textStorage.endEditing()

    // Restore previous mode
    #if canImport(UIKit)
    (textStorage as? ReconcilerTextStorage)?.mode = previousMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = previousMode
    #endif

    // Recompute entire range cache
    _ = recomputeRangeCacheSubtree(nodeKey: kRootNodeKey, state: nextState, startLocation: 0, editor: editor)
    pruneRangeCacheGlobally(nextState: nextState, editor: editor)
    editor.invalidateDFSOrderCache()

    // Reconcile decorator operations
    reconcileDecoratorOpsForSubtree(
      ancestorKey: kRootNodeKey,
      prevState: currentState,
      nextState: nextState,
      editor: editor
    )
    syncDecoratorPositionCacheWithRangeCache(editor: editor)

    // Reconcile selection
    if shouldReconcileSelection {
      try reconcileSelection(
        prevSelection: nil,
        nextSelection: nextState.selection,
        editor: editor
      )
    }
  }

  /// Build attributed content for a subtree and append to output.
  private static func appendAttributedSubtree(
    into output: NSMutableAttributedString,
    nodeKey: NodeKey,
    state: EditorState,
    theme: Theme
  ) {
    guard let node = state.nodeMap[nodeKey] else { return }

    let attributes = AttributeUtils.attributedStringStyles(from: node, state: state, theme: theme)

    func appendStyledString(_ string: String) {
      guard !string.isEmpty else { return }
      let styledString = NSAttributedString(string: string, attributes: attributes)
      output.append(styledString)
    }

    appendStyledString(node.getPreamble())

    if let element = node as? ElementNode {
      for childKey in element.getChildrenKeys(fromLatest: false) {
        appendAttributedSubtree(into: output, nodeKey: childKey, state: state, theme: theme)
      }
    }

    appendStyledString(node.getTextPart(fromLatest: false))
    appendStyledString(node.getPostamble())
  }

  /// Recompute range cache for a subtree. Returns total length written.
  @discardableResult
  private static func recomputeRangeCacheSubtree(
    nodeKey: NodeKey,
    state: EditorState,
    startLocation: Int,
    editor: Editor
  ) -> Int {
    guard let node = state.nodeMap[nodeKey] else { return 0 }

    var item = editor.rangeCache[nodeKey] ?? RangeCacheItem()
    if item.nodeIndex == 0 {
      item.nodeIndex = editor.nextFenwickNodeIndex
      editor.nextFenwickNodeIndex += 1
    }
    item.location = startLocation

    let preLen = node.getPreamble().utf16.count
    item.preambleLength = preLen

    var cursor = startLocation + preLen
    var childrenLen = 0

    if let element = node as? ElementNode {
      for childKey in element.getChildrenKeys(fromLatest: false) {
        let childLen = recomputeRangeCacheSubtree(
          nodeKey: childKey, state: state, startLocation: cursor, editor: editor)
        cursor += childLen
        childrenLen += childLen
      }
    }

    item.childrenLength = childrenLen
    let textLen = node.getTextPart(fromLatest: false).utf16.count
    item.textLength = textLen
    cursor += textLen

    let postLen = node.getPostamble().utf16.count
    item.postambleLength = postLen

    editor.rangeCache[nodeKey] = item
    return preLen + childrenLen + textLen + postLen
  }

  /// Remove stale entries from range cache.
  private static func pruneRangeCacheGlobally(nextState: EditorState, editor: Editor) {
    let validKeys = Set(nextState.nodeMap.keys)
    for key in editor.rangeCache.keys {
      if !validKeys.contains(key) {
        editor.rangeCache.removeValue(forKey: key)
      }
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

    // When inserting an element node, the previous sibling's postamble may change
    // (e.g., paragraph gains a trailing newline when it gets a next sibling)
    if let prevSibling = node.getPreviousSibling() {
      try updateSiblingPostamble(prevSibling, in: textStorage, state: state, editor: editor, theme: theme)
    }

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

  /// Update a sibling's postamble after a new sibling is inserted.
  private static func updateSiblingPostamble(
    _ sibling: Node,
    in textStorage: NSTextStorage,
    state: EditorState,
    editor: Editor,
    theme: Theme
  ) throws {
    guard let cacheItem = editor.rangeCache[sibling.key] else { return }

    // Get the current postamble from the node (which now reflects the new sibling)
    let newPostamble = sibling.getPostamble()
    let oldPostambleLength = cacheItem.postambleLength
    let newPostambleLength = newPostamble.utf16.count

    // If postamble length changed, we need to update textStorage
    if newPostambleLength != oldPostambleLength {
      let postambleStart = cacheItem.location + cacheItem.preambleLength + cacheItem.childrenLength + cacheItem.textLength
      let oldPostambleRange = NSRange(location: postambleStart, length: oldPostambleLength)

      // Build attributed postamble with proper styling
      let attributes = AttributeUtils.attributedStringStyles(from: sibling, state: state, theme: theme)
      let styledPostamble = NSAttributedString(string: newPostamble, attributes: attributes)

      if oldPostambleRange.location + oldPostambleRange.length <= textStorage.length {
        textStorage.replaceCharacters(in: oldPostambleRange, with: styledPostamble)
      } else if oldPostambleRange.location <= textStorage.length {
        // Append at end
        textStorage.insert(styledPostamble, at: oldPostambleRange.location)
      }

      // Update range cache for the sibling
      var updatedItem = cacheItem
      updatedItem.postambleLength = newPostambleLength
      editor.rangeCache[sibling.key] = updatedItem

      // Shift all nodes after this sibling if length changed
      let delta = newPostambleLength - oldPostambleLength
      if delta != 0 {
        let afterLocation = postambleStart + newPostambleLength
        shiftRangeCacheAfter(location: afterLocation, delta: delta, excludingKeys: [sibling.key], editor: editor)
      }
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
    let deletedLength = range.length
    let deletedLocation = range.location

    if deletedLength > 0 && deletedLocation + deletedLength <= textStorage.length {
      textStorage.deleteCharacters(in: range)
    }

    // Remove from range cache
    editor.rangeCache.removeValue(forKey: node.key)

    // Shift all nodes after the deleted range
    if deletedLength > 0 {
      shiftRangeCacheAfter(location: deletedLocation, delta: -deletedLength, excludingKeys: [node.key], editor: editor)
    }
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

    // Set mode to controllerMode so TextStorage accepts our attributed string
    #if canImport(UIKit)
    let previousMode = (textStorage as? ReconcilerTextStorage)?.mode ?? .none
    (textStorage as? ReconcilerTextStorage)?.mode = .controllerMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    let previousMode: TextStorageEditingMode = (textStorage as? ReconcilerTextStorageAppKit)?.mode ?? .none
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = .controllerMode
    #endif

    // Replace characters in storage at requested range
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: operation.selectionRangeToReplace, with: markedAttr)
    textStorage.fixAttributes(
      in: NSRange(location: operation.selectionRangeToReplace.location, length: markedAttr.length)
    )
    textStorage.endEditing()

    // Restore previous mode
    #if canImport(UIKit)
    (textStorage as? ReconcilerTextStorage)?.mode = previousMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = previousMode
    #endif

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

  // MARK: - Decorator Reconciliation

  /// Get the ReconcilerTextStorage from the editor (platform-specific).
  private static func reconcilerTextStorage(_ editor: Editor) -> ReconcilerTextStorage? {
    #if canImport(UIKit)
    return editor.textStorage
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    return editor.textStorage as? ReconcilerTextStorage
    #else
    return nil
    #endif
  }

  /// Get all node keys in DFS order from a subtree.
  private static func subtreeKeysDFS(rootKey: NodeKey, state: EditorState) -> [NodeKey] {
    var result: [NodeKey] = []
    var stack: [NodeKey] = [rootKey]
    while !stack.isEmpty {
      let key = stack.removeLast()
      result.append(key)
      if let element = state.nodeMap[key] as? ElementNode {
        // Push children in reverse order so they're popped in correct order
        for childKey in element.getChildrenKeys(fromLatest: false).reversed() {
          stack.append(childKey)
        }
      }
    }
    return result
  }

  /// Get attachment locations from text storage by scanning for attachment attributes.
  private static func attachmentLocationsByKey(textStorage: ReconcilerTextStorage) -> [NodeKey: Int] {
    let storageLen = textStorage.length
    guard storageLen > 0 else { return [:] }
    var locations: [NodeKey: Int] = [:]
    #if canImport(UIKit)
    textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storageLen)) { value, range, _ in
      if let att = value as? TextAttachment, let key = att.key {
        locations[key] = range.location
      }
    }
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storageLen)) { value, range, _ in
      if let att = value as? TextAttachmentAppKit, let key = att.key {
        locations[key] = range.location
      }
    }
    #endif
    return locations
  }

  /// Reconcile decorator operations for a subtree.
  /// This handles adding/removing decorator views and updating position caches.
  internal static func reconcileDecoratorOpsForSubtree(
    ancestorKey: NodeKey,
    prevState: EditorState,
    nextState: EditorState,
    editor: Editor
  ) {
    guard let textStorage = reconcilerTextStorage(editor) else { return }

    func isAttached(key: NodeKey, in state: EditorState) -> Bool {
      var cursor: NodeKey? = key
      while let k = cursor {
        if k == kRootNodeKey { return true }
        guard let node = state.nodeMap[k] else { return false }
        cursor = node.parent
      }
      return false
    }

    var attachmentLocations: [NodeKey: Int]? = nil
    func attachmentLocation(for key: NodeKey) -> Int? {
      if let loc = editor.rangeCache[key]?.location { return loc }
      if attachmentLocations == nil {
        attachmentLocations = attachmentLocationsByKey(textStorage: textStorage)
      }
      return attachmentLocations?[key]
    }

    func decoratorKeys(in state: EditorState, under root: NodeKey) -> Set<NodeKey> {
      let keys = subtreeKeysDFS(rootKey: root, state: state)
      var out: Set<NodeKey> = []
      for k in keys {
        guard isAttached(key: k, in: state) else { continue }
        if state.nodeMap[k] is DecoratorNode { out.insert(k) }
      }
      return out
    }

    let prevDecos = decoratorKeys(in: prevState, under: ancestorKey)
    let nextDecos = decoratorKeys(in: nextState, under: ancestorKey)

    // Removals: purge position + cache and destroy views
    let removed = prevDecos.subtracting(nextDecos)
    for k in removed {
      let decoratorNode = nextState.nodeMap[k] as? DecoratorNode
      let existsInNextState = decoratorNode != nil
      let isAttachedInNextState = existsInNextState && isAttached(key: k, in: nextState)
      if existsInNextState && isAttachedInNextState && ancestorKey != kRootNodeKey {
        continue
      }
      decoratorView(forKey: k, createIfNecessary: false)?.removeFromSuperview()
      destroyCachedDecoratorView(forKey: k)
      textStorage.decoratorPositionCache[k] = nil
      textStorage.decoratorPositionCacheDirtyKeys.insert(k)
    }

    // Additions: ensure cache entry exists and set position
    let added = nextDecos.subtracting(prevDecos)
    for k in added {
      if editor.decoratorCache[k] == nil { editor.decoratorCache[k] = .needsCreation }
      if let loc = attachmentLocation(for: k) {
        textStorage.decoratorPositionCache[k] = loc
        textStorage.decoratorPositionCacheDirtyKeys.insert(k)
        let safe = NSIntersectionRange(NSRange(location: loc, length: 1), NSRange(location: 0, length: textStorage.length))
        if safe.length > 0 { textStorage.fixAttributes(in: safe) }
      }
    }

    // Persist positions for all present decorators and mark dirty ones for decorating
    for k in nextDecos {
      if let loc = attachmentLocation(for: k) {
        let oldLoc = textStorage.decoratorPositionCache[k]
        if oldLoc != loc {
          textStorage.decoratorPositionCache[k] = loc
          textStorage.decoratorPositionCacheDirtyKeys.insert(k)
        }
        let safe = NSIntersectionRange(NSRange(location: loc, length: 1), NSRange(location: 0, length: textStorage.length))
        if safe.length > 0 { textStorage.fixAttributes(in: safe) }
      }
      if editor.dirtyNodes[k] != nil {
        if let cacheItem = editor.decoratorCache[k], let view = cacheItem.view {
          editor.decoratorCache[k] = .needsDecorating(view)
        }
      }
    }
  }

  /// Sync decorator position cache with range cache after updates.
  private static func syncDecoratorPositionCacheWithRangeCache(editor: Editor) {
    guard let ts = reconcilerTextStorage(editor), !ts.decoratorPositionCache.isEmpty else { return }
    var attachmentLocations: [NodeKey: Int]? = nil

    for (key, oldLoc) in ts.decoratorPositionCache {
      let candidateLoc = editor.rangeCache[key]?.location ?? oldLoc
      let storageLen = ts.length
      var resolvedLoc: Int = candidateLoc

      #if canImport(UIKit)
      if storageLen > 0, candidateLoc >= 0, candidateLoc < storageLen,
         let att = ts.attribute(.attachment, at: candidateLoc, effectiveRange: nil) as? TextAttachment,
         att.key == key {
        resolvedLoc = candidateLoc
      } else if storageLen > 0 {
        if attachmentLocations == nil {
          attachmentLocations = attachmentLocationsByKey(textStorage: ts)
        }
        if let foundAt = attachmentLocations?[key] { resolvedLoc = foundAt }
      }
      #elseif os(macOS) && !targetEnvironment(macCatalyst)
      if storageLen > 0, candidateLoc >= 0, candidateLoc < storageLen,
         let att = ts.attribute(.attachment, at: candidateLoc, effectiveRange: nil) as? TextAttachmentAppKit,
         att.key == key {
        resolvedLoc = candidateLoc
      } else if storageLen > 0 {
        if attachmentLocations == nil {
          attachmentLocations = attachmentLocationsByKey(textStorage: ts)
        }
        if let foundAt = attachmentLocations?[key] { resolvedLoc = foundAt }
      }
      #endif

      if oldLoc != resolvedLoc {
        ts.decoratorPositionCache[key] = resolvedLoc
        ts.decoratorPositionCacheDirtyKeys.insert(key)
      }
    }
  }
}
