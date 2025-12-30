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
#if DEBUG
	  private static var debugLoggingEnabled: Bool {
	    ProcessInfo.processInfo.environment["LEXICAL_ROPE_RECONCILER_DEBUG"] == "1" ||
	    UserDefaults.standard.bool(forKey: "LEXICAL_ROPE_RECONCILER_DEBUG")
	  }
#endif

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

  private static var reconcileCounter = 0

  /// Internal implementation of reconciliation.
  private static func reconcileInternal(
    from prevState: EditorState?,
    to nextState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    markedTextOperation: MarkedTextOperation?
  ) throws {
    guard let textStorage = editor.textStorage else { return }
    reconcileCounter += 1
    let reconcileId = reconcileCounter
    print("🔍🔍🔍 RECONCILE #\(reconcileId) START storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"  🔍🔍🔍")

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
    // NOTE: handleComposition uses Fenwick-aware pointAtStringLocation, so no pre-materialization needed.
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
        // `getWritable()` on an ElementNode marks all descendants as dirty, even when their
        // actual content hasn't changed (e.g. mutating RootNode children marks the entire
        // document dirty). Avoid updating nodes that were not cloned/mutated in this update.
        if prev !== next {
          updates.append((key, prev, next))
        }
      case (nil, nil):
        continue
      }
    }

    // Some structural transforms can detach an ElementNode while reparenting its descendants
    // (e.g. paragraph merges). In these cases, removing the entire subtree range would delete
    // text that still exists elsewhere in `nextState`. Treat these nodes as "wrapper-only" removes:
    // delete only their pre/postamble bytes and rely on descendant updates for content.
    var wrapperOnlyRemoveKeys = Set<NodeKey>()
    if let prevState {
      @inline(__always)
      func isAttached(key: NodeKey, in state: EditorState) -> Bool {
        var cursor: NodeKey? = key
        while let k = cursor {
          if k == kRootNodeKey { return true }
          guard let node = state.nodeMap[k] else { return false }
          cursor = node.parent
        }
        return false
      }

      @inline(__always)
      func hasAttachedDescendant(under key: NodeKey) -> Bool {
        guard let root = prevState.nodeMap[key] as? ElementNode else { return false }
        var stack = root.getChildrenKeys(fromLatest: false)
        while let k = stack.popLast() {
          if isAttached(key: k, in: nextState) { return true }
          if let element = prevState.nodeMap[k] as? ElementNode {
            stack.append(contentsOf: element.getChildrenKeys(fromLatest: false))
          }
        }
        return false
      }

      for (key, node) in removes {
        guard node is ElementNode else { continue }
        if hasAttachedDescendant(under: key) {
          wrapperOnlyRemoveKeys.insert(key)
        }
      }
    }

    // Filter inserts: skip nodes whose parent is also being inserted
    // (parent's buildAttributedContent already includes children)
    inserts = inserts.filter { (_, node) in
      guard let parentKey = node.parent else { return true }
      return !insertedKeys.contains(parentKey)
    }

    // Filter removes: skip nodes whose parent is also being removed.
    // Removing the parent deletes the entire subtree's content, so deleting descendants would double-delete ranges.
    let removedKeys = Set(removes.map { $0.key })
    print("🔍 DEBUG removes BEFORE filter: \(removes.map { "(\($0.key), \(type(of: $0.node)))" })")
    print("🔍 DEBUG wrapperOnlyRemoveKeys: \(wrapperOnlyRemoveKeys)")
    print("🔍 DEBUG updates: \(updates.map { "(\($0.key), \(type(of: $0.next)))" })")
    removes = removes.filter { (_, node) in
      guard let parentKey = node.parent else { return true }
      // If the parent is being removed as wrapper-only, descendants may still represent real
      // content deletions; don't skip them.
      guard removedKeys.contains(parentKey) else { return true }
      return wrapperOnlyRemoveKeys.contains(parentKey)
    }
    print("🔍 DEBUG removes AFTER filter: \(removes.map { "(\($0.key), \(type(of: $0.node)))" })")

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

    let useLazyLocations =
      editor.useFenwickLocations
      && inserts.isEmpty
      && removes.isEmpty
      && updates.allSatisfy({ $0.prev is TextNode && $0.next is TextNode })

    if editor.useFenwickLocations {
      if editor.fenwickHasDeltas && !useLazyLocations {
        materializeFenwickLocations(editor: editor)
      }
      if useLazyLocations {
        _ = editor.cachedDFSOrderAndIndex()
        editor.ensureFenwickCapacity(editor.rangeCache.count)
      }
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

#if DEBUG
    let t_apply0 = CFAbsoluteTimeGetCurrent()
    var t_afterRemoves = t_apply0
    var t_afterInserts = t_apply0
    var t_afterUpdates = t_apply0
    var t_afterBlockAttrs = t_apply0
    var t_afterEndEditing = t_apply0
    var t_afterSelection = t_apply0
#endif

    // Process removes first (in reverse document order to avoid shifting issues)
    // Use batched approach for O(n) instead of O(n²) cache updates
    removes.sort { a, b in
      let aLoc = editor.rangeCache[a.key]?.location ?? 0
      let bLoc = editor.rangeCache[b.key]?.location ?? 0
      return aLoc > bLoc  // Reverse order
    }
    if let prevState {
      try batchRemoveNodes(
        removes,
        from: textStorage,
        editor: editor,
        prevState: prevState,
        nextState: nextState,
        wrapperOnlyRemoveKeys: wrapperOnlyRemoveKeys
      )
    } else {
      try batchRemoveNodes(
        removes,
        from: textStorage,
        editor: editor,
        prevState: nextState,
        nextState: nextState,
        wrapperOnlyRemoveKeys: []
      )
    }

    // Removals can change boundary-derived preambles/postambles of adjacent element nodes
    // (e.g. the last paragraph losing its trailing newline). These nodes are often not cloned
    // in `nextState`, so they won't appear in `updates` and would otherwise be skipped.
    if let prevState, !removes.isEmpty {
      var boundaryCandidateKeys = Set<NodeKey>()
      boundaryCandidateKeys.reserveCapacity(removes.count * 2)

      @inline(__always)
      func siblingKeysInState(for node: Node, state: EditorState) -> (prev: NodeKey?, next: NodeKey?) {
        guard let parentKey = node.parent,
              let parent = state.nodeMap[parentKey] as? ElementNode
        else { return (nil, nil) }
        let children = parent.getChildrenKeys(fromLatest: false)
        guard let idx = children.firstIndex(of: node.key) else { return (nil, nil) }
        let prevKey = idx > 0 ? children[idx - 1] : nil
        let nextKey = idx + 1 < children.count ? children[idx + 1] : nil
        return (prevKey, nextKey)
      }

      for (_, node) in removes {
        let sibs = siblingKeysInState(for: node, state: prevState)
        if let prevKey = sibs.prev { boundaryCandidateKeys.insert(prevKey) }
        if let nextKey = sibs.next { boundaryCandidateKeys.insert(nextKey) }
      }

      // Update candidates in document order to apply shifts consistently.
      // Skip nodes that are already in the updates list - they'll be updated there.
      let updateKeys = Set(updates.map { $0.key })
      let candidateKeys: [NodeKey] = boundaryCandidateKeys
        .filter { key in
          !updateKeys.contains(key)
            && (prevState.nodeMap[key] as? ElementNode) != nil
            && (nextState.nodeMap[key] as? ElementNode) != nil
            && editor.rangeCache[key] != nil
        }
        .sorted { a, b in
          let aLoc = editor.rangeCache[a]?.location ?? 0
          let bLoc = editor.rangeCache[b]?.location ?? 0
          if aLoc != bLoc { return aLoc < bLoc }
          return a < b
        }

      print("🔍 DEBUG boundary candidates: \(candidateKeys) storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"")
      for key in candidateKeys {
        guard let prevElement = prevState.nodeMap[key] as? ElementNode,
              let nextElement = nextState.nodeMap[key] as? ElementNode
        else { continue }
        print("🔍 DEBUG calling updateElementNode for key=\(key)")
        try updateElementNode(from: prevElement, to: nextElement, in: textStorage, state: nextState, editor: editor, theme: theme)
        print("🔍 DEBUG after updateElementNode for key=\(key) storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"")
      }
    }
#if DEBUG
    t_afterRemoves = CFAbsoluteTimeGetCurrent()
#endif

    // Process inserts in document order
#if DEBUG
    let t_insertSort0 = CFAbsoluteTimeGetCurrent()
#endif
    do {
      // Sorting inserts by repeatedly computing document positions inside the comparator is extremely
      // expensive for large pastes (O(N² log N) due to repeated linear sibling scans).
      // Precompute positions once per node using a cached child-index map per parent.
      var childIndexCache: [NodeKey: [NodeKey: Int]] = [:]
      childIndexCache.reserveCapacity(8)

      @inline(__always)
      func indexMap(forParentKey parentKey: NodeKey, parent: ElementNode) -> [NodeKey: Int] {
        if let cached = childIndexCache[parentKey] { return cached }
        let children = parent.getChildrenKeys(fromLatest: false)
        var map: [NodeKey: Int] = [:]
        map.reserveCapacity(children.count)
        for (i, key) in children.enumerated() {
          map[key] = i
        }
        childIndexCache[parentKey] = map
        return map
      }

      @inline(__always)
      func documentPositionFast(of node: Node) -> [Int] {
        var path: [Int] = []
        path.reserveCapacity(4)
        var current: Node? = node
        while let cur = current, let parentKey = cur.parent,
              let parent = nextState.nodeMap[parentKey] as? ElementNode
        {
          let map = indexMap(forParentKey: parentKey, parent: parent)
          if let index = map[cur.key] {
            path.insert(index, at: 0)
          }
          current = parent
        }
        return path
      }

      var positioned: [(pos: [Int], key: NodeKey, node: Node)] = []
      positioned.reserveCapacity(inserts.count)
      for (key, node) in inserts {
        positioned.append((documentPositionFast(of: node), key, node))
      }

      positioned.sort { comparePaths($0.pos, $1.pos) }
      inserts = positioned.map { (key: $0.key, node: $0.node) }
    }
#if DEBUG
    let insertSortMs = (CFAbsoluteTimeGetCurrent() - t_insertSort0) * 1000
    if debugLoggingEnabled && insertSortMs > 50 {
      let insertSortStr = String(format: "%.2f", insertSortMs)
      print(
        "🔥 ROPE_RECONCILER insert sort: count=\(inserts.count) time=\(insertSortStr)ms"
      )
    }
#endif
    print("🔍 DEBUG before inserts: storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\" inserts.count=\(inserts.count)")
    var insertIndex = 0
    while insertIndex < inserts.count {
      let consumed = try bulkInsertElementSiblingRunIfPossible(
        inserts,
        startingAt: insertIndex,
        into: textStorage,
        state: nextState,
        editor: editor,
        theme: theme
      )
      if consumed > 0 {
        insertIndex += consumed
        continue
      }

      let node = inserts[insertIndex].node
      try insertNode(node, into: textStorage, state: nextState, editor: editor, theme: theme)
      insertIndex += 1
    }
#if DEBUG
    t_afterInserts = CFAbsoluteTimeGetCurrent()
#endif

    updates.sort { a, b in
      let aLoc = editor.rangeCache[a.key]?.location ?? 0
      let bLoc = editor.rangeCache[b.key]?.location ?? 0
      if aLoc != bLoc { return aLoc < bLoc }
      // Within the same location, process TextNodes before ElementNodes.
      // TextNode updates change content lengths that ElementNode updates depend on.
      let aIsText = a.next is TextNode
      let bIsText = b.next is TextNode
      if aIsText != bIsText { return aIsText }
      return a.key < b.key
    }
    print("🔍 DEBUG before updates: storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\" updates.count=\(updates.count) keys=\(updates.map { $0.key })")

    for (key, prev, next) in updates {
      print("🔍 DEBUG calling updateNode for key=\(key) type=\(type(of: next)) storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"")
      defer { print("🔍 DEBUG after updateNode for key=\(key) storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"") }
      try updateNode(
        from: prev,
        to: next,
        in: textStorage,
        state: nextState,
        editor: editor,
        theme: theme,
        useLazyLocations: useLazyLocations
      )
    }
#if DEBUG
    t_afterUpdates = CFAbsoluteTimeGetCurrent()
#endif

    #if canImport(UIKit)
    if hasEdits, !useLazyLocations {
      // `getWritable()` on ElementNodes (notably RootNode) marks entire subtrees dirty.
      // Avoid treating all those descendants as block-attribute candidates; apply only for
      // nodes that were actually inserted/updated in this reconciliation pass.
      var blockAttributeDirty: DirtyNodeMap = [:]
      blockAttributeDirty.reserveCapacity(inserts.count + updates.count + removes.count)
      for (key, _) in inserts {
        blockAttributeDirty[key] = .editorInitiated
      }
      for (key, _, _) in updates {
        blockAttributeDirty[key] = .editorInitiated
      }
      for (_, node) in removes {
        if let parentKey = node.parent {
          blockAttributeDirty[parentKey] = .editorInitiated
        }
      }

      applyBlockLevelAttributesIfNeeded(
        editor: editor,
        state: nextState,
        dirtyNodes: blockAttributeDirty,
        treatAllNodesAsDirty: false,
        theme: theme,
        textStorage: textStorage
      )
    } else if hasEdits, useLazyLocations {
      // Even in text-only updates, we must ensure extraLineFragmentAttributes is set
      // correctly so that empty trailing paragraphs render properly.
      updateExtraLineFragmentAttributesIfNeeded(
        editor: editor,
        state: nextState,
        theme: theme,
        textStorage: textStorage
      )
    }
    #endif
#if DEBUG
    t_afterBlockAttrs = CFAbsoluteTimeGetCurrent()
#endif

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
#if DEBUG
    t_afterEndEditing = CFAbsoluteTimeGetCurrent()
#endif
    applyDuration = CFAbsoluteTimeGetCurrent() - applyStart

    if !removedKeys.isEmpty {
      pruneRangeCacheGlobally(nextState: nextState, editor: editor, textStorageLength: textStorage.length)
    } else if hasEdits {
      // Even without explicit removes, bulk operations like removeText() can leave
      // range cache entries with stale lengths. Validate and repair if needed.
      validateAndRepairRangeCache(nextState: nextState, editor: editor, textStorageLength: textStorage.length)
    }
    if !removedKeys.isEmpty || !inserts.isEmpty {
      editor.invalidateDFSOrderCache()
    }

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
#if DEBUG
    t_afterSelection = CFAbsoluteTimeGetCurrent()

    let removesMs = (t_afterRemoves - t_apply0) * 1000
    let insertsMs = (t_afterInserts - t_afterRemoves) * 1000
    let updatesMs = (t_afterUpdates - t_afterInserts) * 1000
    let blockAttrsMs = (t_afterBlockAttrs - t_afterUpdates) * 1000
    let endEditingMs = (t_afterEndEditing - t_afterBlockAttrs) * 1000
    let selectionMs = (t_afterSelection - t_afterEndEditing) * 1000
    let totalMs = (t_afterSelection - t_apply0) * 1000

    if debugLoggingEnabled && totalMs > 50 {
      let removesStr = String(format: "%.2f", removesMs)
      let insertsStr = String(format: "%.2f", insertsMs)
      let updatesStr = String(format: "%.2f", updatesMs)
      let blockAttrsStr = String(format: "%.2f", blockAttrsMs)
      let endEditingStr = String(format: "%.2f", endEditingMs)
      let selectionStr = String(format: "%.2f", selectionMs)
      let totalStr = String(format: "%.2f", totalMs)
      print(
        "🔥 ROPE_RECONCILER counts: dirty=\(dirtyNodesCount) removes=\(removes.count) inserts=\(inserts.count) updates=\(updates.count) rangeCache=\(editor.rangeCache.count) storageLen=\(textStorage.length)"
      )
      print(
        "🔥 ROPE_RECONCILER phases: removes=\(removesStr)ms inserts=\(insertsStr)ms updates=\(updatesStr)ms blockAttrs=\(blockAttrsStr)ms endEditing=\(endEditingStr)ms selection=\(selectionStr)ms total=\(totalStr)ms"
      )
    }
#endif
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

    let preamble: String
    let postamble: String
    if let element = node as? ElementNode {
      preamble = computeElementPreamble(for: element, state: state)
      postamble = computeElementPostamble(for: element, state: state)
    } else {
      preamble = node.getPreamble()
      postamble = node.getPostamble()
    }

    var length = preamble.utf16.count + node.getTextPart(fromLatest: false).utf16.count + postamble.utf16.count

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

    // Recompute range cache from root
    _ = recomputeRangeCacheSubtree(nodeKey: kRootNodeKey, state: pendingState, startLocation: 0, editor: editor)
    editor.invalidateDFSOrderCache()
    editor.resetFenwickTree(capacity: editor.rangeCache.count)

    #if canImport(UIKit)
    applyBlockLevelAttributesIfNeeded(
      editor: editor,
      state: pendingState,
      dirtyNodes: [:],
      treatAllNodesAsDirty: true,
      theme: theme,
      textStorage: textStorage
    )
    #endif

    textStorage.endEditing()

    // Restore previous mode
    #if canImport(UIKit)
    (textStorage as? ReconcilerTextStorage)?.mode = previousMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = previousMode
    #endif

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

    // Recompute entire range cache
    _ = recomputeRangeCacheSubtree(nodeKey: kRootNodeKey, state: nextState, startLocation: 0, editor: editor)
    pruneRangeCacheGlobally(nextState: nextState, editor: editor)
    editor.invalidateDFSOrderCache()
    editor.resetFenwickTree(capacity: editor.rangeCache.count)

    #if canImport(UIKit)
    applyBlockLevelAttributesIfNeeded(
      editor: editor,
      state: nextState,
      dirtyNodes: [:],
      treatAllNodesAsDirty: true,
      theme: theme,
      textStorage: textStorage
    )
    #endif

    textStorage.endEditing()

    // Restore previous mode
    #if canImport(UIKit)
    (textStorage as? ReconcilerTextStorage)?.mode = previousMode
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    (textStorage as? ReconcilerTextStorageAppKit)?.mode = previousMode
    #endif

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

    // Use the node's overridable preamble/postamble so plugin nodes can supply control characters
    // (e.g. ListItemNode uses a ZWSP preamble marker for list drawing).
    let preamble: String
    let postamble: String
    if let element = node as? ElementNode {
      preamble = computeElementPreamble(for: element, state: state)
      postamble = computeElementPostamble(for: element, state: state)
    } else {
      preamble = node.getPreamble()
      postamble = node.getPostamble()
    }

    appendStyledString(preamble)

    if let element = node as? ElementNode {
      for childKey in element.getChildrenKeys(fromLatest: false) {
        appendAttributedSubtree(into: output, nodeKey: childKey, state: state, theme: theme)
      }
    }

    appendStyledString(node.getTextPart(fromLatest: false))
    appendStyledString(postamble)
  }

  #if canImport(UIKit)
  private static func applyBlockLevelAttributesIfNeeded(
    editor: Editor,
    state: EditorState,
    dirtyNodes: DirtyNodeMap,
    treatAllNodesAsDirty: Bool,
    theme: Theme,
    textStorage: NSTextStorage
  ) {
    guard let textStorage = textStorage as? ReconcilerTextStorage else { return }

    let lastDescendentAttributes =
      getRoot()?.getLastChild()?.getAttributedStringAttributes(theme: theme) ?? [:]

    var nodesToApply = Set<NodeKey>()
    if treatAllNodesAsDirty {
      nodesToApply = Set(state.nodeMap.keys)
    } else {
      for nodeKey in dirtyNodes.keys {
        guard let node = getNodeByKey(key: nodeKey) else { continue }
        nodesToApply.insert(nodeKey)
        for parentKey in node.getParentKeys() {
          nodesToApply.insert(parentKey)
        }
      }
    }

    let sortedKeys = nodesToApply.sorted { a, b in
      let aLoc = editor.rangeCache[a]?.location ?? 0
      let bLoc = editor.rangeCache[b]?.location ?? 0
      if aLoc != bLoc { return aLoc < bLoc }
      return a < b
    }

    for nodeKey in sortedKeys {
      guard let node = getNodeByKey(key: nodeKey),
            node.isAttached(),
            let cacheItem = editor.rangeCache[nodeKey],
            let attributes = node.getBlockLevelAttributes(theme: theme)
      else { continue }

      AttributeUtils.applyBlockLevelAttributes(
        attributes,
        cacheItem: cacheItem,
        textStorage: textStorage,
        nodeKey: nodeKey,
        lastDescendentAttributes: lastDescendentAttributes
      )
    }
  }

  /// Lightweight update of extraLineFragmentAttributes for text-only updates.
  /// This ensures empty trailing paragraphs render correctly even when we skip
  /// the full block-level attribute pass for performance.
  private static func updateExtraLineFragmentAttributesIfNeeded(
    editor: Editor,
    state: EditorState,
    theme: Theme,
    textStorage: NSTextStorage
  ) {
    guard let ts = textStorage as? ReconcilerTextStorage else { return }

    // Check if text ends with newline (meaning extra line fragment should be present)
    let textAsNSString: NSString = ts.string as NSString
    let endsWithNewline: Bool
    if textAsNSString.length == 0 {
      endsWithNewline = true  // Empty document shows extra line fragment
    } else if let scalar = Unicode.Scalar(textAsNSString.character(at: textAsNSString.length - 1)) {
      endsWithNewline = NSCharacterSet.newlines.contains(scalar)
    } else {
      endsWithNewline = false
    }

    if endsWithNewline {
      // Get the last child's attributes to use for the extra line fragment
      let lastDescendentAttributes =
        getRoot()?.getLastChild()?.getAttributedStringAttributes(theme: theme) ?? [:]
      ts.extraLineFragmentAttributes = lastDescendentAttributes
    } else {
      ts.extraLineFragmentAttributes = nil
    }
  }
  #endif

  /// Recompute range cache for a subtree. Returns total length written.
  @discardableResult
  private static func recomputeRangeCacheSubtree(
    nodeKey: NodeKey,
    state: EditorState,
    startLocation: Int,
    editor: Editor,
    visitedKeys: inout Set<NodeKey>?
  ) -> Int {
    guard let node = state.nodeMap[nodeKey] else { return 0 }

    visitedKeys?.insert(nodeKey)

    var item = editor.rangeCache[nodeKey] ?? RangeCacheItem()
    if item.nodeIndex == 0 {
      item.nodeIndex = editor.nextFenwickNodeIndex
      editor.nextFenwickNodeIndex += 1
    }
    item.location = startLocation

    // Use the node's overridable preamble/postamble so plugin nodes can supply control characters.
    let preamble: String
    let postamble: String
    if let element = node as? ElementNode {
      preamble = computeElementPreamble(for: element, state: state)
      postamble = computeElementPostamble(for: element, state: state)
    } else {
      preamble = node.getPreamble()
      postamble = node.getPostamble()
    }

    let preLen = preamble.utf16.count
    item.preambleLength = preLen

    var cursor = startLocation + preLen
    var childrenLen = 0

    if let element = node as? ElementNode {
      for childKey in element.getChildrenKeys(fromLatest: false) {
        let childLen = recomputeRangeCacheSubtree(
          nodeKey: childKey, state: state, startLocation: cursor, editor: editor, visitedKeys: &visitedKeys)
        cursor += childLen
        childrenLen += childLen
      }
    }

    item.childrenLength = childrenLen
    let textLen = node.getTextPart(fromLatest: false).utf16.count
    item.textLength = textLen
    cursor += textLen

    let postLen = postamble.utf16.count
    item.postambleLength = postLen

    editor.rangeCache[nodeKey] = item
    return preLen + childrenLen + textLen + postLen
  }

  /// Convenience overload for backward compatibility.
  @discardableResult
  private static func recomputeRangeCacheSubtree(
    nodeKey: NodeKey,
    state: EditorState,
    startLocation: Int,
    editor: Editor
  ) -> Int {
    var visitedKeys: Set<NodeKey>? = nil
    return recomputeRangeCacheSubtree(
      nodeKey: nodeKey, state: state, startLocation: startLocation, editor: editor, visitedKeys: &visitedKeys)
  }

  /// Validate range cache entries are within text storage bounds and repair if needed.
  private static func validateAndRepairRangeCache(nextState: EditorState, editor: Editor, textStorageLength: Int) {
    guard textStorageLength >= 0 else { return }

    var needsRecompute = false
    for (_, item) in editor.rangeCache {
      let entryEnd = item.location + item.entireLength
      if entryEnd > textStorageLength {
        needsRecompute = true
        break
      }
    }

    if needsRecompute {
      // Track which nodes are actually attached (reachable from root)
      var visitedKeys: Set<NodeKey>? = Set()
      _ = recomputeRangeCacheSubtree(
        nodeKey: kRootNodeKey, state: nextState, startLocation: 0, editor: editor, visitedKeys: &visitedKeys)
      // Prune entries for detached nodes (not visited during tree traversal)
      // This handles nodes that are still in nodeMap but have parent=nil (detached)
      if let attached = visitedKeys {
        for key in editor.rangeCache.keys {
          if !attached.contains(key) {
            editor.rangeCache.removeValue(forKey: key)
          }
        }
      }
    }
  }

  /// Remove stale entries from range cache.
  private static func pruneRangeCacheGlobally(nextState: EditorState, editor: Editor, textStorageLength: Int? = nil) {
    // First pass: remove entries for nodes not in nodeMap at all
    let validKeys = Set(nextState.nodeMap.keys)
    for key in editor.rangeCache.keys {
      if !validKeys.contains(key) {
        editor.rangeCache.removeValue(forKey: key)
      }
    }

    // After bulk deletes, range cache entries may have stale lengths that extend
    // beyond the actual text storage. Detect this and trigger a full recompute.
    if let maxLength = textStorageLength, maxLength >= 0 {
      var needsRecompute = false
      for (_, item) in editor.rangeCache {
        let entryEnd = item.location + item.entireLength
        if entryEnd > maxLength {
          needsRecompute = true
          break
        }
      }
      if needsRecompute {
        // Track which nodes are actually attached (reachable from root)
        var visitedKeys: Set<NodeKey>? = Set()
        _ = recomputeRangeCacheSubtree(
          nodeKey: kRootNodeKey, state: nextState, startLocation: 0, editor: editor, visitedKeys: &visitedKeys)
        // Prune entries for detached nodes (not visited during tree traversal)
        // This handles nodes that are still in nodeMap but have parent=nil (detached)
        if let attached = visitedKeys {
          for key in editor.rangeCache.keys {
            if !attached.contains(key) {
              editor.rangeCache.removeValue(forKey: key)
            }
          }
        }
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
    guard let parentKey = node.parent,
          let parent = state.nodeMap[parentKey] as? ElementNode
    else { return }

    // When inserting an element node, the previous sibling's postamble may change
    // (e.g., paragraph gains a trailing newline when it gets a next sibling)
    let parentChildren = parent.getChildrenKeys(fromLatest: false)
    if let idx = parentChildren.firstIndex(of: node.key), idx > 0 {
      let prevKey = parentChildren[idx - 1]
      if let prevSibling = state.nodeMap[prevKey] {
        try updateSiblingPostamble(prevSibling, in: textStorage, state: state, editor: editor, theme: theme)
      }
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
    updateRangeCache(for: node, at: location, length: content.length, state: state, editor: editor)

    // Insertions of element nodes can include the entire subtree's content (preamble + children + postamble).
    // Ensure the range cache is populated for all descendants so selection mapping works.
    if node is ElementNode {
      _ = recomputeRangeCacheSubtree(nodeKey: node.key, state: state, startLocation: location, editor: editor)
    }
  }

  private static func bulkInsertElementSiblingRunIfPossible(
    _ inserts: [(key: NodeKey, node: Node)],
    startingAt startIndex: Int,
    into textStorage: NSTextStorage,
    state: EditorState,
    editor: Editor,
    theme: Theme
  ) throws -> Int {
    guard startIndex < inserts.count else { return 0 }
    guard let first = inserts[startIndex].node as? ElementNode else { return 0 }
    guard let parentKey = first.parent,
          let parent = state.nodeMap[parentKey] as? ElementNode
    else { return 0 }

    var endIndex = startIndex
    while endIndex < inserts.count {
      guard let el = inserts[endIndex].node as? ElementNode else { break }
      guard el.parent == parentKey else { break }
      endIndex += 1
    }

    let runCount = endIndex - startIndex
    // Avoid paying the overhead for small runs; this is primarily for multi-block pastes.
    guard runCount >= 32 else { return 0 }

    // Only handle append-at-end runs to avoid needing global location shifts.
    // Large paste tests append blocks at the end repeatedly.
    if let prevSibling = first.getPreviousSibling() {
      try updateSiblingPostamble(prevSibling, in: textStorage, state: state, editor: editor, theme: theme)
    }

    let insertLocation = computeInsertLocation(for: first, parent: parent, editor: editor)
#if DEBUG
    if debugLoggingEnabled {
      if insertLocation != textStorage.length {
        print(
          "🔥 ROPE_RECONCILER bulkInsert SKIP runCount=\(runCount) insertLocation=\(insertLocation) storageLen=\(textStorage.length) parent=\(parentKey)"
        )
      } else {
        print("🔥 ROPE_RECONCILER bulkInsert runCount=\(runCount) insertLocation=\(insertLocation)")
      }
    }
#endif
    guard insertLocation == textStorage.length else { return 0 }

#if DEBUG
    let t_build_start = CFAbsoluteTimeGetCurrent()
#endif
    let combined = NSMutableAttributedString()
    combined.beginEditing()
    for i in startIndex..<endIndex {
      let nodeKey = inserts[i].node.key
      autoreleasepool {
        appendAttributedSubtree(into: combined, nodeKey: nodeKey, state: state, theme: theme)
      }
    }
    combined.endEditing()
#if DEBUG
    let t_build_end = CFAbsoluteTimeGetCurrent()
#endif

    if combined.length > 0 {
#if DEBUG
      let t_insert_start = CFAbsoluteTimeGetCurrent()
#endif
      textStorage.insert(combined, at: insertLocation)
#if DEBUG
      let t_insert_end = CFAbsoluteTimeGetCurrent()
      let buildMs = (t_build_end - t_build_start) * 1000
      let insertMs = (t_insert_end - t_insert_start) * 1000
      if debugLoggingEnabled {
        let buildStr = String(format: "%.2f", buildMs)
        let insertStr = String(format: "%.2f", insertMs)
        print(
          "🔥 ROPE_RECONCILER bulkInsert timings: build=\(buildStr)ms insert=\(insertStr)ms len=\(combined.length)"
        )
      }
#endif
    }

    // Populate range cache entries for all inserted nodes and their descendants.
    var cursor = insertLocation
    for i in startIndex..<endIndex {
      let nodeKey = inserts[i].node.key
      let len = recomputeRangeCacheSubtree(nodeKey: nodeKey, state: state, startLocation: cursor, editor: editor)
      cursor += len
    }
    propagateChildrenLengthDelta(fromParentKey: parentKey, delta: combined.length, state: state, editor: editor)

    return runCount
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

    // Get the current postamble (which now reflects the new sibling). Avoid relying on
    // global editor state; compute from the provided `state` when possible.
    let newPostamble: String = {
      if let element = state.nodeMap[sibling.key] as? ElementNode {
        return computeElementPostamble(for: element, state: state)
      }
      return sibling.getPostamble()
    }()
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
        propagateChildrenLengthDelta(fromParentKey: sibling.parent, delta: delta, state: state, editor: editor)
        let oldEnd = postambleStart + oldPostambleLength
        let excludingKeys = ancestorKeys(fromParentKey: sibling.parent)
        shiftRangeCacheAfter(location: oldEnd, delta: delta, excludingKeys: excludingKeys, editor: editor)
      }
    }
  }

	  /// Batch remove multiple nodes efficiently. O(n + m) instead of O(n × m).
	  /// Nodes must be pre-sorted in reverse document order (highest location first).
		  private static func batchRemoveNodes(
		    _ removes: [(key: NodeKey, node: Node)],
		    from textStorage: NSTextStorage,
		    editor: Editor,
		    prevState: EditorState,
		    nextState: EditorState,
		    wrapperOnlyRemoveKeys: Set<NodeKey>
		  ) throws {
		    guard !removes.isEmpty else { return }

	    // Defensive: structural edits must operate on absolute locations.
	    // If Fenwick deltas are pending, materialize them into `RangeCacheItem.location` first.
	    if editor.useFenwickLocations, editor.fenwickHasDeltas {
	      materializeFenwickLocations(editor: editor)
	    }

		    // Track deletions: (endLocation, deletedLength, parentKey)
		    // We'll use this to compute cumulative shifts for remaining nodes
		    var deletions: [(endLocation: Int, length: Int, parentKey: NodeKey?)] = []
		    deletions.reserveCapacity(removes.count)

		    // If this reconcile is driven by a selection-based delete (e.g. backspace),
		    // constrain TextStorage deletions to the intended native deletion range.
		    // This prevents structural diff logic from deleting the wrong separator/newline when
		    // RangeCache locations are temporarily inconsistent during churn.
		    let deletionClamp = editor.pendingDeletionClampRange
    var plannedDeletes: [(range: NSRange, parentKey: NodeKey?, clampSensitive: Bool)] = []
    plannedDeletes.reserveCapacity(removes.count)

    @inline(__always)
    func isAttached(key: NodeKey, in state: EditorState) -> Bool {
      var cursor: NodeKey? = key
      while let k = cursor {
        if k == kRootNodeKey { return true }
        guard let node = state.nodeMap[k] else { return false }
        cursor = node.parent
      }
      return false
    }

		    // Phase 1: Collect planned deletions and update range cache.
		    // Since removes are in reverse order, planned deletions don't affect each other's locations
		    for (key, node) in removes {
		      guard let cacheItem = editor.rangeCache[key] else { continue }

		      var deletedLength = 0

		      if wrapperOnlyRemoveKeys.contains(key), node is ElementNode {
	        // Wrapper-only removal: delete only this node's preamble/postamble bytes.
	        // Do not delete children/text regions because they may still be present elsewhere in `nextState`.
	        let baseLoc = editor.actualLocation(for: key) ?? cacheItem.location
	        let preLen = cacheItem.preambleLength
	        let postLen = cacheItem.postambleLength
	        let postStart = baseLoc + cacheItem.preambleLength + cacheItem.childrenLength + cacheItem.textLength

        if postLen > 0 {
          let postRange = NSRange(location: postStart, length: postLen)
          plannedDeletes.append((postRange, node.parent, true))
          deletedLength += postLen
        }

        if preLen > 0 {
          let preRange = NSRange(location: baseLoc, length: preLen)
          plannedDeletes.append((preRange, node.parent, true))
          deletedLength += preLen
        }

#if DEBUG
	        if debugLoggingEnabled, (preLen > 0 || postLen > 0), deletedLength > 0 {
	          let attachmentLeak = isAttached(key: key, in: nextState)
	          print(
	            "🔥 ROPE_RECONCILER wrapper-only remove key=\(key) pre=\(preLen) post=\(postLen) deleted=\(deletedLength) attachedInNext=\(attachmentLeak)"
	          )
	        }
#endif
		      } else {
		        let range = editor.actualRange(for: key) ?? cacheItem.range
		        deletedLength = range.length

#if DEBUG
	        if debugLoggingEnabled {
	          @inline(__always)
	          func snippet(_ s: String, around location: Int, maxLength: Int = 60) -> String {
	            guard !s.isEmpty else { return "" }
	            let utf16 = Array(s.utf16)
	            let start = Swift.max(0, Swift.min(location, utf16.count))
	            let lo = Swift.max(0, start - maxLength / 2)
	            let hi = Swift.min(utf16.count, lo + maxLength)
	            let view = String(utf16CodeUnits: Array(utf16[lo..<hi]), count: hi - lo)
	            return view.replacingOccurrences(of: "\n", with: "\\n")
	          }

	          let typeName = String(describing: type(of: node))
	          let t = textStorage.string
	          print(
	            "🔥 ROPE_RECONCILER remove key=\(key) type=\(typeName) range={\(range.location),\(range.length)} storageLen=\(textStorage.length) ctx=\"\(snippet(t, around: range.location))\""
	          )
	        }
#endif

        if deletedLength > 0 {
          plannedDeletes.append((range, node.parent, !(node is TextNode)))
        }
      }

		      // Remove from range cache
		      editor.rangeCache.removeValue(forKey: key)
		    }

		    // Apply deletes to TextStorage (in reverse order). If a clamp is provided, intersect deletes.
    var deletesToApply: [(range: NSRange, parentKey: NodeKey?)] = []
    deletesToApply.reserveCapacity(plannedDeletes.count)
    print("🔍 DEBUG plannedDeletes: \(plannedDeletes.map { "(range=\($0.range), parentKey=\($0.parentKey ?? "nil"), clampSensitive=\($0.clampSensitive))" })")
    print("🔍 DEBUG deletionClamp: \(String(describing: deletionClamp))")
    if let clamp = deletionClamp {
      var minStart: Int? = nil
      for (range, parentKey, clampSensitive) in plannedDeletes {
        if clampSensitive {
          // Clamp-sensitive deletes (structural nodes like paragraphs) should only
          // delete the portion that intersects with the user's intended deletion range.
          // If no intersection exists, skip this delete entirely.
          let inter = NSIntersectionRange(range, clamp)
          if inter.length > 0 {
            deletesToApply.append((inter, parentKey))
            if minStart == nil || inter.location < minStart! { minStart = inter.location }
          }
          // If no intersection, skip this delete - user didn't intend to delete this region
        } else {
          // Non-clamp-sensitive deletes (TextNodes) are applied in full
          deletesToApply.append((range, parentKey))
        }
      }

		      // If clamp starts before the first intersected delete, add a leading delete to cover
		      // selection preamble left behind by grouping.
      if let ms = minStart, clamp.location < ms {
        let lead = NSRange(location: clamp.location, length: ms - clamp.location)
        if lead.length > 0 {
          let fallbackParent = plannedDeletes.first?.parentKey
          deletesToApply.append((lead, fallbackParent))
        }
      }

      if clamp.length > 0 {
        let clampCovered = deletesToApply.contains { entry in
          entry.range.location <= clamp.location
            && NSMaxRange(entry.range) >= NSMaxRange(clamp)
        }
        if !clampCovered {
          let fallbackParent = plannedDeletes.first?.parentKey
          deletesToApply.append((clamp, fallbackParent))
        }
      }

      // Coalesce overlapping deletes (keep the first parentKey for a merged region).
      deletesToApply.sort { $0.range.location < $1.range.location }
      var merged: [(range: NSRange, parentKey: NodeKey?)] = []
		      for (r, pk) in deletesToApply {
		        guard r.length > 0 else { continue }
		        if var last = merged.last, NSMaxRange(last.range) >= r.location {
		          merged.removeLast()
		          let newEnd = max(NSMaxRange(last.range), NSMaxRange(r))
		          last.range = NSRange(location: last.range.location, length: newEnd - last.range.location)
		          merged.append(last)
		        } else {
		          merged.append((r, pk))
		        }
		      }
      deletesToApply = merged
      editor.pendingDeletionClampRange = nil
    } else {
      deletesToApply = plannedDeletes.map { (range: $0.range, parentKey: $0.parentKey) }
    }
    print("🔍 DEBUG deletesToApply: \(deletesToApply.map { "(range=\($0.range), parentKey=\($0.parentKey ?? "nil"))" })")
    print("🔍 DEBUG textStorage.string before deletes: \"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"")

		    // Apply deletes in reverse order so earlier ranges are stable.
		    for (range, parentKey) in deletesToApply.sorted(by: { $0.range.location > $1.range.location }) {
		      guard range.length > 0 else { continue }
		      guard range.location >= 0 else { continue }
		      guard range.location + range.length <= textStorage.length else { continue }
		      print("🔍 DEBUG deleting range \(range)")
		      textStorage.deleteCharacters(in: range)
		      deletions.append((range.location + range.length, range.length, parentKey))
		    }
    print("🔍 DEBUG textStorage.string after deletes: \"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"")

	    // Phase 2: Batch update childrenLength for all affected parents
	    // Group deletions by parent for efficient updates
	    var parentDeltas: [NodeKey: Int] = [:]
    for (_, length, parentKey) in deletions {
      guard let pKey = parentKey else { continue }
      parentDeltas[pKey, default: 0] -= length
    }
    for (parentKey, delta) in parentDeltas {
      propagateChildrenLengthDelta(fromParentKey: parentKey, delta: delta, state: prevState, editor: editor)
    }

    // Phase 3: Batch shift remaining cache entries in a single O(n) pass
    // Sort deletions by endLocation (ascending) for efficient cumulative delta calculation
    deletions.sort { $0.endLocation < $1.endLocation }

    // Build exclusion set: all ancestors of all deleted nodes
    var allExcludedKeys = Set<NodeKey>()
    for (_, node) in removes {
      var parentKey = node.parent
      while let pKey = parentKey {
        allExcludedKeys.insert(pKey)
        parentKey = prevState.nodeMap[pKey]?.parent
      }
    }

    // Single pass through remaining cache entries
    let remainingKeys = Array(editor.rangeCache.keys)
    for key in remainingKeys {
      if allExcludedKeys.contains(key) { continue }
      guard var item = editor.rangeCache[key] else { continue }

      // Calculate cumulative delta from all deletions before this location
      var cumulativeDelta = 0
      for (endLoc, length, _) in deletions {
        if endLoc <= item.location {
          cumulativeDelta -= length
        } else {
          break  // Deletions are sorted, no more will affect this item
        }
      }

      if cumulativeDelta != 0 {
        item.location += cumulativeDelta
        editor.rangeCache[key] = item
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

	    let range = editor.actualRange(for: node.key) ?? cacheItem.range
	    let deletedLength = range.length
	    let deletedLocation = range.location

	    if deletedLength > 0 && deletedLocation + deletedLength <= textStorage.length {
	      textStorage.deleteCharacters(in: range)
	    }

    // Remove from range cache
    editor.rangeCache.removeValue(forKey: node.key)

    // Shift all nodes after the deleted range
    if deletedLength > 0 {
      propagateChildrenLengthDelta(fromParentKey: node.parent, delta: -deletedLength, editor: editor)
      let oldEnd = deletedLocation + deletedLength
      let excludingKeys = ancestorKeys(fromParentKey: node.parent)
      shiftRangeCacheAfter(location: oldEnd, delta: -deletedLength, excludingKeys: excludingKeys, editor: editor)
    }
  }

  /// Update a node that has been modified.
  private static func updateNode(
    from prev: Node,
    to next: Node,
    in textStorage: NSTextStorage,
    state: EditorState,
    editor: Editor,
    theme: Theme,
    useLazyLocations: Bool
  ) throws {
    // Check if node was reparented - if so, we need to update both old and new parent's childrenLength
    let wasReparented = prev.parent != next.parent
    if wasReparented, let cacheItem = editor.rangeCache[prev.key] {
      let nodeLength = cacheItem.entireLength
      // Decrement old parent's childrenLength
      propagateChildrenLengthDelta(fromParentKey: prev.parent, delta: -nodeLength, editor: editor)
      // Increment new parent's childrenLength
      propagateChildrenLengthDelta(fromParentKey: next.parent, delta: nodeLength, state: state, editor: editor)
    }

    // Handle text node changes
    if let prevText = prev as? TextNode, let nextText = next as? TextNode {
      try updateTextNode(
        from: prevText,
        to: nextText,
        in: textStorage,
        state: state,
        editor: editor,
        theme: theme,
        useLazyLocations: useLazyLocations
      )
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
    theme: Theme,
    useLazyLocations: Bool
  ) throws {
    guard var cacheItem = editor.rangeCache[prev.key] else { return }

    let oldText = prev.getTextPart(fromLatest: false)
    let newText = next.getTextPart(fromLatest: false)

    let oldLength = cacheItem.textLength
    let oldTextLen = oldText.lengthAsNSString()
    let newLength = newText.lengthAsNSString()
    let delta = newLength - oldLength

    let baseLoc = cacheItem.location
    let nodeLoc: Int = {
      guard useLazyLocations else { return baseLoc }
      guard let item = editor.rangeCache[prev.key] else { return baseLoc }
      let dfsPos = item.dfsPosition
      return editor.actualLocation(for: prev.key, dfsPosition: dfsPos) ?? baseLoc
    }()

    let textStart = nodeLoc + cacheItem.preambleLength + cacheItem.childrenLength
    let textRange = NSRange(location: textStart, length: oldLength)
    print("🔍 DEBUG updateTextNode key=\(prev.key) oldText=\(oldText) newText=\(newText) textRange=\(textRange) storageLen=\(textStorage.length) storage=\"\(textStorage.string.replacingOccurrences(of: "\n", with: "\\n"))\"")

    guard textRange.location + textRange.length <= textStorage.length else { return }

    // Check if the storage has been modified by a prior merge operation (e.g., paragraph merge via backspace).
    // This can happen when deleting a paragraph boundary causes adjacent text to merge physically,
    // and then a TextNode update tries to reflect the same change.
    // We detect this by checking if the new content is already at the expected location.
    if newLength > oldLength, textStart + newLength <= textStorage.length {
      let newContentRange = NSRange(location: textStart, length: newLength)
      let actualContent = textStorage.attributedSubstring(from: newContentRange).string
      if actualContent == newText {
        // Storage already has the new content at this location - merge already happened.
        // Just update cache and attributes without modifying storage.
        let actualNewLength = newLength
        let delta = actualNewLength - oldLength
        cacheItem.textLength = actualNewLength
        editor.rangeCache[next.key] = cacheItem

        if delta != 0 {
          propagateChildrenLengthDelta(fromParentKey: next.parent, delta: delta, state: state, editor: editor)
          let oldEnd = textStart + oldLength
          let excludingKeys = ancestorKeys(fromParentKey: next.parent)
          shiftRangeCacheAfter(location: oldEnd, delta: delta, excludingKeys: excludingKeys, editor: editor)
        }

        // Apply attributes to the existing content
        let attributes = AttributeUtils.attributedStringStyles(from: next, state: state, theme: theme)
        textStorage.setAttributes(attributes, range: newContentRange)
        if newContentRange.length > 0 {
          textStorage.fixAttributes(in: newContentRange)
        }
        print("🔍 DEBUG updateTextNode SKIPPED (content already merged) key=\(prev.key)")
        return
      }
    }

    // Incremental text updates: avoid replacing the entire TextNode content (which can be large
    // after big pastes) for small edits like typing.
    if oldText == newText {
      // Attribute-only update: keep content, re-apply styles.
      let attributes = AttributeUtils.attributedStringStyles(from: next, state: state, theme: theme)
      textStorage.setAttributes(attributes, range: textRange)
      if textRange.length > 0 {
        textStorage.fixAttributes(in: textRange)
      }
    } else if oldTextLen == oldLength {
      // Minimal replace algorithm (LCP/LCS): replace only the changed span.
      let oldStr = oldText as NSString
      let newStr = newText as NSString
      let maxPref = min(oldTextLen, newLength)
      var lcp = 0
      while lcp < maxPref && oldStr.character(at: lcp) == newStr.character(at: lcp) { lcp += 1 }
      let oldRem = oldTextLen - lcp
      let newRem = newLength - lcp
      let maxSuf = min(oldRem, newRem)
      var lcs = 0
      while lcs < maxSuf && oldStr.character(at: oldTextLen - 1 - lcs) == newStr.character(at: newLength - 1 - lcs) { lcs += 1 }

      let changedOldLen = max(0, oldRem - lcs)
      let changedNewLen = max(0, newRem - lcs)
      let replaceLoc = textStart + lcp
      let replaceRange = NSRange(location: replaceLoc, length: changedOldLen)

      let newSegment =
        changedNewLen > 0 ? newStr.substring(with: NSRange(location: lcp, length: changedNewLen)) : ""
      let styled = AttributeUtils.attributedStringByAddingStyles(
        NSAttributedString(string: newSegment),
        from: next,
        state: state,
        theme: theme
      )

      if styled.length == 0 && changedOldLen > 0 {
        // Pure deletion is cheaper and avoids attribute churn.
        textStorage.deleteCharacters(in: replaceRange)
        let fixStart = max(0, replaceLoc - 1)
        let fixLen = min(2, (textStorage.length - fixStart))
        if fixLen > 0 {
          textStorage.fixAttributes(in: NSRange(location: fixStart, length: fixLen))
        }
      } else {
        textStorage.replaceCharacters(in: replaceRange, with: styled)
        let fixLen = max(changedOldLen, styled.length)
        let fixCandidate = NSRange(location: replaceLoc, length: fixLen)
        let safeFix = NSIntersectionRange(fixCandidate, NSRange(location: 0, length: textStorage.length))
        if safeFix.length > 0 {
          textStorage.fixAttributes(in: safeFix)
        }
      }
    } else {
      // Fallback (should be rare): replace full content.
      let newContent = buildTextNodeContent(next, state: state, theme: theme)
      textStorage.replaceCharacters(in: textRange, with: newContent)
    }

    // Update range cache for this node
    var updatedItem = cacheItem
    updatedItem.textLength = newLength
    editor.rangeCache[next.key] = updatedItem

    // Shift all nodes after this one if length changed
    if delta != 0 {
      if useLazyLocations {
        applyFenwickSuffixShift(afterKey: next.key, delta: delta, editor: editor)
      } else {
        let afterLocation = textStart + oldLength
        let excludingKeys = ancestorKeys(fromParentKey: next.parent)
        shiftRangeCacheAfter(location: afterLocation, delta: delta, excludingKeys: excludingKeys, editor: editor)
      }

      // Update parent's childrenLength
      propagateChildrenLengthDelta(fromParentKey: next.parent, delta: delta, editor: editor)
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
    guard var cacheItem = editor.rangeCache[prev.key] else { return }

    let attributes = AttributeUtils.attributedStringStyles(from: next, state: state, theme: theme)

    // Update preamble/postamble without relying on global editor state (which can lag
    // behind `state` during reconciliation).
    let nextPreamble = computeElementPreamble(for: next, state: state)
    let nextPreambleLength = nextPreamble.utf16.count
    let oldPreambleLength = cacheItem.preambleLength
    if nextPreambleLength != oldPreambleLength
      || (oldPreambleLength > 0
        && NSMaxRange(NSRange(location: cacheItem.location, length: oldPreambleLength)) <= textStorage.length
        && textStorage.attributedSubstring(from: NSRange(location: cacheItem.location, length: oldPreambleLength)).string != nextPreamble)
    {
      let preambleRange = NSRange(location: cacheItem.location, length: oldPreambleLength)
      let styledPreamble = NSAttributedString(string: nextPreamble, attributes: attributes)

      if preambleRange.location + preambleRange.length <= textStorage.length {
        textStorage.replaceCharacters(in: preambleRange, with: styledPreamble)
      } else if preambleRange.location <= textStorage.length {
        textStorage.insert(styledPreamble, at: preambleRange.location)
      }

      let delta = nextPreambleLength - oldPreambleLength
      cacheItem.preambleLength = nextPreambleLength
      editor.rangeCache[next.key] = cacheItem

      if delta != 0 {
        propagateChildrenLengthDelta(fromParentKey: next.parent, delta: delta, editor: editor)
        let oldEnd = preambleRange.location + preambleRange.length
        let excludingKeys = ancestorKeys(fromParentKey: next.parent)
        shiftRangeCacheAfter(location: oldEnd, delta: delta, excludingKeys: excludingKeys, editor: editor)
      }
    }

    // Update postamble if necessary.
    let nextPostamble = computeElementPostamble(for: next, state: state)
    let nextPostambleLength = nextPostamble.utf16.count
    let oldPostambleLength = cacheItem.postambleLength
    if nextPostambleLength != oldPostambleLength
      || (oldPostambleLength > 0
        && NSMaxRange(
          NSRange(
            location: cacheItem.location + cacheItem.preambleLength + cacheItem.childrenLength + cacheItem.textLength,
            length: oldPostambleLength
          )
        ) <= textStorage.length
        && textStorage.attributedSubstring(
          from: NSRange(
            location: cacheItem.location + cacheItem.preambleLength + cacheItem.childrenLength + cacheItem.textLength,
            length: oldPostambleLength
          )
        ).string != nextPostamble)
    {
      let postambleStart = cacheItem.location + cacheItem.preambleLength + cacheItem.childrenLength + cacheItem.textLength
      let postambleRange = NSRange(location: postambleStart, length: oldPostambleLength)
      let styledPostamble = NSAttributedString(string: nextPostamble, attributes: attributes)

      if postambleRange.location + postambleRange.length <= textStorage.length {
        textStorage.replaceCharacters(in: postambleRange, with: styledPostamble)
      } else if postambleRange.location <= textStorage.length {
        textStorage.insert(styledPostamble, at: postambleRange.location)
      }

      let delta = nextPostambleLength - oldPostambleLength
      cacheItem.postambleLength = nextPostambleLength
      editor.rangeCache[next.key] = cacheItem

      if delta != 0 {
        propagateChildrenLengthDelta(fromParentKey: next.parent, delta: delta, editor: editor)
        let oldEnd = postambleStart + oldPostambleLength
        let excludingKeys = ancestorKeys(fromParentKey: next.parent)
        shiftRangeCacheAfter(location: oldEnd, delta: delta, excludingKeys: excludingKeys, editor: editor)
      }
    }
  }

  private static func computeElementPreamble(for element: ElementNode, state: EditorState) -> String {
    let intrinsic = element.getPreambleIntrinsic()
    if element.isInline() { return intrinsic }

    guard let parentKey = element.parent,
          let parent = state.nodeMap[parentKey] as? ElementNode
    else { return intrinsic }

    let children = parent.getChildrenKeys(fromLatest: false)
    guard let idx = children.firstIndex(of: element.key), idx > 0 else {
      return intrinsic
    }
    let prevSiblingKey = children[idx - 1]
    guard let prevSibling = state.nodeMap[prevSiblingKey] else { return intrinsic }

    if parent is RootNode {
      return ((prevSibling is DecoratorNode && !prevSibling.isInline()) ? "\n" : "") + intrinsic
    }

    return ((prevSibling is ElementNode) ? "" : "\n") + intrinsic
  }

  private static func computeElementPostamble(for element: ElementNode, state: EditorState) -> String {
    let intrinsic = element.getPostambleIntrinsic()
    guard let parentKey = element.parent,
          let parent = state.nodeMap[parentKey] as? ElementNode
    else { return intrinsic }

    let children = parent.getChildrenKeys(fromLatest: false)
    guard let idx = children.firstIndex(of: element.key) else { return intrinsic }
    let hasNextSibling = idx + 1 < children.count
    if !hasNextSibling { return intrinsic }

    if element.isInline() {
      let nextSiblingKey = children[idx + 1]
      if let nextSibling = state.nodeMap[nextSiblingKey], !nextSibling.isInline() {
        return intrinsic + "\n"
      }
      return intrinsic
    }

    return intrinsic + "\n"
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
    let result = NSMutableAttributedString()
    appendAttributedSubtree(into: result, nodeKey: node.getKey(), state: state, theme: theme)
    return result
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
    for childKey in node.getChildrenKeys(fromLatest: false) {
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
      let siblings = parent.getChildrenKeys(fromLatest: false)
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
    let children = parent.getChildrenKeys(fromLatest: false)
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
    state: EditorState,
    editor: Editor
  ) {
    // Collect ancestor keys - we shouldn't shift ancestors since the insertion is inside them
    var ancestorKeys = Set<NodeKey>()
    var currentKey = node.parent
    while let key = currentKey {
      ancestorKeys.insert(key)
      currentKey = state.nodeMap[key]?.parent
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

    propagateChildrenLengthDelta(fromParentKey: node.parent, delta: length, state: state, editor: editor)
  }

  private static func propagateChildrenLengthDelta(
    fromParentKey parentKey: NodeKey?,
    delta: Int,
    state: EditorState? = nil,
    editor: Editor
  ) {
    guard delta != 0 else { return }
    var currentKey = parentKey
    while let key = currentKey {
      if var item = editor.rangeCache[key] {
        item.childrenLength += delta
        editor.rangeCache[key] = item
      }
      if let state {
        currentKey = state.nodeMap[key]?.parent
      } else {
        currentKey = getNodeByKey(key: key)?.parent
      }
    }
  }

  private static func ancestorKeys(fromParentKey parentKey: NodeKey?) -> Set<NodeKey> {
    var keys = Set<NodeKey>()
    var currentKey = parentKey
    while let key = currentKey, let node = getNodeByKey(key: key) {
      keys.insert(key)
      currentKey = node.parent
    }
    return keys
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

    // Avoid mutating the dictionary while iterating it: this can trigger expensive internal copies
    // and becomes a hot path on large documents. Snapshot the keys and then apply updates.
    let keys = Array(editor.rangeCache.keys)
    for key in keys {
      if excludingKeys.contains(key) { continue }
      guard var item = editor.rangeCache[key] else { continue }
      if item.location >= location {
        item.location += delta
        editor.rangeCache[key] = item
      }
    }
  }

  private static func applyFenwickSuffixShift(afterKey: NodeKey, delta: Int, editor: Editor) {
    guard editor.useFenwickLocations, delta != 0 else { return }

    let (order, _) = editor.cachedDFSOrderAndIndex()
    let totalNodes = order.count
    guard totalNodes > 0 else { return }

    editor.ensureFenwickCapacity(totalNodes)

    guard let dfsPosition = editor.rangeCache[afterKey]?.dfsPosition, dfsPosition > 0 else { return }
    guard dfsPosition < totalNodes else { return }

    // Shift nodes strictly after `afterKey` (exclusive start).
    editor.addFenwickDelta(atIndex: dfsPosition + 1, delta: delta)
  }

  private static func materializeFenwickLocations(editor: Editor) {
    guard editor.useFenwickLocations, editor.fenwickHasDeltas else { return }

    let (order, _) = editor.cachedDFSOrderAndIndex()
    let totalNodes = order.count
    guard totalNodes > 0 else {
      editor.resetFenwickTree(capacity: editor.rangeCache.count)
      return
    }

    editor.ensureFenwickCapacity(totalNodes)
    let tree = editor.locationFenwickTree

    for key in order {
      guard var item = editor.rangeCache[key] else { continue }
      item.location = item.locationFromFenwick(using: tree)
      editor.rangeCache[key] = item
    }

    // All locations are now absolute again; clear deltas.
    editor.resetFenwickTree(capacity: editor.rangeCache.count)
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
      rangeCache: editor.rangeCache,
      fenwickTree: {
        guard editor.useFenwickLocations, editor.fenwickHasDeltas else { return nil }
        _ = editor.cachedDFSOrderAndIndex()
        return editor.locationFenwickTree
      }()
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

    propagateChildrenLengthDelta(fromParentKey: getNodeByKey(key: nodeKey)?.parent, delta: delta, editor: editor)

    // Shift all nodes after this one using O(log N) Fenwick delta when available.
    if editor.useFenwickLocations {
      applyFenwickSuffixShift(afterKey: nodeKey, delta: delta, editor: editor)
    } else {
      // Fallback to O(N) loop when Fenwick is disabled
      for (key, var item) in editor.rangeCache where key != nodeKey {
        if item.location > cacheItem.location {
          item.location += delta
          editor.rangeCache[key] = item
        }
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
      if editor.useFenwickLocations, editor.fenwickHasDeltas, let loc = editor.actualLocation(for: key) { return loc }
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
      let candidateLoc: Int = {
        if editor.useFenwickLocations, editor.fenwickHasDeltas, let loc = editor.actualLocation(for: key) {
          return loc
        }
        return editor.rangeCache[key]?.location ?? oldLoc
      }()
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
