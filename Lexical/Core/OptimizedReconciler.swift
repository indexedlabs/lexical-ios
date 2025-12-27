/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore
import QuartzCore

#if canImport(UIKit)
import UIKit
private typealias PlatformTextAttachment = TextAttachment
#elseif os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
private typealias PlatformTextAttachment = TextAttachmentAppKit
#endif

// Optimized reconciler entry point. Initially a thin wrapper so we can land
// the feature flag, metrics, and supporting data structures incrementally.

internal enum OptimizedReconciler {
  struct InstructionApplyStats { let deletes: Int; let inserts: Int; let sets: Int; let fixes: Int; let duration: TimeInterval }

  @MainActor
  private static func reconcilerTextStorage(_ editor: Editor) -> ReconcilerTextStorage? {
    #if canImport(UIKit)
    return editor.textStorage
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    return editor.textStorage as? ReconcilerTextStorage
    #else
    return nil
    #endif
  }

  @MainActor
  private static func reconcilerLayoutManager(_ editor: Editor) -> NSLayoutManager? {
    #if canImport(UIKit)
    return editor.frontend?.layoutManager
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    return editor.frontendAppKit?.layoutManager
    #else
    return nil
    #endif
  }

  @MainActor
  private static func performWithoutAnimation(_ body: () -> Void) {
    #if canImport(UIKit)
    UIView.performWithoutAnimation(body)
    #else
    body()
    #endif
  }

  @MainActor
  private static func isReadOnlyFrontendContext(_ editor: Editor) -> Bool {
    #if canImport(UIKit)
    return editor.frontend is LexicalReadOnlyTextKitContext
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    return editor.isReadOnlyFrontend
    #else
    return false
    #endif
  }

  @MainActor
  private static func resetSelectedRange(editor: Editor) {
    #if canImport(UIKit)
    editor.frontend?.resetSelectedRange()
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    editor.frontendAppKit?.resetSelectedRange()
    #endif
  }

  @MainActor
  private static func updateNativeSelection(editor: Editor, selection: BaseSelection) throws {
    #if canImport(UIKit)
    try editor.frontend?.updateNativeSelection(from: selection)
    #elseif os(macOS) && !targetEnvironment(macCatalyst)
    try editor.frontendAppKit?.updateNativeSelection(from: selection)
    #endif
  }

  @MainActor
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
  @MainActor
  private static func fenwickOrderAndIndex(editor: Editor) -> ([NodeKey], [NodeKey: Int]) {
    editor.cachedDFSOrderAndIndex()
  }

  @MainActor
  private static func attachmentLocationsByKey(textStorage: ReconcilerTextStorage) -> [NodeKey: Int] {
    let storageLen = textStorage.length
    guard storageLen > 0 else { return [:] }
    var locations: [NodeKey: Int] = [:]
    textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storageLen)) { value, range, _ in
      if let att = value as? PlatformTextAttachment, let key = att.key {
        locations[key] = range.location
      }
    }
    return locations
  }

  @MainActor
  private static func syncDecoratorPositionCacheWithRangeCache(editor: Editor) {
    guard let ts = reconcilerTextStorage(editor), !ts.decoratorPositionCache.isEmpty else { return }
    var movedDecorators: [(NodeKey, Int, Int)] = []
    var attachmentLocations: [NodeKey: Int]? = nil
    for (key, oldLoc) in ts.decoratorPositionCache {
      let candidateLoc = editor.rangeCache[key]?.location ?? oldLoc
      let storageLen = ts.length

      // Prefer the rangeCache location when it actually points at this attachment.
      var resolvedLoc: Int = candidateLoc
      if storageLen > 0, candidateLoc >= 0, candidateLoc < storageLen,
         let att = ts.attribute(.attachment, at: candidateLoc, effectiveRange: nil) as? PlatformTextAttachment,
         att.key == key {
        resolvedLoc = candidateLoc
      } else if storageLen > 0 {
        // Fall back to scanning the storage for the attachment key (rangeCache can be stale
        // during structural delete fast paths and selection-driven edits).
        if attachmentLocations == nil {
          attachmentLocations = attachmentLocationsByKey(textStorage: ts)
        }
        if let foundAt = attachmentLocations?[key] { resolvedLoc = foundAt }
      }

      if oldLoc != resolvedLoc {
        movedDecorators.append((key, oldLoc, resolvedLoc))
      }
      ts.decoratorPositionCache[key] = resolvedLoc
    }
    if !movedDecorators.isEmpty {
      for (key, _, _) in movedDecorators {
        ts.decoratorPositionCacheDirtyKeys.insert(key)
      }
    }
    if movedDecorators.isEmpty { return }
    let editorWeak = editor
    let movedCopy = movedDecorators
    DispatchQueue.main.async {
      guard let layoutManager = reconcilerLayoutManager(editorWeak),
            let ts = reconcilerTextStorage(editorWeak) else { return }
      for (key, oldLoc, _) in movedCopy {
        if let range = editorWeak.rangeCache[key]?.range {
          layoutManager.invalidateDisplay(forCharacterRange: range)
        }
        let oldRange = NSRange(location: oldLoc, length: 1)
        if oldRange.location < ts.length {
          layoutManager.invalidateDisplay(forCharacterRange: oldRange)
        }
      }
    }
  }
  // Instruction set for applying minimal changes to TextStorage
  enum Instruction {
    case delete(range: NSRange)
    case insert(location: Int, attrString: NSAttributedString)
    case setAttributes(range: NSRange, attributes: [NSAttributedString.Key: Any])
    case fixAttributes(range: NSRange)
    case decoratorAdd(key: NodeKey)
    case decoratorRemove(key: NodeKey)
    case decoratorDecorate(key: NodeKey)
    case applyBlockAttributes(nodeKey: NodeKey)
  }

  // Planner: collect text-only multi instructions without applying
  @MainActor
  private static func plan_TextOnly_Multi(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor
  ) throws -> (instructions: [Instruction], lengthChanges: [(nodeKey: NodeKey, part: NodePart, delta: Int)], affected: Set<NodeKey>)? {
    // Structural safety: central aggregation text-only planning must not run when the update also
    // adds/removes/reorders nodes. Those operations need either a dedicated structural path or a
    // slow rebuild to keep TextStorage consistent with the pending EditorState.
    if currentEditorState.nodeMap.count != pendingEditorState.nodeMap.count {
      return nil
    }
    let candidates: [NodeKey] = editor.dirtyNodes.keys.compactMap { key in
      guard let prev = currentEditorState.nodeMap[key] as? TextNode,
            let next = pendingEditorState.nodeMap[key] as? TextNode,
            let prevRange = editor.rangeCache[key] else { return nil }
      let oldText = prev.getTextPart(fromLatest: false); let newText = next.getTextPart(fromLatest: false)
      if oldText == newText { return nil }
      if prevRange.preambleLength != next.getPreamble().lengthAsNSString() { return nil }
      if prevRange.postambleLength != next.getPostamble().lengthAsNSString() { return nil }
      return key
    }
    if candidates.isEmpty { return nil }

    // Restrict to local edits: only the changed text nodes and their ancestors may be dirty, and
    // those ancestors must not have structural child-list changes.
    var allowedDirtyKeys: Set<NodeKey> = Set(candidates)
    for key in candidates {
      guard let prev = currentEditorState.nodeMap[key] as? TextNode,
            let next = pendingEditorState.nodeMap[key] as? TextNode else { return nil }
      if prev.parent != next.parent { return nil }
      for p in next.getParents() { allowedDirtyKeys.insert(p.getKey()) }
    }
    for k in editor.dirtyNodes.keys where !allowedDirtyKeys.contains(k) {
      return nil
    }
    for k in allowedDirtyKeys where !candidates.contains(k) {
      guard let prevAny = currentEditorState.nodeMap[k], let nextAny = pendingEditorState.nodeMap[k] else { return nil }
      if let prevEl = prevAny as? ElementNode {
        guard let nextEl = nextAny as? ElementNode else { return nil }
        if prevEl.getChildrenKeys(fromLatest: false) != nextEl.getChildrenKeys(fromLatest: false) {
          return nil
        }
      }
    }

    var instructions: [Instruction] = []
    var affected: Set<NodeKey> = []
    var lengthChanges: [(nodeKey: NodeKey, part: NodePart, delta: Int)] = []
    let theme = editor.getTheme()
    for key in candidates {
      guard let prev = currentEditorState.nodeMap[key] as? TextNode,
            let next = pendingEditorState.nodeMap[key] as? TextNode,
            let prevRange = editor.rangeCache[key] else { continue }
      let oldText = prev.getTextPart(fromLatest: false); let newText = next.getTextPart(fromLatest: false)
      if oldText == newText { continue }
      let textStart = prevRange.location + prevRange.preambleLength + prevRange.childrenLength
      let deleteRange = NSRange(location: textStart, length: oldText.lengthAsNSString())
      if deleteRange.length > 0 { instructions.append(.delete(range: deleteRange)) }
      let attr = AttributeUtils.attributedStringByAddingStyles(NSAttributedString(string: newText), from: next, state: pendingEditorState, theme: theme)
      if attr.length > 0 { instructions.append(.insert(location: textStart, attrString: attr)) }
      let delta = newText.lengthAsNSString() - oldText.lengthAsNSString()
      lengthChanges.append((nodeKey: key, part: .text, delta: delta))
      affected.insert(key)
      for p in next.getParents() { affected.insert(p.getKey()) }
    }
    return instructions.isEmpty ? nil : (instructions, lengthChanges, affected)
  }

  // Pre/post attributes-only planning has been retired. The optimized reconciler now uses a single
  // graduated strategy and does not expose algorithm forks.
  @MainActor
  private static func plan_PreamblePostambleOnly_Multi(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor
  ) throws -> (instructions: [Instruction], lengthChanges: [(nodeKey: NodeKey, part: NodePart, delta: Int)], affected: Set<NodeKey>)? {
    nil
  }
  
  // MARK: - Modern TextKit Optimizations (iOS 16+)
  
  @MainActor
  private static func applyInstructionsWithModernBatching(
    _ instructions: [Instruction],
    editor: Editor,
    fixAttributesEnabled: Bool = true
  ) -> InstructionApplyStats {
    guard let textStorage = reconcilerTextStorage(editor) else {
      return InstructionApplyStats(deletes: 0, inserts: 0, sets: 0, fixes: 0, duration: 0)
    }
    
    let applyStart = CFAbsoluteTimeGetCurrent()
    
    // Step 1: Categorize all operations
    struct TextOp {
      enum Kind {
        case delete(NSRange)
        case insert(Int, NSAttributedString)
        case set(NSRange, [NSAttributedString.Key: Any])
      }

      // Higher locations should be applied first to avoid adjusting offsets.
      let location: Int
      // Ordering at the same location: delete → insert → set.
      let order: Int
      // Stable ordering within the same location/type.
      let sequence: Int
      let kind: Kind
    }

    var textOps: [TextOp] = []
    var decoratorOps: [Instruction] = []
    var blockAttributeOps: [NodeKey] = []
    var fixCount = 0
    var deleteCount = 0
    var insertCount = 0
    var setCount = 0
    
    for (index, inst) in instructions.enumerated() {
      switch inst {
      case .delete(let r):
        if r.length > 0 {
          deleteCount += 1
          textOps.append(TextOp(location: r.location, order: 0, sequence: index, kind: .delete(r)))
        }
      case .insert(let loc, let s):
        if s.length > 0 {
          insertCount += 1
          textOps.append(TextOp(location: loc, order: 1, sequence: index, kind: .insert(loc, s)))
        }
      case .setAttributes(let r, let attrs):
        if r.length > 0 {
          setCount += 1
          textOps.append(TextOp(location: r.location, order: 2, sequence: index, kind: .set(r, attrs)))
        }
      case .fixAttributes:
        fixCount += 1
      case .decoratorAdd, .decoratorRemove, .decoratorDecorate:
        decoratorOps.append(inst)
      case .applyBlockAttributes(let key):
        blockAttributeOps.append(key)
      }
    }
    
    // Step 2: Apply text changes in a single batch transaction
    let previousMode = textStorage.mode
    textStorage.mode = .controllerMode
    
    // Wrap all operations in CATransaction for UI performance
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      textStorage.mode = previousMode
    }
    
    // Begin text storage editing batch
    textStorage.beginEditing()
    defer { textStorage.endEditing() }
    
    // Pre-calculate all safe ranges to minimize bounds checking
    var currentLength = textStorage.length
    var allModifiedRanges: [NSRange] = []
    allModifiedRanges.reserveCapacity(textOps.count)

    // Apply operations in descending location order to avoid offset adjustments.
    textOps.sort {
      if $0.location != $1.location { return $0.location > $1.location }
      if $0.order != $1.order { return $0.order < $1.order }
      return $0.sequence < $1.sequence
    }

    for op in textOps {
      switch op.kind {
      case .delete(let r):
        let safe = NSIntersectionRange(r, NSRange(location: 0, length: currentLength))
        if safe.length > 0 {
          textStorage.deleteCharacters(in: safe)
          allModifiedRanges.append(safe)
          currentLength -= safe.length
        }
      case .insert(let loc, let s):
        let safeLoc = max(0, min(loc, currentLength))
        textStorage.insert(s, at: safeLoc)
        allModifiedRanges.append(NSRange(location: safeLoc, length: s.length))
        currentLength += s.length
      case .set(let r, let attrs):
        let safe = NSIntersectionRange(r, NSRange(location: 0, length: currentLength))
        if safe.length > 0 {
          textStorage.setAttributes(attrs, range: safe)
          allModifiedRanges.append(safe)
        }
      }
    }
    
    // Step 3: Optimize fixAttributes with minimal range
    if fixAttributesEnabled && !allModifiedRanges.isEmpty {
      let cover = allModifiedRanges.reduce(allModifiedRanges[0]) { acc, r in
        NSRange(
          location: min(acc.location, r.location),
          length: max(NSMaxRange(acc), NSMaxRange(r)) - min(acc.location, r.location)
        )
      }
      let safeCover = NSIntersectionRange(cover, NSRange(location: 0, length: currentLength))
      if safeCover.length > 0 {
        textStorage.fixAttributes(in: safeCover)
      }
    }
    
    // Step 4: Batch decorator operations without animations
    if !decoratorOps.isEmpty {
      performWithoutAnimation {
        for op in decoratorOps {
          switch op {
          case .decoratorAdd(let key):
            if let loc = editor.rangeCache[key]?.location,
               let ts = reconcilerTextStorage(editor) {
              ts.decoratorPositionCache[key] = loc
              ts.decoratorPositionCacheDirtyKeys.insert(key)
            }
          case .decoratorRemove(let key):
            if let ts = reconcilerTextStorage(editor) {
              ts.decoratorPositionCache[key] = nil
              ts.decoratorPositionCacheDirtyKeys.insert(key)
            }
          case .decoratorDecorate(let key):
            if let loc = editor.rangeCache[key]?.location,
               let ts = reconcilerTextStorage(editor) {
              ts.decoratorPositionCache[key] = loc
              ts.decoratorPositionCacheDirtyKeys.insert(key)
            }
          default:
            break
          }
        }
      }
    }
    
    let applyDuration = CFAbsoluteTimeGetCurrent() - applyStart
    return InstructionApplyStats(
      deletes: deleteCount,
      inserts: insertCount,
      sets: setCount,
      fixes: (fixCount > 0 ? 1 : 0),
      duration: applyDuration
    )
  }
  
  // MARK: - Optimized Batch Coalescing Functions
  
  @MainActor
  private static func optimizedBatchCoalesceDeletes(_ ranges: [NSRange]) -> [NSRange] {
    if ranges.isEmpty { return [] }
    
    // Use Set for O(1) deduplication
    var uniqueRanges = Set<NSRange>()
    for range in ranges {
      uniqueRanges.insert(range)
    }
    
    // Sort and merge overlapping/adjacent ranges
    let sorted = uniqueRanges.sorted { $0.location < $1.location }
    var merged: [NSRange] = []
    merged.reserveCapacity(sorted.count)
    
    var current = sorted[0]
    for r in sorted.dropFirst() {
      if NSMaxRange(current) >= r.location {
        // Merge overlapping or adjacent
        let end = max(NSMaxRange(current), NSMaxRange(r))
        current = NSRange(location: current.location, length: end - current.location)
      } else {
        merged.append(current)
        current = r
      }
    }
    merged.append(current)
    
    // Return in reverse order for safe deletion
    return merged.sorted { $0.location > $1.location }
  }
  
  @MainActor
  private static func optimizedBatchCoalesceInserts(_ ops: [(Int, NSAttributedString)]) -> [(Int, NSAttributedString)] {
    if ops.isEmpty { return [] }
    
    // Group by location with pre-allocated capacity
    let sorted = ops.sorted { $0.0 < $1.0 }
    var result: [(Int, NSMutableAttributedString)] = []
    result.reserveCapacity(ops.count)
    
    for (loc, s) in sorted {
      if let lastIndex = result.indices.last, result[lastIndex].0 == loc {
        // Batch concatenate at same location
        result[lastIndex].1.append(s)
      } else {
        // Pre-allocate mutable string with expected capacity
        let mutable = NSMutableAttributedString(attributedString: s)
        result.append((loc, mutable))
      }
    }
    
    // Convert to immutable for return
    return result.map { ($0.0, NSAttributedString(attributedString: $0.1)) }
  }
  
  @MainActor
  private static func optimizedBatchCoalesceAttributeSets(
    _ sets: [(NSRange, [NSAttributedString.Key: Any])]
  ) -> [(NSRange, [NSAttributedString.Key: Any])] {
    if sets.isEmpty { return [] }
    
    // Group overlapping ranges with same attributes
    var grouped: [NSRange: [NSAttributedString.Key: Any]] = [:]
    
    for (range, attrs) in sets {
      var merged = false
      for (existingRange, existingAttrs) in grouped {
        // Check if ranges overlap and attributes are compatible
        if NSIntersectionRange(range, existingRange).length > 0 {
          // Merge ranges
          let newStart = min(range.location, existingRange.location)
          let newEnd = max(NSMaxRange(range), NSMaxRange(existingRange))
          let mergedRange = NSRange(location: newStart, length: newEnd - newStart)
          
          // Merge attributes (last one wins for conflicts)
          var mergedAttrs = existingAttrs
          for (key, value) in attrs {
            mergedAttrs[key] = value
          }
          
          grouped.removeValue(forKey: existingRange)
          grouped[mergedRange] = mergedAttrs
          merged = true
          break
        }
      }
      
      if !merged {
        grouped[range] = attrs
      }
    }
    
    return Array(grouped)
  }
  
  // MARK: - Batch Range Cache Updates
  
  @MainActor
  private static func batchUpdateRangeCache(
    editor: Editor,
    pendingEditorState: EditorState,
    changes: [(nodeKey: NodeKey, part: NodePart, delta: Int)]
  ) {
    if changes.isEmpty { return }
    
    // Pre-allocate collections
    var nodeDeltas: [NodeKey: Int] = [:]
    nodeDeltas.reserveCapacity(changes.count)
    
    var parentDeltas: [NodeKey: Int] = [:]
    
    // Batch calculate deltas
    for (nodeKey, part, delta) in changes {
      guard let node = pendingEditorState.nodeMap[nodeKey] else { continue }
      
      // Update node's own cache
      if var item = editor.rangeCache[nodeKey] {
        switch part {
        case .text:
          item.textLength += delta
        case .preamble:
          item.preambleLength += delta
        case .postamble:
          item.postambleLength += delta
        }
        editor.rangeCache[nodeKey] = item
      }
      
      // Accumulate parent deltas for childrenLength updates
      for parent in node.getParents() {
        let parentKey = parent.getKey()
        parentDeltas[parentKey, default: 0] += delta
      }
      
      nodeDeltas[nodeKey, default: 0] += delta
    }
    
    // Batch apply parent updates (children length changes)
    for (parentKey, totalDelta) in parentDeltas {
      if var parentItem = editor.rangeCache[parentKey] {
        parentItem.childrenLength += totalDelta
        editor.rangeCache[parentKey] = parentItem
      }
    }
  }
  
  // MARK: - Batch Decorator Position Updates

  @MainActor
  private static func batchUpdateDecoratorPositions(editor: Editor) {
    guard let textStorage = reconcilerTextStorage(editor) else { return }

    // Batch update all decorator positions at once
    var updates: [(NodeKey, Int, Int)] = [] // (key, oldLocation, newLocation)
    updates.reserveCapacity(textStorage.decoratorPositionCache.count)

    for (key, oldLocation) in textStorage.decoratorPositionCache {
      if let newLocation = editor.rangeCache[key]?.location, newLocation != oldLocation {
        updates.append((key, oldLocation, newLocation))
      }
    }

    // Apply all updates in single pass without animations
    performWithoutAnimation {
      for (key, _, newLocation) in updates {
        textStorage.decoratorPositionCache[key] = newLocation
        textStorage.decoratorPositionCacheDirtyKeys.insert(key)
      }
    }

    // Invalidate display for decorators whose positions changed so they get repositioned
    // during the next draw pass. Without this, decorator views won't move when content
    // is inserted above them (e.g., pressing Enter before an image).
    // IMPORTANT: Defer invalidation to next run loop to avoid crash when textStorage is editing.
    if !updates.isEmpty {
      let editorWeak = editor
      DispatchQueue.main.async {
        guard let layoutManager = reconcilerLayoutManager(editorWeak),
              let ts = reconcilerTextStorage(editorWeak) else {
          return
        }
        for (key, oldLocation, _) in updates {
          // Invalidate both old and new positions to ensure the view moves
          if let range = editorWeak.rangeCache[key]?.range {
            layoutManager.invalidateDisplay(forCharacterRange: range)
          }
          // Also invalidate the old location area
          let oldRange = NSRange(location: oldLocation, length: 1)
          if oldRange.location < ts.length {
            layoutManager.invalidateDisplay(forCharacterRange: oldRange)
          }
        }
      }
    }
  }
  
  // MARK: - Instruction application & coalescing
  @MainActor
  private static func applyInstructions(_ instructions: [Instruction], editor: Editor, fixAttributesEnabled: Bool = true) -> InstructionApplyStats {
    applyInstructionsWithModernBatching(instructions, editor: editor, fixAttributesEnabled: fixAttributesEnabled)
  }

  @MainActor
  internal static func updateEditorState(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    markedTextOperation: MarkedTextOperation?
  ) throws {
    // Optimized reconciler is always active in tests and app.
    guard let ts = reconcilerTextStorage(editor) else { fatalError("Cannot run optimized reconciler on an editor with no text storage") }
    #if DEBUG
    let updateStart = CFAbsoluteTimeGetCurrent()
    let docLen = ts.length
    #endif
    defer {
      #if DEBUG
      let syncStart = CFAbsoluteTimeGetCurrent()
      #endif
      syncDecoratorPositionCacheWithRangeCache(editor: editor)
      #if DEBUG
      let syncEnd = CFAbsoluteTimeGetCurrent()
      if docLen > 50000 {
        print("[updateEditorState] Total time: \(String(format: "%.3f", (CFAbsoluteTimeGetCurrent()-updateStart)*1000))ms syncDecorator=\(String(format: "%.3f", (syncEnd-syncStart)*1000))ms docLen=\(docLen)")
      }
      #endif
    }

    // Composition (marked text) fast path first
    if let mto = markedTextOperation {
      if try fastPath_Composition(
        currentEditorState: currentEditorState,
        pendingEditorState: pendingEditorState,
        editor: editor,
        shouldReconcileSelection: shouldReconcileSelection,
        op: mto
      ) { return }
    }

    // Full-editor-state swaps (e.g. `Editor.setEditorState`) must rebuild the entire TextStorage.
    // Fast paths are designed for incremental edits and can leave stale content behind.
    if editor.dirtyType == .fullReconcile {
      #if DEBUG
      print("[Reconciler] SLOW PATH: dirtyType=fullReconcile dirtyNodes=\(editor.dirtyNodes.count)")
      #endif
      try optimizedSlowPath(
        currentEditorState: currentEditorState,
        pendingEditorState: pendingEditorState,
        editor: editor,
        shouldReconcileSelection: shouldReconcileSelection
      )
      return
    }

    // Fresh-document fast hydration: build full string + cache in one pass
    if shouldHydrateFreshDocument(pendingState: pendingEditorState, editor: editor) {
      let hydrateStart = CFAbsoluteTimeGetCurrent()
      let previousRangeCacheCount = editor.rangeCache.count
      let dirtyNodeCount = editor.dirtyNodes.count
      try hydrateFreshDocumentFully(pendingState: pendingEditorState, editor: editor)
      // Also reconcile selection once so the caret lands correctly after
      // the first user input (e.g., typing into an empty document).
      if shouldReconcileSelection {
        let prevSelection = currentEditorState.selection
        let nextSelection = pendingEditorState.selection
        var selectionsAreDifferent = false
        if let nextSelection, let prevSelection { selectionsAreDifferent = !nextSelection.isSelection(prevSelection) }
        if (editor.dirtyType != .noDirtyNodes) || nextSelection == nil || selectionsAreDifferent {
          try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
        }
      }
      if let metrics = editor.metricsContainer {
        let duration = max(0.000_001, CFAbsoluteTimeGetCurrent() - hydrateStart)
        let added = max(0, editor.rangeCache.count - previousRangeCacheCount)
        let metric = ReconcilerMetric(
          duration: duration,
          dirtyNodes: dirtyNodeCount,
          rangesAdded: max(1, added),
          rangesDeleted: 0,
          treatedAllNodesAsDirty: true,
          pathLabel: "hydrate-fresh"
        )
        metrics.record(.reconcilerRun(metric))
      }
      return
    }

    // Selection-only updates should not pay the cost of diffing/reconciling the entire document.
    // These updates happen frequently during user navigation (arrow keys / tap to move caret).
    if editor.dirtyType == .noDirtyNodes {
      if shouldReconcileSelection {
        let prevSelection = currentEditorState.selection
        let nextSelection = pendingEditorState.selection
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

    // Try optimized fast paths before falling back (even if fullReconcile)
    // Optional central aggregation of Fenwick deltas across paths
    var fenwickAggregatedDeltas: [NodeKey: Int] = [:]

    // Structural insert fast path (before reorder)
    // Try multi-block insert first (K >= 2) - skip expensive computePartDiffs for this path
    var didInsertFastPath = false
    #if DEBUG
    let t_fastPaths_start = CFAbsoluteTimeGetCurrent()
    let t_multiBlock_start = CFAbsoluteTimeGetCurrent()
    #endif
    if try fastPath_InsertMultiBlock(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection,
      fenwickAggregatedDeltas: &fenwickAggregatedDeltas
    ) {
      didInsertFastPath = true
    }
    #if DEBUG
    let t_multiBlock_end = CFAbsoluteTimeGetCurrent()
    if docLen > 50000 {
      print("[updateEditorState] fastPath_InsertMultiBlock took \(String(format: "%.3f", (t_multiBlock_end - t_multiBlock_start)*1000))ms (matched=\(didInsertFastPath))")
    }
    #endif

    // Try split-paragraph fast path BEFORE computePartDiffs - this skips the O(N) diff
    // computation by doing targeted detection based on structural change patterns only
    #if DEBUG
    let t_splitParagraph_start = CFAbsoluteTimeGetCurrent()
    #endif
    if !didInsertFastPath, try fastPath_SplitParagraph(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection,
      fenwickAggregatedDeltas: &fenwickAggregatedDeltas
    ) {
      didInsertFastPath = true
    }
    #if DEBUG
    let t_splitParagraph_end = CFAbsoluteTimeGetCurrent()
    if docLen > 50000 {
      print("[updateEditorState] fastPath_SplitParagraph took \(String(format: "%.3f", (t_splitParagraph_end - t_splitParagraph_start)*1000))ms (matched=\(didInsertFastPath))")
    }
    #endif

    // Try single-block insert BEFORE computePartDiffs (since it doesn't need diffs)
    // This avoids O(N) diff computation for common operations like pressing Enter at end
    #if DEBUG
    let t_insertBlock_start = CFAbsoluteTimeGetCurrent()
    #endif
    if !didInsertFastPath, try fastPath_InsertBlock(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection,
      fenwickAggregatedDeltas: &fenwickAggregatedDeltas
    ) {
      didInsertFastPath = true
    }
    #if DEBUG
    let t_insertBlock_end = CFAbsoluteTimeGetCurrent()
    if docLen > 50000 {
      print("[updateEditorState] fastPath_InsertBlock took \(String(format: "%.3f", (t_insertBlock_end - t_insertBlock_start)*1000))ms (matched=\(didInsertFastPath))")
    }
    #endif

    // If no insert fast path matched, compute part diffs for other paths
    #if DEBUG
    let t_partDiffs_start = CFAbsoluteTimeGetCurrent()
    #endif
    if !didInsertFastPath {
      _ = computePartDiffs(editor: editor, prevState: currentEditorState, nextState: pendingEditorState)
    }
    #if DEBUG
    let t_partDiffs_end = CFAbsoluteTimeGetCurrent()
    if docLen > 50000 && !didInsertFastPath {
      print("[updateEditorState] computePartDiffs took \(String(format: "%.3f", (t_partDiffs_end - t_partDiffs_start)*1000))ms")
    }
    #endif

    #if DEBUG
    let t_dfs_start = CFAbsoluteTimeGetCurrent()
    #endif
    if didInsertFastPath {
      editor.invalidateDFSOrderCache()
      // Pre-compute DFS cache for subsequent edits (only for large documents)
      if editor.rangeCache.count > 1000 {
        _ = editor.cachedDFSOrderAndIndex()
      }
    }
    #if DEBUG
    let t_dfs_end = CFAbsoluteTimeGetCurrent()
    #endif
    // If insert-block consumed and central aggregation collected deltas, apply them once
    #if DEBUG
    let t_fenwick_start = CFAbsoluteTimeGetCurrent()
    #endif
    if !fenwickAggregatedDeltas.isEmpty {
      let (order, positions) = fenwickOrderAndIndex(editor: editor)
      let ranges = fenwickAggregatedDeltas.map { (k, d) in (startKey: k, endKeyExclusive: Optional<NodeKey>.none, delta: d) }
      applyIncrementalLocationShifts(rangeCache: &editor.rangeCache, ranges: ranges, order: order, indexOf: positions, diffScratch: &editor.locationShiftDiffScratch)
      fenwickAggregatedDeltas.removeAll(keepingCapacity: true)
    }
    #if DEBUG
    let t_fenwick_end = CFAbsoluteTimeGetCurrent()
    if docLen > 50000 && didInsertFastPath {
      print("[updateEditorState] post-fast-path: dfsCache=\(String(format: "%.3f", (t_dfs_end - t_dfs_start)*1000))ms fenwickApply=\(String(format: "%.3f", (t_fenwick_end - t_fenwick_start)*1000))ms allFastPaths=\(String(format: "%.3f", (t_insertBlock_end - t_fastPaths_start)*1000))ms")
    }
    #endif

    if didInsertFastPath { return }

    // (Removed) early structural delete pass: moved to end of updateEditorState to
    // ensure single-character edits are applied first and to avoid over-deletes.

    if try fastPath_ReorderChildren(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection
    ) {
      return
    }

    // Text-only and attribute-only fast paths
    // Prefer single-text fast path before central aggregation to avoid no-op gating during live edits
    if !didInsertFastPath, try fastPath_TextOnly(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection,
      fenwickAggregatedDeltas: &fenwickAggregatedDeltas
    ) {
      // If central aggregation is enabled, apply aggregated rebuild now
      if !fenwickAggregatedDeltas.isEmpty {
        let (order, positions) = fenwickOrderAndIndex(editor: editor)
        let ranges = fenwickAggregatedDeltas.map { (k, d) in (startKey: k, endKeyExclusive: Optional<NodeKey>.none, delta: d) }
        applyIncrementalLocationShifts(rangeCache: &editor.rangeCache, ranges: ranges, order: order, indexOf: positions, diffScratch: &editor.locationShiftDiffScratch)
      }
      return
    }

    // Central aggregation: collect both text and pre/post instructions, then apply once
    if true {
      var aggregatedInstructions: [Instruction] = []
      var aggregatedAffected: Set<NodeKey> = []
      var aggregatedLengthChanges: [(nodeKey: NodeKey, part: NodePart, delta: Int)] = []
      if !didInsertFastPath,
         let plan = try plan_TextOnly_Multi(currentEditorState: currentEditorState, pendingEditorState: pendingEditorState, editor: editor) {
        aggregatedInstructions.append(contentsOf: plan.instructions)
        aggregatedAffected.formUnion(plan.affected)
        aggregatedLengthChanges.append(contentsOf: plan.lengthChanges)
      }
      if let plan = try plan_PreamblePostambleOnly_Multi(currentEditorState: currentEditorState, pendingEditorState: pendingEditorState, editor: editor) {
        aggregatedInstructions.append(contentsOf: plan.instructions)
        aggregatedAffected.formUnion(plan.affected)
        aggregatedLengthChanges.append(contentsOf: plan.lengthChanges)
      }
      if !aggregatedInstructions.isEmpty {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let stats = applyInstructions(aggregatedInstructions, editor: editor)
        if !aggregatedLengthChanges.isEmpty {
          batchUpdateRangeCache(editor: editor, pendingEditorState: pendingEditorState, changes: aggregatedLengthChanges)
        }

        if !fenwickAggregatedDeltas.isEmpty {
          let (order, positions) = fenwickOrderAndIndex(editor: editor)
          let ranges = fenwickAggregatedDeltas.map { (k, d) in (startKey: k, endKeyExclusive: Optional<NodeKey>.none, delta: d) }
          applyIncrementalLocationShifts(rangeCache: &editor.rangeCache, ranges: ranges, order: order, indexOf: positions, diffScratch: &editor.locationShiftDiffScratch)
          fenwickAggregatedDeltas.removeAll(keepingCapacity: true)
        }
        // Update decorator caches/positions (parity with legacy). This captures
        // adds/removes and marks dirty decorators as .needsDecorating.
        reconcileDecoratorOpsForSubtree(
          ancestorKey: kRootNodeKey,
          prevState: currentEditorState,
          nextState: pendingEditorState,
          editor: editor
        )
        batchUpdateDecoratorPositions(editor: editor)
        CATransaction.commit()
        // One-time block attribute pass over affected keys (skip for pure text edits)
        if shouldApplyBlockAttributesPass(
          currentEditorState: currentEditorState,
          pendingEditorState: pendingEditorState,
          editor: editor,
          affectedKeys: aggregatedAffected,
          treatAllNodesAsDirty: false
        ) {
          applyBlockAttributesPass(
            editor: editor,
            pendingEditorState: pendingEditorState,
            affectedKeys: aggregatedAffected,
            treatAllNodesAsDirty: false
          )
        }
        // One-time selection reconcile
        if shouldReconcileSelection {
          let prevSelection = currentEditorState.selection
          let nextSelection = pendingEditorState.selection
          try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
        }
        if let metrics = editor.metricsContainer {
          let label: String = aggregatedLengthChanges.contains(where: { $0.part == .text }) && aggregatedLengthChanges.contains(where: { $0.part != .text }) ? "text+prepost-multi" : (aggregatedLengthChanges.contains(where: { $0.part == .text }) ? "text-only-multi" : "prepost-only-multi")
          let metric = ReconcilerMetric(duration: stats.duration, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0, treatedAllNodesAsDirty: false, pathLabel: label, planningDuration: 0, applyDuration: stats.duration, deleteCount: 0, insertCount: 0, setAttributesCount: 0, fixAttributesCount: 1)
          metrics.record(.reconcilerRun(metric))
        }
        return
      }
    }

    if !didInsertFastPath, try fastPath_TextOnly(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection,
      fenwickAggregatedDeltas: &fenwickAggregatedDeltas
    ) {
      // If central aggregation is enabled, apply aggregated rebuild now
      if !fenwickAggregatedDeltas.isEmpty {
        let (order, positions) = fenwickOrderAndIndex(editor: editor)
        let ranges = fenwickAggregatedDeltas.map { (k, d) in (startKey: k, endKeyExclusive: Optional<NodeKey>.none, delta: d) }
        applyIncrementalLocationShifts(rangeCache: &editor.rangeCache, ranges: ranges, order: order, indexOf: positions, diffScratch: &editor.locationShiftDiffScratch)
      }
      return
    }

    // Deferred structural delete: by this point, any single-character text edits have been
    // applied. If there are genuine structural removals remaining, handle them now. Skip if
    // there are still text deltas present.
    do {
      let diffs = computePartDiffs(editor: editor, prevState: currentEditorState, nextState: pendingEditorState)
      let hasTextDelta = diffs.values.contains { $0.textDelta != 0 }
      if !hasTextDelta, try fastPath_DeleteBlocks(
        currentEditorState: currentEditorState,
        pendingEditorState: pendingEditorState,
        editor: editor,
        shouldReconcileSelection: shouldReconcileSelection,
        fenwickAggregatedDeltas: &fenwickAggregatedDeltas
      ) { return }
    }

    // Coalesced contiguous multi-node replace (e.g., paste across multiple nodes)
    if try fastPath_ContiguousMultiNodeReplace(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection
    ) {
      return
    }

    // Fallback to optimized slow path for full rebuilds
    #if DEBUG
    print("[Reconciler] SLOW PATH FALLBACK: dirtyNodes=\(editor.dirtyNodes.count) dirtyType=\(editor.dirtyType)")
    #endif
    try optimizedSlowPath(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      shouldReconcileSelection: shouldReconcileSelection
    )
  }

  // No legacy delegation in optimized reconciler.

  // MARK: - Fresh document hydration (one-pass build)
  @MainActor
  private static func shouldHydrateFreshDocument(pendingState: EditorState, editor: Editor) -> Bool {
    guard let ts = reconcilerTextStorage(editor) else { return false }
    let storageEmpty = ts.length == 0
    guard storageEmpty else { return false }
    // Avoid hydrating an empty document: if the pending root has no children
    // OR the total subtree length is zero, skip. This prevents 0-length
    // replace cycles before the real content is restored.
    if let root = pendingState.getRootNode() {
      let keys = root.getChildrenKeys(fromLatest: false)
      if keys.isEmpty {
        return false
      }
      var total = 0
      for k in keys { total += subtreeTotalLength(nodeKey: k, state: pendingState) }
      if total == 0 {
        return false
      }
    } else {
      // No root yet → nothing to hydrate.
      return false
    }
    // Range cache has only root and it’s empty
    if editor.rangeCache.count == 1, let root = editor.rangeCache[kRootNodeKey] {
      if root.preambleLength == 0 && root.childrenLength == 0 && root.textLength == 0 && root.postambleLength == 0 {
        return true
      }
    }
    // Fallback: brand-new editor state (only root)
    // Final guard: only hydrate if computed subtree length above was non-zero
    return true
  }

  @MainActor
  private static func currentNodeCount(_ state: EditorState) -> Int { state.nodeMap.count }

  @MainActor
  internal static func hydrateFreshDocumentFully(pendingState: EditorState, editor: Editor) throws {
    guard let ts = reconcilerTextStorage(editor) else { return }
    let prevMode = ts.mode
    ts.mode = .controllerMode
    ts.beginEditing()
    // Build full attributed content for root's children
    let theme = editor.getTheme()
    let built = NSMutableAttributedString()
    if let root = pendingState.getRootNode() {
      for child in root.getChildrenKeys(fromLatest: false) {
        built.append(buildAttributedSubtree(nodeKey: child, state: pendingState, theme: theme))
      }
    }
    // Replace
    ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: built)
    ts.fixAttributes(in: NSRange(location: 0, length: built.length))
    ts.endEditing()
    ts.mode = prevMode

    // Recompute cache from root start 0
    _ = recomputeRangeCacheSubtree(nodeKey: kRootNodeKey, state: pendingState, startLocation: 0, editor: editor)
    editor.invalidateDFSOrderCache()
    // Reset Fenwick tree - all locations are now absolute, no deltas needed
    editor.resetFenwickTree(capacity: editor.rangeCache.count)

    // Apply block-level attributes for all nodes once
    applyBlockAttributesPass(editor: editor, pendingEditorState: pendingState, affectedKeys: nil, treatAllNodesAsDirty: true)

    // Ensure decorator caches/positions are initialized for a freshly hydrated document.
    // Use the editor's current state as the "previous" snapshot (often empty on first hydrate)
    // so that newly-present decorators transition to `.needsCreation` and acquire positions.
    reconcileDecoratorOpsForSubtree(
      ancestorKey: kRootNodeKey,
      prevState: editor.getEditorState(),
      nextState: pendingState,
      editor: editor
    )

    // Decorator positions align with new locations
    for (key, oldLoc) in ts.decoratorPositionCache {
      if let loc = editor.rangeCache[key]?.location, loc != oldLoc {
        ts.decoratorPositionCache[key] = loc
        ts.decoratorPositionCacheDirtyKeys.insert(key)
      }
    }
  }

  // MARK: - Optimized slow path fallback (no legacy)
  @MainActor
  private static func optimizedSlowPath(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool
  ) throws {
    guard let textStorage = reconcilerTextStorage(editor) else { return }
    // Capture prior state to detect no-op string rebuilds (e.g., decorator size-only changes)
    let prevString = textStorage.string
    let prevDecoratorPositions = textStorage.decoratorPositionCache
    let theme = editor.getTheme()
    let previousMode = textStorage.mode
    textStorage.mode = .controllerMode
    textStorage.beginEditing()
    // Rebuild full string from pending state (root children)
    let built = NSMutableAttributedString()
    if let root = pendingEditorState.getRootNode() {
      for child in root.getChildrenKeys(fromLatest: false) {
        built.append(buildAttributedSubtree(nodeKey: child, state: pendingEditorState, theme: theme))
      }
    }
    let fullRange = NSRange(location: 0, length: textStorage.string.lengthAsNSString())
    textStorage.replaceCharacters(in: fullRange, with: built)
    textStorage.fixAttributes(in: NSRange(location: 0, length: built.length))
    textStorage.endEditing()
    // Apply block-level attributes for all nodes (parity with legacy slow path)
    applyBlockAttributesPass(editor: editor, pendingEditorState: pendingEditorState, affectedKeys: nil, treatAllNodesAsDirty: true)
    textStorage.mode = previousMode

    // Recompute entire range cache locations and prune stale entries
    _ = recomputeRangeCacheSubtree(nodeKey: kRootNodeKey, state: pendingEditorState, startLocation: 0, editor: editor)
    pruneRangeCacheGlobally(nextState: pendingEditorState, editor: editor)
    // Reset Fenwick tree - all locations are now absolute, no deltas needed
    editor.resetFenwickTree(capacity: editor.rangeCache.count)

    // Reconcile decorators for the entire document (add/remove/decorate + positions)
    reconcileDecoratorOpsForSubtree(ancestorKey: kRootNodeKey, prevState: currentEditorState, nextState: pendingEditorState, editor: editor)

    // Pre-compute DFS cache AFTER decorator reconciliation so subsequent edits have cached positions
    #if DEBUG
    if editor.rangeCache.count > 100 {
      print("[optimizedSlowPath] Pre-computing DFS cache for \(editor.rangeCache.count) nodes")
    }
    #endif
    _ = editor.cachedDFSOrderAndIndex()

    // If the rebuilt string is identical, preserve existing decorator positions.
    // Size-only updates must not perturb position cache.
    if textStorage.string == prevString {
      textStorage.decoratorPositionCache = prevDecoratorPositions
    }

    // Selection reconcile (always, after a text change)
    if shouldReconcileSelection {
      let prevSelection = currentEditorState.selection
      let nextSelection = pendingEditorState.selection
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

    if let metrics = editor.metricsContainer {
      // Approximate wall time for slow path as pure apply time for the full replace
      // (We don't separate planning here.)
      // Note: applyDuration was measured above implicitly by the editing block; recompute here conservatively
      let metric = ReconcilerMetric(
        duration: 0, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
        treatedAllNodesAsDirty: true, pathLabel: "slow")
      metrics.record(.reconcilerRun(metric))
    }
  }

  // MARK: - Fast path: single TextNode content change
  @MainActor
  private static func fastPath_TextOnly(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    @inline(__always)
    func debugSkip(_ message: String) {
      #if DEBUG
      print("[fastPath_TextOnly] SKIP: \(message)")
      #endif
    }

    // Find a single TextNode whose TEXT CONTENT changed. Parents may be dirty due to
    // block attributes; ignore those. Only operate when exactly one TextNode's string
    // actually differs between prev and next states.
    #if DEBUG
    if editor.dirtyNodes.count <= 10 {
      for key in editor.dirtyNodes.keys {
        let prevNode = currentEditorState.nodeMap[key]
        let nextNode = pendingEditorState.nodeMap[key]
        let prevType = prevNode.map { String(describing: type(of: $0)) } ?? "nil"
        let nextType = nextNode.map { String(describing: type(of: $0)) } ?? "nil"
        let prevText = (prevNode as? TextNode)?.getTextPart(fromLatest: false) ?? "<n/a>"
        let nextText = (nextNode as? TextNode)?.getTextPart(fromLatest: false) ?? "<n/a>"
        let prevTextTrunc = prevText.count > 30 ? String(prevText.prefix(30)) + "..." : prevText
        let nextTextTrunc = nextText.count > 30 ? String(nextText.prefix(30)) + "..." : nextText
        print("[fastPath_TextOnly] dirtyKey=\(key) prevType=\(prevType) nextType=\(nextType) prevText='\(prevTextTrunc)' nextText='\(nextTextTrunc)'")
      }
    }
    #endif
    let changedTextKeys: [NodeKey] = editor.dirtyNodes.keys.compactMap { key in
      guard let prev = currentEditorState.nodeMap[key] as? TextNode,
            let next = pendingEditorState.nodeMap[key] as? TextNode else { return nil }
      return (prev.getTextPart(fromLatest: false) != next.getTextPart(fromLatest: false)) ? key : nil
    }
    if changedTextKeys.count != 1 {
      debugSkip("changedTextKeys.count=\(changedTextKeys.count) dirtyNodes=\(editor.dirtyNodes.count)")
      return false
    }
    guard let dirtyKey = changedTextKeys.first else {
      debugSkip("missing dirtyKey")
      return false
    }
    guard let prevNode = currentEditorState.nodeMap[dirtyKey] as? TextNode else {
      debugSkip("prevNode missing key=\(dirtyKey)")
      return false
    }
    guard let nextNode = pendingEditorState.nodeMap[dirtyKey] as? TextNode else {
      debugSkip("nextNode missing key=\(dirtyKey)")
      return false
    }
    guard let prevRange = editor.rangeCache[dirtyKey] else {
      debugSkip("prevRange missing key=\(dirtyKey)")
      return false
    }

    // Parent identity should remain stable for the fast path
    if prevNode.parent != nextNode.parent {
      debugSkip("parent changed key=\(dirtyKey) prev=\(String(describing: prevNode.parent)) next=\(String(describing: nextNode.parent))")
      return false
    }

    // Ensure no structural changes are mixed in. The text-only fast path cannot safely handle
    // operations that also add/remove/reorder sibling nodes (e.g., paragraph merges, decorator
    // deletes that coalesce adjacent TextNodes, etc). In those cases, fall back to a slower
    // path that rebuilds correctly.
    var allowedDirtyKeys: Set<NodeKey> = [dirtyKey]
    for p in nextNode.getParents() { allowedDirtyKeys.insert(p.getKey()) }
    for k in editor.dirtyNodes.keys where !allowedDirtyKeys.contains(k) {
      debugSkip("extra dirty key=\(k) (structural or non-local edit)")
      return false
    }
    for k in allowedDirtyKeys where k != dirtyKey {
      guard let prevAny = currentEditorState.nodeMap[k], let nextAny = pendingEditorState.nodeMap[k] else {
        debugSkip("missing node for allowed dirty key=\(k)")
        return false
      }
      if let prevEl = prevAny as? ElementNode {
        guard let nextEl = nextAny as? ElementNode else {
          debugSkip("type changed for allowed dirty key=\(k)")
          return false
        }
        if prevEl.getChildrenKeys(fromLatest: false) != nextEl.getChildrenKeys(fromLatest: false) {
          debugSkip("children changed for allowed dirty key=\(k)")
          return false
        }
      }
    }

    let newText = nextNode.getTextPart(fromLatest: false)
    let oldTextLen = prevRange.textLength
    let newTextLen = newText.lengthAsNSString()
    if oldTextLen == newTextLen {
      // Attribute-only fast path if underlying string content is identical
      guard let textStorage = reconcilerTextStorage(editor) else {
        debugSkip("textStorage nil (attr-only)")
        return false
      }
      let textRange = NSRange(
        location: prevRange.location + prevRange.preambleLength + prevRange.childrenLength,
        length: oldTextLen)
      if textRange.upperBound <= textStorage.length {
        let currentText = textStorage.attributedSubstring(from: textRange).string
        if currentText == newText {
          let attributes = AttributeUtils.attributedStringStyles(
            from: nextNode, state: pendingEditorState, theme: editor.getTheme())
          let previousMode = textStorage.mode
          textStorage.mode = .controllerMode
          let t0 = CFAbsoluteTimeGetCurrent()
          textStorage.beginEditing()
          textStorage.setAttributes(attributes, range: textRange)
          textStorage.fixAttributes(in: textRange)
          textStorage.endEditing()
          textStorage.mode = previousMode
          let applyDur = CFAbsoluteTimeGetCurrent() - t0

          // No length delta, but re-apply decorator positions for safety
          for (key, oldLoc) in textStorage.decoratorPositionCache {
            if let loc = editor.rangeCache[key]?.location, loc != oldLoc {
              textStorage.decoratorPositionCache[key] = loc
              textStorage.decoratorPositionCacheDirtyKeys.insert(key)
            }
          }

          let prevSelection = currentEditorState.selection
          let nextSelection = pendingEditorState.selection
          var selectionsAreDifferent = false
          if let nextSelection, let prevSelection {
            selectionsAreDifferent = !nextSelection.isSelection(prevSelection)
          }
          let needsUpdate = editor.dirtyType != .noDirtyNodes
          if shouldReconcileSelection
            && (needsUpdate || nextSelection == nil || selectionsAreDifferent)
          {
            try reconcileSelection(
              prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
          }
          if let metrics = editor.metricsContainer {
            let metric = ReconcilerMetric(
              duration: applyDur, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
              treatedAllNodesAsDirty: false, pathLabel: "attr-only", planningDuration: 0,
              applyDuration: applyDur, deleteCount: 0, insertCount: 0, setAttributesCount: 1, fixAttributesCount: 1)
            metrics.record(.reconcilerRun(metric))
          }
          return true
        }
      }
      // Content changed but length kept → try pre/post part deltas for element siblings, else fallback
      debugSkip("length unchanged but content differs key=\(dirtyKey)")
      return false
    }

    // Minimal replace algorithm (LCP/LCS): replace only the changed span
    guard let textStorage = reconcilerTextStorage(editor) else {
      debugSkip("textStorage nil (min-replace)")
      return false
    }
    let textStart = prevRange.location + prevRange.preambleLength + prevRange.childrenLength
    let textRange = NSRange(location: textStart, length: oldTextLen)
    guard textRange.upperBound <= textStorage.length else {
      debugSkip(
        "textRange OOB key=\(dirtyKey) textRange=\(textRange) ts.length=\(textStorage.length) prevRange=(loc=\(prevRange.location) pre=\(prevRange.preambleLength) children=\(prevRange.childrenLength) text=\(prevRange.textLength))"
      )
      return false
    }

    let oldStr = (textStorage.attributedSubstring(from: textRange).string as NSString)
    let newStr = (newText as NSString)
    let oldLen = oldStr.length
    let newLen = newStr.length
    let maxPref = min(oldLen, newLen)
    var lcp = 0
    while lcp < maxPref && oldStr.character(at: lcp) == newStr.character(at: lcp) { lcp += 1 }
    let oldRem = oldLen - lcp
    let newRem = newLen - lcp
    let maxSuf = min(oldRem, newRem)
    var lcs = 0
    while lcs < maxSuf && oldStr.character(at: oldLen - 1 - lcs) == newStr.character(at: newLen - 1 - lcs) { lcs += 1 }

    let changedOldLen = max(0, oldRem - lcs)
    let changedNewLen = max(0, newRem - lcs)
    let replaceLoc = textStart + lcp
    let replaceRange = NSRange(location: replaceLoc, length: changedOldLen)

    // Build styled replacement for changed segment
    let theme = editor.getTheme()
    let state = pendingEditorState
    let newSegment = changedNewLen > 0 ? newStr.substring(with: NSRange(location: lcp, length: changedNewLen)) : ""
    let styled = AttributeUtils.attributedStringByAddingStyles(NSAttributedString(string: newSegment), from: nextNode, state: state, theme: theme)

    let prevModeTS = textStorage.mode
    textStorage.mode = .controllerMode
    let t0 = CFAbsoluteTimeGetCurrent()
    textStorage.beginEditing()
    let t1 = CFAbsoluteTimeGetCurrent()
    if styled.length == 0 && changedOldLen > 0 {
      // Pure deletion is cheaper and avoids attribute churn.
      textStorage.deleteCharacters(in: replaceRange)
      // Fix attributes around the deletion boundary conservatively (1 char before, 0 after)
      let fixStart = max(0, replaceLoc - 1)
      let fixLen = min(2, (textStorage.length - fixStart))
      if fixLen > 0 { textStorage.fixAttributes(in: NSRange(location: fixStart, length: fixLen)) }
    } else {
      textStorage.replaceCharacters(in: replaceRange, with: styled)
      let fixLen = max(changedOldLen, styled.length)
      let fixCandidate = NSRange(location: replaceLoc, length: fixLen)
      let safeFix = NSIntersectionRange(
        fixCandidate,
        NSRange(location: 0, length: textStorage.length)
      )
      if safeFix.length > 0 {
        textStorage.fixAttributes(in: safeFix)
      }
    }
    let t2 = CFAbsoluteTimeGetCurrent()
    textStorage.endEditing()
    let t3 = CFAbsoluteTimeGetCurrent()
    textStorage.mode = prevModeTS
    let applyDur = t3 - t0
    #if DEBUG
    if textStorage.length > 50000 {
      print("[fastPath_TextOnly] TextKit timing: beginEdit=\(String(format: "%.3f", (t1-t0)*1000))ms replace+fix=\(String(format: "%.3f", (t2-t1)*1000))ms endEdit=\(String(format: "%.3f", (t3-t2)*1000))ms total=\(String(format: "%.3f", applyDur*1000))ms")
    }
    #endif

    // Update cache lengths and ancestors
    let delta = newLen - oldLen
    if var item = editor.rangeCache[dirtyKey] { item.textLength = newLen; editor.rangeCache[dirtyKey] = item }
    if delta != 0, let node = pendingEditorState.nodeMap[dirtyKey] {
      var parent = node.getParent()
      while let p = parent {
        let pk = p.getKey()
        if var it = editor.rangeCache[pk] { it.childrenLength += delta; editor.rangeCache[pk] = it }
        parent = p.getParent()
      }
    }

    // Location shifts
    // OPTIMIZATION: Use O(log N) Fenwick tree update instead of O(N) location shifting.
    // When Fenwick is enabled, we add a delta to the tree that affects all nodes after the edited one.
    // When Fenwick is disabled (or editing the last node), we skip or fall back to the old approach.
    #if DEBUG
    let locShiftStart = CFAbsoluteTimeGetCurrent()
    #endif

    // Try to use cached DFS position from RangeCacheItem first (O(1))
    // Only compute global order if position is not cached
    var nodePosition = editor.rangeCache[dirtyKey]?.dfsPosition ?? 0
    var totalNodes = editor.rangeCache.count
    var needsGlobalOrder = false

    if nodePosition == 0 && delta != 0 {
      // DFS position not cached - need to compute global order
      needsGlobalOrder = true
      let (order, positions) = fenwickOrderAndIndex(editor: editor)
      nodePosition = positions[dirtyKey] ?? 0
      totalNodes = order.count
    }

    let isLastNode = nodePosition == totalNodes

    if delta != 0 && !isLastNode {
      if editor.useFenwickLocations {
        // O(log N) Fenwick tree update: add delta for all nodes after this one
        editor.ensureFenwickCapacity(totalNodes)
        editor.locationFenwickTree.add(nodePosition + 1, delta)
        #if DEBUG
        if totalNodes > 100 {
          print("[fastPath_TextOnly] Fenwick update: pos=\(nodePosition + 1) delta=\(delta) treeSize=\(editor.locationFenwickTree.size) cachedPos=\(!needsGlobalOrder)")
        }
        #endif
      } else {
        // Legacy O(N) path - requires global order
        if !needsGlobalOrder {
          let (order, positions) = fenwickOrderAndIndex(editor: editor)
          #if DEBUG
          if order.count > 100 {
            print("[fastPath_TextOnly] LocShift (legacy): key=\(dirtyKey) pos=\(nodePosition)/\(order.count) delta=\(delta)")
          }
          #endif
          let ranges = [(startKey: dirtyKey, endKeyExclusive: Optional<NodeKey>.none, delta: delta)]
          applyIncrementalLocationShifts(rangeCache: &editor.rangeCache, ranges: ranges, order: order, indexOf: positions, diffScratch: &editor.locationShiftDiffScratch)
        } else {
          // Already have the order from above
          let (order, positions) = fenwickOrderAndIndex(editor: editor)
          let ranges = [(startKey: dirtyKey, endKeyExclusive: Optional<NodeKey>.none, delta: delta)]
          applyIncrementalLocationShifts(rangeCache: &editor.rangeCache, ranges: ranges, order: order, indexOf: positions, diffScratch: &editor.locationShiftDiffScratch)
        }
      }
    }
    #if DEBUG
    let locShiftEnd = CFAbsoluteTimeGetCurrent()
    if textStorage.length > 50000 {
      print("[fastPath_TextOnly] LocShift timing: \(String(format: "%.3f", (locShiftEnd-locShiftStart)*1000))ms fenwick=\(editor.useFenwickLocations) cachedPos=\(!needsGlobalOrder)")
    }
    #endif

    // Update decorator positions
    // When Fenwick is enabled, compute actual locations using the Fenwick tree
    if let ts = reconcilerTextStorage(editor) {
      for (key, oldLoc) in ts.decoratorPositionCache {
        let loc: Int?
        if editor.useFenwickLocations {
          // Use Fenwick-aware location lookup with cached DFS position from RangeCacheItem
          if let item = editor.rangeCache[key], item.dfsPosition > 0 {
            loc = editor.actualLocation(for: key, dfsPosition: item.dfsPosition)
          } else {
            loc = editor.actualLocation(for: key)
          }
        } else {
          loc = editor.rangeCache[key]?.location
        }
        if let loc, loc != oldLoc {
          ts.decoratorPositionCache[key] = loc
          ts.decoratorPositionCacheDirtyKeys.insert(key)
        }
      }
    }

    // Headless/read-only contexts still need decorator cache state updates for parity
    // (e.g., dirty -> needsDecorating) even when taking the text-only path.
    if isReadOnlyFrontendContext(editor) {
      reconcileDecoratorOpsForSubtree(
        ancestorKey: kRootNodeKey,
        prevState: currentEditorState,
        nextState: pendingEditorState,
        editor: editor
      )
    }

    // Selection reconcile
    #if DEBUG
    let selStart = CFAbsoluteTimeGetCurrent()
    #endif
    if shouldReconcileSelection {
      let prevSelection = currentEditorState.selection
      let nextSelection = pendingEditorState.selection
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }
    #if DEBUG
    let selEnd = CFAbsoluteTimeGetCurrent()
    if textStorage.length > 50000 {
      print("[fastPath_TextOnly] Selection timing: \(String(format: "%.3f", (selEnd-selStart)*1000))ms total_in_fastPath=\(String(format: "%.3f", (selEnd-t0)*1000))ms")
    }
    #endif

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(
        duration: applyDur, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
        treatedAllNodesAsDirty: false, pathLabel: "text-only-min-replace", planningDuration: 0,
        applyDuration: applyDur, deleteCount: 0, insertCount: 0, setAttributesCount: 0, fixAttributesCount: 1)
      metrics.record(.reconcilerRun(metric))
    }
    return true
  }

  // MARK: - Fast path: multi-block insert (K >= 2 contiguous children)
  //
  // This fast path handles large paste operations where multiple paragraphs are inserted.
  // Instead of rebuilding the entire document (O(N) memory/time), it only builds the
  // attributed string for the inserted content (O(K) where K = inserted blocks).
  //
  // Detection: Parent element where nextChildren.count == prevChildren.count + K (K >= 2),
  // no removals, and the K added keys are contiguous in nextChildren.
  @MainActor
  private static func fastPath_InsertMultiBlock(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    if editor.suppressInsertFastPathOnce { return false }
    if isReadOnlyFrontendContext(editor) { return false }

    // Find a parent Element whose children gained K >= 2 children (no removals)
    let dirtyParents = editor.dirtyNodes.keys.compactMap { key -> (NodeKey, ElementNode, ElementNode)? in
      guard let prev = currentEditorState.nodeMap[key] as? ElementNode,
            let next = pendingEditorState.nodeMap[key] as? ElementNode else { return nil }
      return (key, prev, next)
    }


    // Look for a parent with K >= 2 added children
    guard let cand = dirtyParents.first(where: { (parentKey, prev, next) in
      let prevChildren = prev.getChildrenKeys(fromLatest: false)
      let nextChildren = next.getChildrenKeys(fromLatest: false)
      let addedCount = nextChildren.count - prevChildren.count
      if addedCount < 2 { return false }  // Need at least 2 for multi-block
      let prevSet = Set(prevChildren)
      let nextSet = Set(nextChildren)
      let removed = prevSet.subtracting(nextSet)
      return removed.isEmpty
    }) else { return false }

    let (parentKey, prevParent, nextParent) = cand
    let prevChildren = prevParent.getChildrenKeys(fromLatest: false)
    let nextChildren = nextParent.getChildrenKeys(fromLatest: false)
    let prevSet = Set(prevChildren)
    let addedKeys = nextChildren.filter { !prevSet.contains($0) }
    let addedCount = addedKeys.count

    // Verify added keys are contiguous in nextChildren
    guard let firstAddedIdx = nextChildren.firstIndex(of: addedKeys[0]) else { return false }
    for (i, key) in addedKeys.enumerated() {
      if nextChildren.indices.contains(firstAddedIdx + i) {
        if nextChildren[firstAddedIdx + i] != key { return false }  // Not contiguous
      } else {
        return false
      }
    }

    // Verify existing children maintain their relative order (no reordering)
    let nextWithoutAdded = nextChildren.filter { prevSet.contains($0) }
    if nextWithoutAdded != prevChildren { return false }

    // Note: We skip the text delta and dirty nodes checks for multi-block insert.
    // Paste operations mark many nodes dirty (new paragraphs, their text nodes, and
    // the existing paragraph at the insertion point). The structural invariants we've
    // verified are sufficient: K >= 2 new contiguous children, no removals, no reordering.

    // Compute insertion location
    guard let parentPrevRange = editor.rangeCache[parentKey] else { return false }
    let childrenStart = parentPrevRange.location + parentPrevRange.preambleLength

    // Sum lengths of siblings before the insertion point
    var acc = 0
    for k in nextChildren.prefix(firstAddedIdx) {
      if let r = editor.rangeCache[k]?.range {
        acc += r.length
      } else {
        acc += subtreeTotalLength(nodeKey: k, state: currentEditorState)
      }
    }
    let insertLoc = childrenStart + acc

    // Build attributed string for ALL inserted blocks (not the whole document!)
    let theme = editor.getTheme()
    let builtInserted = NSMutableAttributedString()
    for addedKey in addedKeys {
      builtInserted.append(buildAttributedSubtree(nodeKey: addedKey, state: pendingEditorState, theme: theme))
    }

    // Handle postamble of previous sibling if needed
    var instructions: [Instruction] = []
    var deleteOldPostRange: NSRange? = nil
    var combinedInsertPrefix: NSAttributedString? = nil
    var postambleDelta = 0

    if firstAddedIdx > 0 {
      let prevSiblingKey = nextChildren[firstAddedIdx - 1]
      if let prevSiblingRange = editor.rangeCache[prevSiblingKey],
         let prevSiblingNext = pendingEditorState.nodeMap[prevSiblingKey] {
        let oldPost = prevSiblingRange.postambleLength
        let newPost = prevSiblingNext.getPostamble().lengthAsNSString()
        if newPost != oldPost {
          let postLoc = prevSiblingRange.location + prevSiblingRange.preambleLength +
                        prevSiblingRange.childrenLength + prevSiblingRange.textLength
          if oldPost > 0 { deleteOldPostRange = NSRange(location: postLoc, length: oldPost) }
          let postAttrStr = AttributeUtils.attributedStringByAddingStyles(
            NSAttributedString(string: prevSiblingNext.getPostamble()),
            from: prevSiblingNext, state: pendingEditorState, theme: theme)
          if postAttrStr.length > 0 { combinedInsertPrefix = postAttrStr }
          postambleDelta = newPost - oldPost
          if var it = editor.rangeCache[prevSiblingKey] {
            it.postambleLength = newPost
            editor.rangeCache[prevSiblingKey] = it
          }
        }
      }
    }

    let effectiveInsertLoc = deleteOldPostRange?.location ?? insertLoc
    if let del = deleteOldPostRange { instructions.append(.delete(range: del)) }

    // Combine postamble prefix with inserted content
    if builtInserted.length > 0 {
      if let prefix = combinedInsertPrefix {
        let combined = NSMutableAttributedString(attributedString: prefix)
        combined.append(builtInserted)
        instructions.append(.insert(location: effectiveInsertLoc, attrString: combined))
      } else {
        instructions.append(.insert(location: effectiveInsertLoc, attrString: builtInserted))
      }
    }

    if instructions.isEmpty { return false }

    // Update range cache incrementally
    let prefixLen = combinedInsertPrefix?.length ?? 0
    let insertLen = prefixLen + builtInserted.length
    let deleteLen = deleteOldPostRange?.length ?? 0
    let delta = insertLen - deleteLen

    if delta != 0 {
      // Propagate childrenLength delta to parent and ancestors
      var cursor: NodeKey? = parentKey
      while let k = cursor {
        if var it = editor.rangeCache[k] {
          it.childrenLength &+= delta
          editor.rangeCache[k] = it
        }
        cursor = pendingEditorState.nodeMap[k]?.parent
      }

      // For inserts at the END of the document (most common paste scenario),
      // we can skip the O(N) location shifting since there are no nodes after
      // the insertion point that need their locations updated.
      let isInsertAtEnd = (firstAddedIdx + addedCount) == nextChildren.count

      if !isInsertAtEnd {
        // Shift locations for nodes after insertion point
        @inline(__always)
        func lastDescendantKey(state: EditorState, root: NodeKey) -> NodeKey {
          var current = root
          while let el = state.nodeMap[current] as? ElementNode {
            let children = el.getChildrenKeys(fromLatest: false)
            guard let last = children.last else { break }
            current = last
          }
          return current
        }

        let shiftStartKey: NodeKey = {
          if firstAddedIdx == 0 { return parentKey }
          let prevSiblingKey = nextChildren[firstAddedIdx - 1]
          return lastDescendantKey(state: pendingEditorState, root: prevSiblingKey)
        }()

        let (order, positions) = fenwickOrderAndIndex(editor: editor)
        applyIncrementalLocationShifts(
          rangeCache: &editor.rangeCache,
          ranges: [(startKey: shiftStartKey, endKeyExclusive: Optional<NodeKey>.none, delta: delta)],
          order: order,
          indexOf: positions,
          diffScratch: &editor.locationShiftDiffScratch
        )
      }
    }

    // Recompute range cache for all inserted subtrees
    var currentLoc = effectiveInsertLoc + prefixLen
    for addedKey in addedKeys {
      _ = recomputeRangeCacheSubtree(
        nodeKey: addedKey,
        state: pendingEditorState,
        startLocation: currentLoc,
        editor: editor
      )
      if let range = editor.rangeCache[addedKey]?.range {
        currentLoc += range.length
      }
    }

    // Apply instructions (insert the content)
    let stats = applyInstructions(instructions, editor: editor, fixAttributesEnabled: true)

    // Reconcile decorators for the parent subtree
    reconcileDecoratorOpsForSubtree(
      ancestorKey: parentKey,
      prevState: currentEditorState,
      nextState: pendingEditorState,
      editor: editor
    )

    // Block attributes only for inserted nodes (not the whole document)
    applyBlockAttributesPass(
      editor: editor,
      pendingEditorState: pendingEditorState,
      affectedKeys: Set(addedKeys),
      treatAllNodesAsDirty: false
    )

    // Selection reconcile
    if shouldReconcileSelection {
      let prevSelection = currentEditorState.selection
      let nextSelection = pendingEditorState.selection
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(
        duration: stats.duration, dirtyNodes: editor.dirtyNodes.count, rangesAdded: addedCount, rangesDeleted: 0,
        treatedAllNodesAsDirty: false, pathLabel: "insert-multi-block-\(addedCount)", planningDuration: 0,
        applyDuration: stats.duration)
      metrics.record(.reconcilerRun(metric))
    }

    // Assign stable nodeIndex for Fenwick-backed locations
    for addedKey in addedKeys {
      if var item = editor.rangeCache[addedKey] {
        if item.nodeIndex == 0 {
          item.nodeIndex = editor.nextFenwickNodeIndex
          editor.nextFenwickNodeIndex += 1
          editor.rangeCache[addedKey] = item
        }
      }
    }

    return true
  }

  // MARK: - Fast path: single block insert (K == 1)
  @MainActor
  private static func fastPath_InsertBlock(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    if editor.suppressInsertFastPathOnce {
      editor.suppressInsertFastPathOnce = false
      return false
    }
    // Read-only contexts (no real TextView) can have different layout/spacing ordering.
    // Keep optimized active but skip this structural fast path in read-only to preserve parity.
    if isReadOnlyFrontendContext(editor) { return false }

    // Find a parent Element whose children gained exactly one child (no removals)
    // and no other structural deltas.
    let dirtyParents = editor.dirtyNodes.keys.compactMap { key -> (NodeKey, ElementNode, ElementNode)? in
      guard let prev = currentEditorState.nodeMap[key] as? ElementNode,
            let next = pendingEditorState.nodeMap[key] as? ElementNode else { return nil }
      return (key, prev, next)
    }
    guard let cand = dirtyParents.first(where: { (parentKey, prev, next) in
      let prevChildren = prev.getChildrenKeys(fromLatest: false)
      let nextChildren = next.getChildrenKeys(fromLatest: false)
      if nextChildren.count != prevChildren.count + 1 { return false }
      let prevSet = Set(prevChildren)
      let nextSet = Set(nextChildren)
      let added = nextSet.subtracting(prevSet)
      let removed = prevSet.subtracting(nextSet)
      return added.count == 1 && removed.isEmpty
    }) else { return false }

    let (parentKey, prevParent, nextParent) = cand

    // Safety gate: do NOT treat this as a structural delete if any descendant
    // TextNode under this parent has a text delta in this update (e.g. a single
    // character backspace). This prevents whole‑block deletes during live typing.
    // OPTIMIZATION: Only check DIRTY nodes that are descendants of parentKey (O(D) where D = # dirty nodes)
    // rather than collecting ALL descendants (O(N)) and then filtering.
    do {
      // Check dirty nodes for text deltas - only those that are descendants of parentKey
      for (key, _) in editor.dirtyNodes {
        // Skip nodes without previous range cache (new nodes can't have negative deltas)
        guard let _ = editor.rangeCache[key],
              let prevText = currentEditorState.nodeMap[key] as? TextNode,
              let nextText = pendingEditorState.nodeMap[key] as? TextNode else { continue }

        // Check if this node is a descendant of parentKey by walking up parent chain
        var parentCheck = nextText.parent
        var isDescendant = false
        while let pk = parentCheck {
          if pk == parentKey {
            isDescendant = true
            break
          }
          parentCheck = pendingEditorState.nodeMap[pk]?.parent
        }
        if !isDescendant { continue }

        let prevLen = prevText.getTextPart(fromLatest: false).lengthAsNSString()
        let nextLen = nextText.getTextPart(fromLatest: false).lengthAsNSString()
        if nextLen != prevLen {
          // Text delta found - bail out
          #if DEBUG
          if editor.rangeCache.count > 100 {
            print("[fastPath_InsertBlock] TEXT_DELTA: key=\(key) prevLen=\(prevLen) nextLen=\(nextLen) delta=\(nextLen - prevLen)")
          }
          #endif
          return false
        }
      }
    }
    let prevChildren = prevParent.getChildrenKeys(fromLatest: false)
    let nextChildren = nextParent.getChildrenKeys(fromLatest: false)
    let prevSet = Set(prevChildren)
    let addedKey = Set(nextChildren).subtracting(prevSet).first!

    // Ensure the insertion does not also reorder existing siblings. The fast path assumes
    // relative order of pre-existing children is unchanged.
    let nextWithoutAdded = nextChildren.filter { $0 != addedKey }
    if nextWithoutAdded != prevChildren { return false }

    // Only proceed if the update is limited to this structural insertion and its affected subtree.
    // This makes it safe for the caller to early-return after the fast path is applied.
    // OPTIMIZATION: When parentKey is root, skip the subtree collection (all keys are allowed)
    if parentKey != kRootNodeKey {
      func collectSubtree(state: EditorState, root: NodeKey) -> Set<NodeKey> {
        guard let node = state.nodeMap[root] else { return [] }
        var out: Set<NodeKey> = [root]
        if let el = node as? ElementNode {
          for c in el.getChildrenKeys(fromLatest: false) {
            out.formUnion(collectSubtree(state: state, root: c))
          }
        }
        return out
      }

      var allowedDirtyKeys = collectSubtree(state: pendingEditorState, root: parentKey)
      if let nextParentNode = pendingEditorState.nodeMap[parentKey] {
        for p in nextParentNode.getParents() { allowedDirtyKeys.insert(p.getKey()) }
      }

      for k in editor.dirtyNodes.keys where !allowedDirtyKeys.contains(k) {
        return false
      }
    }

    // Compute insert index in nextChildren
    guard let insertIndex = nextChildren.firstIndex(of: addedKey) else { return false }
    guard let parentPrevRange = editor.rangeCache[parentKey] else { return false }
    let childrenStart = parentPrevRange.location + parentPrevRange.preambleLength
    // Sum lengths of previous siblings that existed before
    // OPTIMIZATION: When inserting at the end (common case), use parent's childrenLength directly
    // instead of iterating through all previous siblings (O(N) -> O(1))
    let acc: Int
    if insertIndex == prevChildren.count {
      // Inserting at end - parent's childrenLength already has sum of all existing children
      acc = parentPrevRange.childrenLength
    } else if insertIndex == 0 {
      // Inserting at start - no previous siblings
      acc = 0
    } else {
      // Inserting in middle - sum previous siblings (O(K) where K = insertIndex)
      var sum = 0
      for k in nextChildren.prefix(insertIndex) {
        if let r = editor.rangeCache[k]?.range {
          sum += r.length
        } else {
          sum += subtreeTotalLength(nodeKey: k, state: currentEditorState)
        }
      }
      acc = sum
    }
    let insertLoc = childrenStart + acc
    let theme = editor.getTheme()
    var instructions: [Instruction] = []

    // If inserting not at index 0, the previous sibling's postamble may change (e.g., add a newline).
    // We replace old postamble (if any) and insert the new postamble + the new block in a single combined insert.
    var totalShift = 0
    var combinedInsertPrefix: NSAttributedString? = nil
    var deleteOldPostRange: NSRange? = nil
    if insertIndex > 0 {
      let prevSiblingKey = nextChildren[insertIndex - 1]
      if let prevSiblingRange = editor.rangeCache[prevSiblingKey],
         let prevSiblingNext = pendingEditorState.nodeMap[prevSiblingKey] {
        let oldPost = prevSiblingRange.postambleLength
        let newPost = prevSiblingNext.getPostamble().lengthAsNSString()
        if newPost != oldPost {
          let postLoc = prevSiblingRange.location + prevSiblingRange.preambleLength + prevSiblingRange.childrenLength + prevSiblingRange.textLength
          // Will delete old postamble (if present) and then insert (newPost + new block) at postLoc
          if oldPost > 0 { deleteOldPostRange = NSRange(location: postLoc, length: oldPost) }
          let postAttrStr = AttributeUtils.attributedStringByAddingStyles(NSAttributedString(string: prevSiblingNext.getPostamble()), from: prevSiblingNext, state: pendingEditorState, theme: theme)
          if postAttrStr.length > 0 { combinedInsertPrefix = postAttrStr }
          // Update cache + ancestor childrenLength and account for location shift for following content
          let deltaPost = newPost - oldPost
          totalShift += deltaPost
          if var it = editor.rangeCache[prevSiblingKey] { it.postambleLength = newPost; editor.rangeCache[prevSiblingKey] = it }
          // insertion happens at original postLoc; combinedInsertPrefix accounts for the new postamble content
        }
      }
    }

    let effectiveInsertLoc = deleteOldPostRange?.location ?? insertLoc
    let attr = buildAttributedSubtree(nodeKey: addedKey, state: pendingEditorState, theme: theme)
    if let del = deleteOldPostRange { instructions.append(.delete(range: del)) }
    // Insert if we have content (attr) or a prefix (combinedInsertPrefix) to insert
    let hasContentToInsert = attr.length > 0 || combinedInsertPrefix != nil
    if hasContentToInsert {
      if let prefix = combinedInsertPrefix {
        let combined = NSMutableAttributedString(attributedString: prefix)
        combined.append(attr)
        instructions.append(.insert(location: effectiveInsertLoc, attrString: combined))
      } else {
        instructions.append(.insert(location: effectiveInsertLoc, attrString: attr))
      }
    }
    if instructions.isEmpty { return false }

    var applyDuration: TimeInterval = 0
    do {
      // Update range cache to reflect this insertion and shift subsequent locations.
      let prefixLen = combinedInsertPrefix?.length ?? 0
      let insertLen = prefixLen + attr.length
      let deleteLen = deleteOldPostRange?.length ?? 0
      let delta = insertLen - deleteLen

      if delta != 0 {
        // Propagate childrenLength delta to the parent and its ancestors.
        var cursor: NodeKey? = parentKey
        while let k = cursor {
          if var it = editor.rangeCache[k] {
            it.childrenLength &+= delta
            editor.rangeCache[k] = it
          }
          cursor = pendingEditorState.nodeMap[k]?.parent
        }

        @inline(__always)
        func lastDescendantKey(state: EditorState, root: NodeKey) -> NodeKey {
          var current = root
          while let el = state.nodeMap[current] as? ElementNode {
            let children = el.getChildrenKeys(fromLatest: false)
            guard let last = children.last else { break }
            current = last
          }
          return current
        }

        let shiftStartKey: NodeKey = {
          if insertIndex == 0 { return parentKey }
          let prevSiblingKey = nextChildren[insertIndex - 1]
          return lastDescendantKey(state: pendingEditorState, root: prevSiblingKey)
        }()

        let (order, positions) = fenwickOrderAndIndex(editor: editor)
        applyIncrementalLocationShifts(
          rangeCache: &editor.rangeCache,
          ranges: [(startKey: shiftStartKey, endKeyExclusive: Optional<NodeKey>.none, delta: delta)],
          order: order,
          indexOf: positions,
          diffScratch: &editor.locationShiftDiffScratch
        )
      }

      // Add/rebuild range cache entries for the inserted subtree at its new absolute location.
      let addedStartLoc = effectiveInsertLoc + prefixLen
      _ = recomputeRangeCacheSubtree(
        nodeKey: addedKey,
        state: pendingEditorState,
        startLocation: addedStartLoc,
        editor: editor
      )

      // Fenwick variant: apply delete/insert instructions at computed locations
      // Ensure TextKit attributes are fixed after inserting attachments (e.g., decorators/images)
      // so LayoutManager can resolve TextAttachment runs immediately for view mounting.
      let stats = applyInstructions(instructions, editor: editor, fixAttributesEnabled: true)
      applyDuration = stats.duration
      // Ensure decorator cache/positions reflect additions - only for the new block
      // (other nodes under parent are unchanged, so we don't need to scan them)
      reconcileDecoratorOpsForSubtree(
        ancestorKey: addedKey,
        prevState: currentEditorState,
        nextState: pendingEditorState,
        editor: editor
      )
      // After inserting a decorator, force a minimal layout/display invalidation over
      // the character range so LayoutManager positions and unhides the view immediately.
      // IMPORTANT: Defer to next run loop to avoid crash when textStorage is editing.
      if let _ = pendingEditorState.nodeMap[addedKey] as? DecoratorNode,
         let range = editor.rangeCache[addedKey]?.range {
        let editorWeak = editor
        let rangeCopy = range
        DispatchQueue.main.async {
          guard let layoutManager = reconcilerLayoutManager(editorWeak) else { return }
          layoutManager.invalidateLayout(forCharacterRange: rangeCopy, actualCharacterRange: nil)
          layoutManager.invalidateDisplay(forCharacterRange: rangeCopy)
          // Proactively ensure glyph layout to avoid relying on an external draw pass.
          let glyphRange = layoutManager.glyphRange(forCharacterRange: rangeCopy, actualCharacterRange: nil)
          layoutManager.ensureLayout(forGlyphRange: glyphRange)
        }
      }
    }

    // Block attributes only for inserted node
    applyBlockAttributesPass(
      editor: editor, pendingEditorState: pendingEditorState, affectedKeys: [addedKey],
      treatAllNodesAsDirty: false)

    // Selection reconcile mirrors other fast paths
    if shouldReconcileSelection {
      let prevSelection = currentEditorState.selection
      let nextSelection = pendingEditorState.selection
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(
        duration: applyDuration, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
        treatedAllNodesAsDirty: false, pathLabel: "insert-block", planningDuration: 0, applyDuration: applyDuration)
      metrics.record(.reconcilerRun(metric))
    }
    // Assign a stable nodeIndex for future Fenwick-backed locations if missing.
    if var item = editor.rangeCache[addedKey] {
      if item.nodeIndex == 0 {
        item.nodeIndex = editor.nextFenwickNodeIndex
        editor.nextFenwickNodeIndex += 1
        editor.rangeCache[addedKey] = item
      }
    }
    return true
  }

  // MARK: - Fast path: paragraph split (Enter key)
  // Handles the case where pressing Enter splits a paragraph:
  // - Original paragraph's TextNode is truncated (negative text delta)
  // - New paragraph is added with the truncated text
  @MainActor
  private static func fastPath_SplitParagraph(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    if editor.suppressInsertFastPathOnce {
      editor.suppressInsertFastPathOnce = false
      return false
    }
    // Read-only contexts skip structural fast paths
    if isReadOnlyFrontendContext(editor) { return false }

    // STEP 1: Detect the split-paragraph pattern
    // Find a parent Element that gained exactly one child
    let dirtyParents = editor.dirtyNodes.keys.compactMap { key -> (NodeKey, ElementNode, ElementNode)? in
      guard let prev = currentEditorState.nodeMap[key] as? ElementNode,
            let next = pendingEditorState.nodeMap[key] as? ElementNode else { return nil }
      return (key, prev, next)
    }
    guard let cand = dirtyParents.first(where: { (_, prev, next) in
      let prevChildren = prev.getChildrenKeys(fromLatest: false)
      let nextChildren = next.getChildrenKeys(fromLatest: false)
      if nextChildren.count != prevChildren.count + 1 { return false }
      let prevSet = Set(prevChildren)
      let nextSet = Set(nextChildren)
      let added = nextSet.subtracting(prevSet)
      let removed = prevSet.subtracting(nextSet)
      return added.count == 1 && removed.isEmpty
    }) else { return false }

    let (parentKey, prevParent, nextParent) = cand
    let prevChildren = prevParent.getChildrenKeys(fromLatest: false)
    let nextChildren = nextParent.getChildrenKeys(fromLatest: false)
    let prevSet = Set(prevChildren)
    let addedKey = Set(nextChildren).subtracting(prevSet).first!

    // Ensure the insertion does not also reorder existing siblings
    let nextWithoutAdded = nextChildren.filter { $0 != addedKey }
    if nextWithoutAdded != prevChildren { return false }

    // STEP 2: Find exactly one TextNode with a negative text delta (truncation)
    // OPTIMIZATION: Instead of scanning ALL dirty nodes with computePartDiffs (O(N)),
    // only look at the previous sibling subtree where truncation must occur (O(K) for small K)
    guard let insertIndex = nextChildren.firstIndex(of: addedKey), insertIndex > 0 else { return false }
    let prevSiblingKey = nextChildren[insertIndex - 1]

    // The truncated text node should be in the previous sibling's subtree (the paragraph being split)
    // Collect children of prevSibling (typically just 1-3 text nodes in a paragraph)
    guard let prevSibling = pendingEditorState.nodeMap[prevSiblingKey] as? ElementNode else { return false }
    let siblingChildren = prevSibling.getChildrenKeys(fromLatest: false)

    var truncatedKey: NodeKey? = nil
    var truncatedTextDelta: Int = 0

    // Find truncated TextNode among the previous sibling's children
    for childKey in siblingChildren {
      guard editor.dirtyNodes[childKey] != nil,
            let prevText = currentEditorState.nodeMap[childKey] as? TextNode,
            let nextText = pendingEditorState.nodeMap[childKey] as? TextNode,
            let _ = editor.rangeCache[childKey] else { continue }

      let prevLen = prevText.getTextPart(fromLatest: false).lengthAsNSString()
      let nextLen = nextText.getTextPart(fromLatest: false).lengthAsNSString()
      let delta = nextLen - prevLen

      if delta < 0 {
        if truncatedKey != nil {
          // Multiple truncated text nodes - bail out
          return false
        }
        truncatedKey = childKey
        truncatedTextDelta = delta
      }
    }

    guard let truncatedKey = truncatedKey else { return false }

    guard let prevTextNode = currentEditorState.nodeMap[truncatedKey] as? TextNode,
          let nextTextNode = pendingEditorState.nodeMap[truncatedKey] as? TextNode,
          let truncatedRange = editor.rangeCache[truncatedKey] else { return false }

    #if DEBUG
    let t_split_start = CFAbsoluteTimeGetCurrent()
    print("[fastPath_SplitParagraph] parentKey=\(parentKey) addedKey=\(addedKey) truncatedKey=\(truncatedKey) truncatedDelta=\(truncatedTextDelta)")
    #endif

    // STEP 3: Apply the text truncation (like fastPath_TextOnly)
    guard let textStorage = reconcilerTextStorage(editor) else { return false }
    let theme = editor.getTheme()

    let prevText = prevTextNode.getTextPart(fromLatest: false)
    let nextText = nextTextNode.getTextPart(fromLatest: false)
    let prevLen = prevText.lengthAsNSString()
    let nextLen = nextText.lengthAsNSString()
    let textDelta = nextLen - prevLen // negative for truncation

    // Calculate where truncation happens in TextStorage
    let textStart = truncatedRange.location + truncatedRange.preambleLength + truncatedRange.childrenLength
    let deleteRange = NSRange(location: textStart + nextLen, length: prevLen - nextLen)

    // STEP 4: Compute insert location for new block
    guard let parentRange = editor.rangeCache[parentKey] else { return false }
    // insertIndex was already computed in STEP 2

    let childrenStart = parentRange.location + parentRange.preambleLength
    var acc = 0
    for k in nextChildren.prefix(insertIndex) {
      if let r = editor.rangeCache[k] {
        // For the truncated node's parent, use the NEW length after truncation
        if k == truncatedKey {
          acc += r.preambleLength + r.childrenLength + nextLen + r.postambleLength
        } else if k == prevSiblingKey {
          // The previous sibling contains the truncated node - adjust for delta
          acc += r.range.length + textDelta
        } else {
          acc += r.range.length
        }
      } else {
        acc += subtreeTotalLength(nodeKey: k, state: pendingEditorState)
      }
    }
    let insertLoc = childrenStart + acc

    // Handle previous sibling's postamble change (newline for paragraph)
    var combinedInsertPrefix: NSAttributedString? = nil
    var deleteOldPostRange: NSRange? = nil
    var postDelta = 0
    if insertIndex > 0 {
      let prevSiblingKey = nextChildren[insertIndex - 1]
      if let prevSiblingRange = editor.rangeCache[prevSiblingKey],
         let prevSiblingNext = pendingEditorState.nodeMap[prevSiblingKey] {
        let oldPost = prevSiblingRange.postambleLength
        let newPost = prevSiblingNext.getPostamble().lengthAsNSString()
        if newPost != oldPost {
          let postLoc = prevSiblingRange.location + prevSiblingRange.preambleLength + prevSiblingRange.childrenLength + prevSiblingRange.textLength
          if oldPost > 0 { deleteOldPostRange = NSRange(location: postLoc, length: oldPost) }
          let postAttrStr = AttributeUtils.attributedStringByAddingStyles(
            NSAttributedString(string: prevSiblingNext.getPostamble()),
            from: prevSiblingNext, state: pendingEditorState, theme: theme)
          if postAttrStr.length > 0 { combinedInsertPrefix = postAttrStr }
          postDelta = newPost - oldPost
          if var it = editor.rangeCache[prevSiblingKey] {
            it.postambleLength = newPost
            editor.rangeCache[prevSiblingKey] = it
          }
        }
      }
    }

    // Build attributed string for the new block
    let newBlockAttr = buildAttributedSubtree(nodeKey: addedKey, state: pendingEditorState, theme: theme)
    let effectiveInsertLoc = deleteOldPostRange?.location ?? insertLoc

    // STEP 5: Apply TextStorage changes in single editing session
    let previousMode = textStorage.mode
    textStorage.mode = .controllerMode
    textStorage.beginEditing()

    // 1. Apply text truncation first (deleting from the end of the truncated text)
    if deleteRange.length > 0 {
      textStorage.replaceCharacters(in: deleteRange, with: "")
    }

    // 2. Delete old postamble if needed (adjust location after truncation)
    if let del = deleteOldPostRange {
      let adjustedDel = NSRange(location: del.location + textDelta, length: del.length)
      textStorage.replaceCharacters(in: adjustedDel, with: "")
    }

    // 3. Insert new block (with optional postamble prefix)
    let insertLocAdjusted = effectiveInsertLoc + textDelta - (deleteOldPostRange?.length ?? 0)
    if let prefix = combinedInsertPrefix {
      let combined = NSMutableAttributedString(attributedString: prefix)
      combined.append(newBlockAttr)
      textStorage.insert(combined, at: insertLocAdjusted)
    } else {
      textStorage.insert(newBlockAttr, at: insertLocAdjusted)
    }

    // Fix attributes
    let fixStart = max(0, textStart)
    let fixEnd = insertLocAdjusted + (combinedInsertPrefix?.length ?? 0) + newBlockAttr.length
    if fixEnd > fixStart {
      textStorage.fixAttributes(in: NSRange(location: fixStart, length: fixEnd - fixStart))
    }

    textStorage.endEditing()
    textStorage.mode = previousMode
    #if DEBUG
    let t_textkit = CFAbsoluteTimeGetCurrent()
    #endif

    // STEP 6: Update range cache incrementally
    // Update the truncated text node's textLength
    if var it = editor.rangeCache[truncatedKey] {
      it.textLength = nextLen
      editor.rangeCache[truncatedKey] = it
    }

    // Propagate text delta to ancestors' childrenLength
    var cursor: NodeKey? = nextTextNode.parent
    while let k = cursor {
      if var it = editor.rangeCache[k] {
        it.childrenLength += textDelta
        editor.rangeCache[k] = it
      }
      cursor = pendingEditorState.nodeMap[k]?.parent
    }

    // Calculate total delta for shift: text truncation + postamble change + new block
    let prefixLen = combinedInsertPrefix?.length ?? 0
    let insertLen = prefixLen + newBlockAttr.length
    let totalBlockDelta = insertLen - (deleteOldPostRange?.length ?? 0)

    // Propagate block insertion delta to parent's childrenLength
    cursor = parentKey
    while let k = cursor {
      if var it = editor.rangeCache[k] {
        it.childrenLength += totalBlockDelta + postDelta
        editor.rangeCache[k] = it
      }
      cursor = pendingEditorState.nodeMap[k]?.parent
    }

    // Add range cache entries for the new block
    let addedStartLoc = insertLocAdjusted + prefixLen
    _ = recomputeRangeCacheSubtree(
      nodeKey: addedKey,
      state: pendingEditorState,
      startLocation: addedStartLoc,
      editor: editor
    )

    // Shift locations for nodes after the truncated text using Fenwick tree
    if textDelta != 0 || totalBlockDelta != 0 {
      @inline(__always)
      func lastDescendantKey(state: EditorState, root: NodeKey) -> NodeKey {
        var current = root
        while let el = state.nodeMap[current] as? ElementNode {
          let children = el.getChildrenKeys(fromLatest: false)
          guard let last = children.last else { break }
          current = last
        }
        return current
      }

      let (order, positions) = fenwickOrderAndIndex(editor: editor)

      // Shift for text truncation
      if textDelta != 0 {
        applyIncrementalLocationShifts(
          rangeCache: &editor.rangeCache,
          ranges: [(startKey: truncatedKey, endKeyExclusive: Optional<NodeKey>.none, delta: textDelta)],
          order: order,
          indexOf: positions,
          diffScratch: &editor.locationShiftDiffScratch
        )
      }

      // Shift for block insertion (nodes after the inserted block)
      if totalBlockDelta != 0 {
        let shiftStartKey: NodeKey = lastDescendantKey(state: pendingEditorState, root: addedKey)
        applyIncrementalLocationShifts(
          rangeCache: &editor.rangeCache,
          ranges: [(startKey: shiftStartKey, endKeyExclusive: Optional<NodeKey>.none, delta: totalBlockDelta)],
          order: order,
          indexOf: positions,
          diffScratch: &editor.locationShiftDiffScratch
        )
      }
    }

    // Decorator reconciliation - only for the newly added block (not the entire parent tree)
    // The truncated paragraph's decorators are unchanged; we only need to check the new subtree
    reconcileDecoratorOpsForSubtree(
      ancestorKey: addedKey,
      prevState: currentEditorState,
      nextState: pendingEditorState,
      editor: editor
    )

    // Block attributes for affected nodes
    applyBlockAttributesPass(
      editor: editor,
      pendingEditorState: pendingEditorState,
      affectedKeys: [truncatedKey, addedKey],
      treatAllNodesAsDirty: false
    )

    // Selection reconcile
    if shouldReconcileSelection {
      let prevSelection = currentEditorState.selection
      let nextSelection = pendingEditorState.selection
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

    // Assign stable nodeIndex for new block
    if var item = editor.rangeCache[addedKey] {
      if item.nodeIndex == 0 {
        item.nodeIndex = editor.nextFenwickNodeIndex
        editor.nextFenwickNodeIndex += 1
        editor.rangeCache[addedKey] = item
      }
    }

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(
        duration: 0, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 1, rangesDeleted: 0,
        treatedAllNodesAsDirty: false, pathLabel: "split-paragraph")
      metrics.record(.reconcilerRun(metric))
    }

    #if DEBUG
    let t_split_end = CFAbsoluteTimeGetCurrent()
    print("[fastPath_SplitParagraph] SUCCESS: truncatedDelta=\(textDelta) blockDelta=\(totalBlockDelta) textkit=\(String(format: "%.3f", (t_textkit - t_split_start)*1000))ms total=\(String(format: "%.3f", (t_split_end - t_split_start)*1000))ms")
    #endif
    return true
  }

  /// Helper to collect all descendant keys under a root node
  @MainActor
  @inline(__always)
  private static func collectDescendantKeys(state: EditorState, root: NodeKey) -> Set<NodeKey> {
    guard let node = state.nodeMap[root] else { return [] }
    var out: Set<NodeKey> = []
    if let el = node as? ElementNode {
      for c in el.getChildrenKeys(fromLatest: false) {
        out.insert(c)
        out.formUnion(collectDescendantKeys(state: state, root: c))
      }
    }
    return out
  }

  // MARK: - Fast path: delete contiguous blocks under a single ElementNode
  @MainActor
  private static func fastPath_DeleteBlocks(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    // Safety: do NOT treat this update as a structural block delete if the user's
    // selection is a collapsed caret inside a TextNode (i.e., not at a text boundary).
    // This prevents cases where a single-character delete/backspace inside a line
    // accidentally triggers removal of an entire paragraph.
    // Use the pre-update selection (current state) for this guard. Many valid structural deletes
    // (e.g., paragraph merges or node-selection deletes) leave the caret *inside* a TextNode in the
    // pending state after the operation completes.
    if let sel = currentEditorState.selection as? RangeSelection, sel.isCollapsed() {
      if sel.anchor.type == .text, let tn = currentEditorState.nodeMap[sel.anchor.key] as? TextNode {
        let off = sel.anchor.offset
        let len = tn.getTextPart(fromLatest: false).lengthAsNSString()
        if off > 0 && off < len {
          return false
        }
      }
    }
    // Find a parent Element whose children lost one or more direct children (no additions)
    let dirtyParents = editor.dirtyNodes.keys.compactMap { key -> (NodeKey, ElementNode, ElementNode)? in
      guard let prev = currentEditorState.nodeMap[key] as? ElementNode,
            let next = pendingEditorState.nodeMap[key] as? ElementNode else { return nil }
      return (key, prev, next)
    }
    guard let cand = dirtyParents.first(where: { (parentKey, prev, next) in
      let prevChildren = prev.getChildrenKeys(fromLatest: false)
      let nextChildren = next.getChildrenKeys(fromLatest: false)
      if nextChildren.count >= prevChildren.count { return false }
      let prevSet = Set(prevChildren)
      let nextSet = Set(nextChildren)
      let removed = prevSet.subtracting(nextSet)
      let added = nextSet.subtracting(prevSet)
      return !removed.isEmpty && added.isEmpty
    }) else { return false }

    let (parentKey, prevParent, nextParent) = cand
    let prevChildren = prevParent.getChildrenKeys(fromLatest: false)
    let nextChildren = nextParent.getChildrenKeys(fromLatest: false)
    let nextSet = Set(nextChildren)
    // Collect removed indices in prev order and cluster into contiguous groups
    var removedIndices: [Int] = []
    for (i, k) in prevChildren.enumerated() { if !nextSet.contains(k) { removedIndices.append(i) } }
    if removedIndices.isEmpty { return false }
    var groups: [(start: Int, end: Int)] = []
    var s = removedIndices[0]
    var e = s
    for idx in removedIndices.dropFirst() {
      if idx == e + 1 { e = idx } else { groups.append((s, e)); s = idx; e = idx }
    }
    groups.append((s, e))

    // Safety: if any removed direct child is still attached in the pending state,
    // this is a move (not a delete). Bail out to avoid dropping content.
    for idx in removedIndices {
      let k = prevChildren[idx]
      if let n = pendingEditorState.nodeMap[k], n.isAttached() {
        return false
      }
    }

    let theme = editor.getTheme()
    var rangeShifts: [(startKey: NodeKey, endKeyExclusive: NodeKey?, delta: Int)] = []
    rangeShifts.reserveCapacity(groups.count * 2)

    @inline(__always)
    func applyChildrenLengthDeltaFromParent(_ parentKey: NodeKey, delta: Int) {
      guard delta != 0 else { return }
      var cursor: NodeKey? = parentKey
      while let k = cursor {
        if var it = editor.rangeCache[k] {
          it.childrenLength &+= delta
          editor.rangeCache[k] = it
        }
        cursor = pendingEditorState.nodeMap[k]?.parent
      }
    }

    // Build delete ranges coalesced per group
    var instructions: [Instruction] = []
    var totalDelta = 0
    var affected: Set<NodeKey> = [parentKey]
    for g in groups {
      guard g.start < prevChildren.count && g.end < prevChildren.count else { continue }
      let firstKey = prevChildren[g.start]
      let lastKey = prevChildren[g.end]
      guard let firstItem = editor.rangeCache[firstKey], let lastItem = editor.rangeCache[lastKey] else { continue }

      // Neighbor boundary: the previous sibling's postamble can depend on its next sibling.
      // When blocks are removed in the middle, update the previous sibling's postamble to
      // match pending state so the resulting string stays in parity with legacy.
      if g.start > 0 {
        let prevSiblingKey = prevChildren[g.start - 1]
        if let prevSiblingRange = editor.rangeCache[prevSiblingKey],
           let prevSiblingNext = pendingEditorState.nodeMap[prevSiblingKey] {
          let oldPost = prevSiblingRange.postambleLength
          let newPostStr = prevSiblingNext.getPostamble()
          let newPost = newPostStr.lengthAsNSString()
          if newPost != oldPost {
            let postLoc = prevSiblingRange.location + prevSiblingRange.preambleLength + prevSiblingRange.childrenLength + prevSiblingRange.textLength
            if oldPost > 0 {
              instructions.append(.delete(range: NSRange(location: postLoc, length: oldPost)))
            }
            let postAttrStr = AttributeUtils.attributedStringByAddingStyles(
              NSAttributedString(string: newPostStr),
              from: prevSiblingNext,
              state: pendingEditorState,
              theme: theme
            )
            if postAttrStr.length > 0 {
              instructions.append(.insert(location: postLoc, attrString: postAttrStr))
            }
            let deltaPost = newPost - oldPost
            if var it = editor.rangeCache[prevSiblingKey] { it.postambleLength = newPost; editor.rangeCache[prevSiblingKey] = it }
            if let pk = prevSiblingNext.parent { applyChildrenLengthDeltaFromParent(pk, delta: deltaPost) }
            rangeShifts.append((startKey: prevSiblingKey, endKeyExclusive: Optional<NodeKey>.none, delta: deltaPost))
          }
        }
      }

      let start = firstItem.location
      let end = lastItem.location + lastItem.range.length
      let len = max(0, end - start)
      if len > 0 {
        instructions.append(.delete(range: NSRange(location: start, length: len)))
        rangeShifts.append((startKey: lastKey, endKeyExclusive: Optional<NodeKey>.none, delta: -len))
      }
      totalDelta &-= len
      // Mark neighbors as affected for block attributes
      if g.start > 0 { affected.insert(prevChildren[g.start - 1]) }
      if g.end + 1 < prevChildren.count { affected.insert(prevChildren[g.end + 1]) }
    }
    if instructions.isEmpty { return false }

    // Update parent+ancestor childrenLength now that removed blocks are gone.
    applyChildrenLengthDeltaFromParent(parentKey, delta: totalDelta)

    // Apply deletes via batch path
    // If a clamp range was provided (selection-driven delete), intersect deletes.
    if let clamp = editor.pendingDeletionClampRange {
      var clamped: [Instruction] = []
      var newTotalDelta = 0
      var minStart: Int? = nil
      for inst in instructions {
        if case .delete(let r) = inst {
          let inter = NSIntersectionRange(r, clamp)
          if inter.length > 0 {
            if minStart == nil || inter.location < minStart! { minStart = inter.location }
            clamped.append(.delete(range: inter))
            newTotalDelta &-= inter.length
          }
        }
      }
      // If clamp starts before the first intersected delete, add a leading delete to cover
      // selection preamble (e.g., a paragraph separator) left behind by block grouping.
      if let ms = minStart, clamp.location < ms {
        let lead = NSRange(location: clamp.location, length: ms - clamp.location)
        if lead.length > 0 { clamped.append(.delete(range: lead)); newTotalDelta &-= lead.length }
      } else if minStart == nil {
        // No intersections; treat entire clamp as the delete target
        if clamp.length > 0 { clamped = [.delete(range: clamp)]; newTotalDelta = -clamp.length }
      }
      if !clamped.isEmpty {
        // Coalesce resulting deletes to ensure safe application order
        let merged = clamped.compactMap { inst -> NSRange? in if case .delete(let r) = inst { return r } else { return nil } }
        .sorted { $0.location < $1.location }
        var finalDeletes: [NSRange] = []
        if let first = merged.first {
          var cur = first
          for r in merged.dropFirst() {
            if NSMaxRange(cur) >= r.location { cur = NSRange(location: cur.location, length: max(NSMaxRange(cur), NSMaxRange(r)) - cur.location) }
            else { finalDeletes.append(cur); cur = r }
          }
          finalDeletes.append(cur)
        }
        instructions = finalDeletes.sorted { $0.location > $1.location }.map { .delete(range: $0) }
        totalDelta = newTotalDelta
      }
      editor.pendingDeletionClampRange = nil
    }

    let stats = applyInstructions(instructions, editor: editor, fixAttributesEnabled: false)

    let prePruneOrderAndIndex: ([NodeKey], [NodeKey: Int]) = fenwickOrderAndIndex(editor: editor)

    // Prune removed subtrees from range cache without scanning the entire parent subtree.
    let removedRoots: [NodeKey] = removedIndices.map { prevChildren[$0] }
    if !removedRoots.isEmpty {
      var toRemove: Set<NodeKey> = []
      for r in removedRoots {
        toRemove.formUnion(subtreeKeysDFS(rootKey: r, state: currentEditorState))
      }
      if !toRemove.isEmpty {
        for k in toRemove { editor.rangeCache.removeValue(forKey: k) }
        editor.invalidateDFSOrderCache()
      }

      // Reconcile decorator removals only for deleted subtrees to avoid scanning the entire parent.
      for r in removedRoots {
        reconcileDecoratorOpsForSubtree(
          ancestorKey: r,
          prevState: currentEditorState,
          nextState: pendingEditorState,
          editor: editor
        )
      }
    }

    do {
      let (order, positions) = prePruneOrderAndIndex
      applyIncrementalLocationShifts(rangeCache: &editor.rangeCache, ranges: rangeShifts, order: order, indexOf: positions, diffScratch: &editor.locationShiftDiffScratch)
    }
    // Always recompute the parent subtree for correctness (decorators, paragraph merges, etc.).
    // Fenwick shifts handle global location deltas; subtree recompute fixes local invariants.
    if let parentPrevRange = editor.rangeCache[parentKey] {
      _ = recomputeRangeCacheSubtree(nodeKey: parentKey, state: pendingEditorState, startLocation: parentPrevRange.location, editor: editor)
    }

    // Block attributes over parent + neighbors
    applyBlockAttributesPass(editor: editor, pendingEditorState: pendingEditorState, affectedKeys: affected, treatAllNodesAsDirty: false)

    // Selection reconcile
    let prevSelection = currentEditorState.selection
    let nextSelection = pendingEditorState.selection
    var selectionsAreDifferent = false
    if let nextSelection, let prevSelection { selectionsAreDifferent = !nextSelection.isSelection(prevSelection) }
    let needsUpdate = editor.dirtyType != .noDirtyNodes
    if shouldReconcileSelection && (needsUpdate || nextSelection == nil || selectionsAreDifferent) {
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(duration: stats.duration, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0, treatedAllNodesAsDirty: false, pathLabel: "delete-block", planningDuration: 0, applyDuration: stats.duration)
      metrics.record(.reconcilerRun(metric))
    }
    return true
  }

  // Find first key whose cached location is >= targetLocation
  @MainActor
  private static func firstKey(afterOrAt targetLocation: Int, in cache: [NodeKey: RangeCacheItem]) -> NodeKey? {
    // Build ordered list once and binary search by location
    let ordered = cache.map { ($0.key, $0.value.location) }.sorted { $0.1 < $1.1 }
    guard !ordered.isEmpty else { return nil }
    var lo = 0, hi = ordered.count - 1
    var ans: NodeKey? = nil
    while lo <= hi {
      let mid = (lo + hi) / 2
      let loc = ordered[mid].1
      if loc >= targetLocation {
        ans = ordered[mid].0
        if mid == 0 { break }
        hi = mid - 1
      } else {
        lo = mid + 1
      }
    }
    return ans
  }

  // Multi-text changes in one pass (central aggregation only)
  @MainActor
  private static func fastPath_TextOnly_Multi(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    // Collect all TextNodes whose text changed
    let candidates: [NodeKey] = editor.dirtyNodes.keys.compactMap { key in
      guard let prev = currentEditorState.nodeMap[key] as? TextNode,
            let next = pendingEditorState.nodeMap[key] as? TextNode,
            let prevRange = editor.rangeCache[key] else { return nil }
      let oldText = prev.getTextPart(fromLatest: false)
      let newText = next.getTextPart(fromLatest: false)
      if oldText == newText { return nil }
      // Ensure children and pre/post unchanged
      if prevRange.preambleLength != next.getPreamble().lengthAsNSString() { return nil }
      if prevRange.postambleLength != next.getPostamble().lengthAsNSString() { return nil }
      return key
    }
    if candidates.isEmpty { return false }

    // Build instructions across all candidates based on previous ranges
    var instructions: [Instruction] = []
    var affected: Set<NodeKey> = []
    var lengthChanges: [(nodeKey: NodeKey, part: NodePart, delta: Int)] = []
    for key in candidates {
      guard let prev = currentEditorState.nodeMap[key] as? TextNode,
            let next = pendingEditorState.nodeMap[key] as? TextNode,
            let prevRange = editor.rangeCache[key] else { continue }
      let oldText = prev.getTextPart(fromLatest: false); let newText = next.getTextPart(fromLatest: false)
      if oldText == newText { continue }
      let theme = editor.getTheme()
      let textStart = prevRange.location + prevRange.preambleLength + prevRange.childrenLength
      let deleteRange = NSRange(location: textStart, length: oldText.lengthAsNSString())
      if deleteRange.length > 0 { instructions.append(.delete(range: deleteRange)) }
      let attr = AttributeUtils.attributedStringByAddingStyles(NSAttributedString(string: newText), from: next, state: pendingEditorState, theme: theme)
      if attr.length > 0 { instructions.append(.insert(location: textStart, attrString: attr)) }

      let delta = newText.lengthAsNSString() - oldText.lengthAsNSString()
      // Defer cache updates to a single batched pass
      lengthChanges.append((nodeKey: key, part: .text, delta: delta))
      affected.insert(key)
      for p in next.getParents() { affected.insert(p.getKey()) }
    }
    if instructions.isEmpty { return false }
    let stats = applyInstructions(instructions, editor: editor)

    // Single batched cache/ancestor updates; aggregate Fenwick start shifts
    if !lengthChanges.isEmpty {
      let shifts = applyLengthDeltasBatch(editor: editor, changes: lengthChanges)
      for (k, d) in shifts where d != 0 { fenwickAggregatedDeltas[k, default: 0] &+= d }
    }

    // Update decorator positions after location rebuild at end (done in caller)
    // Apply block-level attributes scoped to affected nodes (skip for pure text edits)
    if shouldApplyBlockAttributesPass(
      currentEditorState: currentEditorState,
      pendingEditorState: pendingEditorState,
      editor: editor,
      affectedKeys: affected,
      treatAllNodesAsDirty: false
    ) {
      applyBlockAttributesPass(
        editor: editor,
        pendingEditorState: pendingEditorState,
        affectedKeys: affected,
        treatAllNodesAsDirty: false
      )
    }

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(duration: stats.duration, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0, treatedAllNodesAsDirty: false, pathLabel: "text-only-multi", planningDuration: 0, applyDuration: stats.duration, deleteCount: 0, insertCount: 0, setAttributesCount: 0, fixAttributesCount: 1)
      metrics.record(.reconcilerRun(metric))
    }
    return true
  }

  // Multi pre/post changes in one pass (central aggregation only)
  @MainActor
  private static func fastPath_PreamblePostambleOnly_Multi(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    false
  }

  // MARK: - Fast path: reorder children of a single ElementNode (same keys, new order)
  @MainActor
  private static func fastPath_ReorderChildren(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool
  ) throws -> Bool {
    // Identify all parents whose children order changed but set of keys is identical
    // We allow multiple dirty nodes; we only check the structural condition.
    var candidates: [NodeKey] = pendingEditorState.nodeMap.compactMap { key, node in
      guard let prev = currentEditorState.nodeMap[key] as? ElementNode,
            let next = node as? ElementNode else { return nil }
      let prevChildren = prev.getChildrenKeys(fromLatest: false)
      let nextChildren = next.getChildrenKeys(fromLatest: false)
      if prevChildren == nextChildren { return nil }
      if Set(prevChildren) != Set(nextChildren) { return nil }
      return key
    }
    // Process candidates in document order for stability
    candidates.sort { a, b in
      let la = editor.rangeCache[a]?.location ?? 0
      let lb = editor.rangeCache[b]?.location ?? 0
      return la < lb
    }

    var appliedAny = false
    for parentKey in candidates {
      guard
          let parentPrev = currentEditorState.nodeMap[parentKey] as? ElementNode,
          let parentNext = pendingEditorState.nodeMap[parentKey] as? ElementNode,
          let parentPrevRange = editor.rangeCache[parentKey]
      else { continue }

    let nextChildren = parentNext.getChildrenKeys(fromLatest: false)

    // Compute LIS (stable children); if almost all children are stable, moves are few
    let prevChildren = parentPrev.getChildrenKeys(fromLatest: false)
    let stableSet = computeStableChildKeys(prev: prevChildren, next: nextChildren)

    // Build attributed string for children in new order and compute subtree lengths
    let theme = editor.getTheme()
    let built = NSMutableAttributedString()
    for childKey in nextChildren {
      built.append(buildAttributedSubtree(nodeKey: childKey, state: pendingEditorState, theme: theme))
    }

    // Children region range in existing storage
    let childrenStart = parentPrevRange.location + parentPrevRange.preambleLength
    let childrenRange = NSRange(location: childrenStart, length: parentPrevRange.childrenLength)
    if childrenRange.length != built.length {
      // Not a pure reorder; bail and let legacy handle complex changes
      return false
    }

    // Decide whether to do minimal moves or full region rebuild.
    // For stability in suite-wide runs, prefer the simple region rebuild.
    let movedCount = nextChildren.filter { !stableSet.contains($0) }.count
    if movedCount == 0 {
      // Nothing to do beyond cache recompute
      _ = recomputeRangeCacheSubtree(
        nodeKey: parentKey, state: pendingEditorState, startLocation: parentPrevRange.location,
        editor: editor)
    } else {
      // Region rebuild fallback when many moves
      guard let textStorage = reconcilerTextStorage(editor) else { return false }
      let previousMode = textStorage.mode
      textStorage.mode = .controllerMode
      let t0 = CFAbsoluteTimeGetCurrent()
      textStorage.beginEditing()
      textStorage.replaceCharacters(in: childrenRange, with: built)
      textStorage.fixAttributes(in: NSRange(location: childrenRange.location, length: built.length))
      textStorage.endEditing()
      textStorage.mode = previousMode
      if let metrics = editor.metricsContainer {
        let applyDur = CFAbsoluteTimeGetCurrent() - t0
        let metric = ReconcilerMetric(
          duration: applyDur, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
          treatedAllNodesAsDirty: false, pathLabel: "reorder-rebuild", planningDuration: 0, applyDuration: applyDur, movedChildren: movedCount)
        metrics.record(.reconcilerRun(metric))
      }
    }

    // Rebuild locations for the reordered subtree without recomputing lengths.
    // Compute child-level new starts using next order and shift entire subtrees accordingly.
    // This keeps decorator-bearing subtrees intact while avoiding a full subtree recompute.
    let prevChildrenOrder = prevChildren
    let nextChildrenOrder = nextChildren

    // Entire-range length for each direct child (unchanged by reorder)
    var childLength: [NodeKey: Int] = [:]
    var childOldStart: [NodeKey: Int] = [:]
    for k in prevChildrenOrder {
      if let item = editor.rangeCache[k] {
        childLength[k] = item.range.length
        childOldStart[k] = item.location
      } else {
        // Fallback to computing from state if cache missing (should be rare)
        let len = subtreeTotalLength(nodeKey: k, state: currentEditorState)
        childLength[k] = len
        childOldStart[k] = parentPrevRange.location + parentPrevRange.preambleLength // safe base
      }
    }

    // Compute new starts based on next order
    var childNewStart: [NodeKey: Int] = [:]
    var accLen = 0
    for k in nextChildrenOrder {
      childNewStart[k] = childrenStart + accLen
      accLen += childLength[k] ?? 0
    }

    // Shift locations for each direct child subtree via Fenwick range adds
    var rangeShifts: [(NodeKey, NodeKey?, Int)] = []
    let (orderedKeys, indexOf) = fenwickOrderAndIndex(editor: editor)
    for k in nextChildrenOrder {
      guard let oldStart = childOldStart[k], let newStart = childNewStart[k] else { continue }
      let deltaShift = newStart - oldStart
      if deltaShift == 0 { continue }
      let subKeys = subtreeKeysDFS(rootKey: k, state: pendingEditorState)
      var maxIdx = 0
      for sk in subKeys { if let idx = indexOf[sk], idx > maxIdx { maxIdx = idx } }
      let endExclusive: NodeKey? = (maxIdx < orderedKeys.count) ? orderedKeys[maxIdx] : nil
      rangeShifts.append((k, endExclusive, deltaShift))
    }
    if !rangeShifts.isEmpty {
      editor.rangeCache = rebuildLocationsWithRangeDiffs(
        prev: editor.rangeCache, ranges: rangeShifts, order: orderedKeys, indexOf: indexOf)
    }

    // Reconcile decorators within this subtree (moves preserve cache; dirty -> needsDecorating)
    reconcileDecoratorOpsForSubtree(ancestorKey: parentKey, prevState: currentEditorState, nextState: pendingEditorState, editor: editor)

    // Apply block-level attributes for parent and direct children (reorder may affect paragraph boundaries)
    var affected: Set<NodeKey> = [parentKey]
    for k in nextChildren { affected.insert(k) }
    applyBlockAttributesPass(editor: editor, pendingEditorState: pendingEditorState, affectedKeys: affected, treatAllNodesAsDirty: false)

    // Selection handling
    let prevSelection = currentEditorState.selection
    let nextSelection = pendingEditorState.selection
    var selectionsAreDifferent = false
    if let nextSelection, let prevSelection { selectionsAreDifferent = !nextSelection.isSelection(prevSelection) }
    let needsUpdate = editor.dirtyType != .noDirtyNodes
    if shouldReconcileSelection && (needsUpdate || nextSelection == nil || selectionsAreDifferent) {
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

      appliedAny = true
    }
    if appliedAny { editor.invalidateDFSOrderCache() }
    return appliedAny
  }

  // Build full attributed subtree for a node in pending state (preamble + children + text + postamble)
  @MainActor
  private static func buildAttributedSubtree(
    nodeKey: NodeKey, state: EditorState, theme: Theme
  ) -> NSAttributedString {
    let output = NSMutableAttributedString()
    appendAttributedSubtree(into: output, nodeKey: nodeKey, state: state, theme: theme)
    return output
  }

  @MainActor
  private static func appendAttributedSubtree(
    into output: NSMutableAttributedString,
    nodeKey: NodeKey,
    state: EditorState,
    theme: Theme
  ) {
    guard let node = state.nodeMap[nodeKey] else { return }

    let attributes = AttributeUtils.attributedStringStyles(from: node, state: state, theme: theme)

    @inline(__always)
    func appendStyledString(_ string: String) {
      let len = string.lengthAsNSString()
      guard len > 0 else { return }
      let start = output.length
      output.append(NSAttributedString(string: string))
      output.addAttributes(attributes, range: NSRange(location: start, length: len))
    }

    appendStyledString(node.getPreamble())

    if let element = node as? ElementNode {
      for child in element.getChildrenKeys(fromLatest: false) {
        appendAttributedSubtree(into: output, nodeKey: child, state: state, theme: theme)
      }
    }

    appendStyledString(node.getTextPart(fromLatest: false))
    appendStyledString(node.getPostamble())
  }

  // Recompute range cache (location + part lengths) for a subtree using the pending state.
  // Returns total length (entireRange) written for this node.
  @MainActor
  @discardableResult
  private static func recomputeRangeCacheSubtree(
    nodeKey: NodeKey, state: EditorState, startLocation: Int, editor: Editor
  ) -> Int {
    guard let node = state.nodeMap[nodeKey] else { return 0 }
    var item = editor.rangeCache[nodeKey] ?? RangeCacheItem()
    if item.nodeIndex == 0 { item.nodeIndex = editor.nextFenwickNodeIndex; editor.nextFenwickNodeIndex += 1 }
    item.location = startLocation
    let preLen = node.getPreamble().lengthAsNSString()
    let preSpecial = node.getPreamble().lengthAsNSString(includingCharacters: ["\u{200B}"])
    item.preambleLength = preLen
    item.preambleSpecialCharacterLength = preSpecial
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
    let textLen = node.getTextPart(fromLatest: false).lengthAsNSString()
    item.textLength = textLen
    cursor += textLen
    let postLen = node.getPostamble().lengthAsNSString()
    item.postambleLength = postLen
    editor.rangeCache[nodeKey] = item
    return preLen + childrenLen + textLen + postLen
  }

  // Minimal selection reconciler mirroring legacy logic
  @MainActor
  private static func reconcileSelection(
    prevSelection: BaseSelection?,
    nextSelection: BaseSelection?,
    editor: Editor
  ) throws {
    guard let nextSelection else {
      if let prevSelection, !prevSelection.dirty {
        return
      }
      resetSelectedRange(editor: editor)
      return
    }
    try updateNativeSelection(editor: editor, selection: nextSelection)
  }

  // MARK: - Fast path: preamble/postamble change only for a single node (children & text unchanged)
  @MainActor
  private static func fastPath_PreamblePostambleOnly(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    fenwickAggregatedDeltas: inout [NodeKey: Int]
  ) throws -> Bool {
    // Skip attributes-only structural path in read-only to avoid spacing/order mismatches.
    if isReadOnlyFrontendContext(editor) { return false }
    guard editor.dirtyNodes.count == 1, let dirtyKey = editor.dirtyNodes.keys.first else {
      return false
    }
    guard let _ = currentEditorState.nodeMap[dirtyKey],
          let nextNode = pendingEditorState.nodeMap[dirtyKey],
          let prevRange = editor.rangeCache[dirtyKey] else { return false }

    // Ensure children/text lengths unchanged (attributes-only path must not change lengths)
    let nextTextLen = nextNode.getTextPart(fromLatest: false).lengthAsNSString()
    if nextTextLen != prevRange.textLength { return false }
    // We approximate children unchanged by comparing aggregated length via pending state subtree build
    var computedChildrenLen = 0
    if let element = nextNode as? ElementNode {
      for child in element.getChildrenKeys(fromLatest: false) {
        computedChildrenLen += subtreeTotalLength(nodeKey: child, state: pendingEditorState)
      }
    }
    if computedChildrenLen != prevRange.childrenLength { return false }

    let nextPreLen = nextNode.getPreamble().lengthAsNSString()
    let nextPostLen = nextNode.getPostamble().lengthAsNSString()
    // Attributes-only: strictly no length changes (safer; avoids re-dirty loops)
    guard nextPreLen == prevRange.preambleLength && nextPostLen == prevRange.postambleLength else { return false }
    if nextPreLen == 0 && nextPostLen == 0 { return false }

    let theme = editor.getTheme()
    var applied: [Instruction] = []

    // Postamble attributes only (higher location first)
    if nextPostLen > 0 {
      let postLoc = prevRange.location + prevRange.preambleLength + prevRange.childrenLength + prevRange.textLength
      let rng = NSRange(location: postLoc, length: nextPostLen)
      let postAttr = AttributeUtils.attributedStringByAddingStyles(
        NSAttributedString(string: nextNode.getPostamble()), from: nextNode, state: pendingEditorState,
        theme: theme)
      let attrs = postAttr.attributes(at: 0, effectiveRange: nil)
      applied.append(.setAttributes(range: rng, attributes: attrs))
    }

    // Apply preamble second (lower location)
    // Preamble attributes only
    if nextPreLen > 0 {
      let preLoc = prevRange.location
      let rng = NSRange(location: preLoc, length: nextPreLen)
      let preAttr = AttributeUtils.attributedStringByAddingStyles(
        NSAttributedString(string: nextNode.getPreamble()), from: nextNode, state: pendingEditorState,
        theme: theme)
      let attrs = preAttr.attributes(at: 0, effectiveRange: nil)
      applied.append(.setAttributes(range: rng, attributes: attrs))
    }
    let stats = applyInstructions(applied, editor: editor)

    // Update decorators positions
    if let ts = reconcilerTextStorage(editor) {
      for (key, oldLoc) in ts.decoratorPositionCache {
        if let loc = editor.rangeCache[key]?.location, loc != oldLoc {
          ts.decoratorPositionCache[key] = loc
          ts.decoratorPositionCacheDirtyKeys.insert(key)
        }
      }
    }

    // No block-level attribute pass for attributes-only; keep changes local

    // Selection handling
    let prevSelection = currentEditorState.selection
    let nextSelection = pendingEditorState.selection
    var selectionsAreDifferent = false
    if let nextSelection, let prevSelection { selectionsAreDifferent = !nextSelection.isSelection(prevSelection) }
    let needsUpdate = editor.dirtyType != .noDirtyNodes
    if shouldReconcileSelection && (needsUpdate || nextSelection == nil || selectionsAreDifferent) {
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(
        duration: stats.duration, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
        treatedAllNodesAsDirty: false, pathLabel: "prepost-attrs-only", planningDuration: 0,
        applyDuration: stats.duration, deleteCount: stats.deletes, insertCount: stats.inserts,
        setAttributesCount: stats.sets, fixAttributesCount: stats.fixes)
      metrics.record(.reconcilerRun(metric))
    }
    return true
  }

  // MARK: - Fast path: composition (marked text) start/update
  @MainActor
  private static func fastPath_Composition(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool,
    op: MarkedTextOperation
  ) throws -> Bool {
    guard let textStorage = reconcilerTextStorage(editor) else { return false }
    // Only special-handle start of composition. Updates/end are handled by Events via insert/replace
    guard op.createMarkedText else { return false }

    // Locate Point at replacement start if possible
    let startLocation = op.selectionRangeToReplace.location
    let point = try? pointAtStringLocation(startLocation, searchDirection: .forward, rangeCache: editor.rangeCache)

    // Prepare attributed marked text with styles from owning node if available
    var attrs: [NSAttributedString.Key: Any] = [:]
    if let p = point, let node = pendingEditorState.nodeMap[p.key] {
      attrs = AttributeUtils.attributedStringStyles(from: node, state: pendingEditorState, theme: editor.getTheme())
    }
    let markedAttr = NSAttributedString(string: op.markedTextString, attributes: attrs)

    // Replace characters in storage at requested range
    let delta = markedAttr.length - op.selectionRangeToReplace.length
    let previousMode = textStorage.mode
    textStorage.mode = .controllerMode
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: op.selectionRangeToReplace, with: markedAttr)
    textStorage.fixAttributes(in: NSRange(location: op.selectionRangeToReplace.location, length: markedAttr.length))
    textStorage.endEditing()
    textStorage.mode = previousMode

    // Update range cache if we can resolve to a TextNode
    if let p = point, let textNode = pendingEditorState.nodeMap[p.key] as? TextNode {
      updateRangeCacheForTextChange(nodeKey: textNode.key, delta: delta)
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
    setMarkedTextFromReconciler(editor: editor, markedText: markedAttr, selectedRange: op.markedTextInternalSelection)

    // Skip selection reconcile after marked text (legacy behavior)
    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(
        duration: 0, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
        treatedAllNodesAsDirty: false, pathLabel: "composition-start")
      metrics.record(.reconcilerRun(metric))
    }
    return true
  }

  // MARK: - Fast path: contiguous multi-node region replace under a common ancestor
  @MainActor
  private static func fastPath_ContiguousMultiNodeReplace(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    shouldReconcileSelection: Bool
  ) throws -> Bool {
    // Require 2+ dirty nodes and no marked text handling pending
    guard editor.dirtyNodes.count >= 2 else { return false }

    // Find lowest common ancestor (LCA) element in pending state for all dirty nodes
    let dirtyKeys = Array(editor.dirtyNodes.keys)
    func ancestors(of key: NodeKey) -> [NodeKey] {
      var list: [NodeKey] = []
      var k: NodeKey? = key
      while let cur = k, let node = pendingEditorState.nodeMap[cur] {
        if let p = node.parent { list.append(p); k = p } else { break }
      }
      return list
    }
    var common: Set<NodeKey>? = nil
    for k in dirtyKeys {
      let a = Set(ancestors(of: k))
      common = (common == nil) ? a : common!.intersection(a)
      if common?.isEmpty == true { return false }
    }
    guard let candidateAncestors = common, let ancestorKey = candidateAncestors.first,
          let _ = currentEditorState.nodeMap[ancestorKey] as? ElementNode,
          let ancestorNext = pendingEditorState.nodeMap[ancestorKey] as? ElementNode,
          let ancestorPrevRange = editor.rangeCache[ancestorKey]
    else { return false }

    // Ensure no creates/deletes inside ancestor (same key set prev vs next)
    func collectDescendants(state: EditorState, root: NodeKey) -> Set<NodeKey> {
      guard let node = state.nodeMap[root] else { return [] }
      var out: Set<NodeKey> = []
      if let el = node as? ElementNode {
        for c in el.getChildrenKeys(fromLatest: false) {
          out.insert(c)
          out.formUnion(collectDescendants(state: state, root: c))
        }
      }
      return out
    }
    let prevSet = collectDescendants(state: currentEditorState, root: ancestorKey)
    let nextSet = collectDescendants(state: pendingEditorState, root: ancestorKey)
    if prevSet != nextSet { return false }

    // Build attributed content for ancestor's children in next order
    let theme = editor.getTheme()
    let nextChildren = ancestorNext.getChildrenKeys(fromLatest: false)
    let built = NSMutableAttributedString()
    for child in nextChildren { built.append(buildAttributedSubtree(nodeKey: child, state: pendingEditorState, theme: theme)) }

    // Replace the children region for the ancestor
    guard let textStorage = reconcilerTextStorage(editor) else { return false }
    let previousMode = textStorage.mode
    let childrenStart = ancestorPrevRange.location + ancestorPrevRange.preambleLength
    let childrenRange = NSRange(location: childrenStart, length: ancestorPrevRange.childrenLength)
    textStorage.mode = .controllerMode
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: childrenRange, with: built)
    textStorage.fixAttributes(in: NSRange(location: childrenRange.location, length: built.length))
    textStorage.endEditing()
    textStorage.mode = previousMode

    // Metrics (planning timing and diff counts)
    if let metrics = editor.metricsContainer {
      let diffs = computePartDiffs(editor: editor, prevState: currentEditorState, nextState: pendingEditorState)
      let changed = diffs.count
      let metric = ReconcilerMetric(
        duration: 0, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 1, rangesDeleted: 1,
        treatedAllNodesAsDirty: false, pathLabel: "coalesced-replace", planningDuration: 0,
        applyDuration: 0, deleteCount: 1, insertCount: 1, setAttributesCount: 0, fixAttributesCount: 1)
      metrics.record(.reconcilerRun(metric))
      _ = changed // placeholder for potential future thresholds
    }

    // Recompute the range cache for this subtree (locations and lengths) and reconcile decorators
    _ = recomputeRangeCacheSubtree(
      nodeKey: ancestorKey, state: pendingEditorState, startLocation: ancestorPrevRange.location,
      editor: editor)
    pruneRangeCacheUnderAncestor(ancestorKey: ancestorKey, prevState: currentEditorState, nextState: pendingEditorState, editor: editor)
    reconcileDecoratorOpsForSubtree(ancestorKey: ancestorKey, prevState: currentEditorState, nextState: pendingEditorState, editor: editor)
    editor.invalidateDFSOrderCache()

    // Block-level attributes for ancestor + its parents
    var affected: Set<NodeKey> = [ancestorKey]
    if let ancNode = pendingEditorState.nodeMap[ancestorKey] { for p in ancNode.getParents() { affected.insert(p.getKey()) } }
    applyBlockAttributesPass(editor: editor, pendingEditorState: pendingEditorState, affectedKeys: affected, treatAllNodesAsDirty: false)

    // Selection reconcile
    let prevSelection = currentEditorState.selection
    let nextSelection = pendingEditorState.selection
    var selectionsAreDifferent = false
    if let nextSelection, let prevSelection { selectionsAreDifferent = !nextSelection.isSelection(prevSelection) }
    let needsUpdate = editor.dirtyType != .noDirtyNodes
    if shouldReconcileSelection && (needsUpdate || nextSelection == nil || selectionsAreDifferent) {
      try reconcileSelection(prevSelection: prevSelection, nextSelection: nextSelection, editor: editor)
    }

    if let metrics = editor.metricsContainer {
      let metric = ReconcilerMetric(
        duration: 0, dirtyNodes: editor.dirtyNodes.count, rangesAdded: 0, rangesDeleted: 0,
        treatedAllNodesAsDirty: false, pathLabel: "coalesced-replace")
      metrics.record(.reconcilerRun(metric))
    }
    return true
  }

  // Compute total entireRange length for a node subtree in the provided state.
  @MainActor
  private static func subtreeTotalLength(nodeKey: NodeKey, state: EditorState) -> Int {
    guard let node = state.nodeMap[nodeKey] else { return 0 }
    var sum = node.getPreamble().lengthAsNSString()
    if let el = node as? ElementNode {
      for c in el.getChildrenKeys(fromLatest: false) { sum += subtreeTotalLength(nodeKey: c, state: state) }
    }
    sum += node.getTextPart(fromLatest: false).lengthAsNSString()
    sum += node.getPostamble().lengthAsNSString()
    return sum
  }

  // MARK: - Block-level attributes pass (parity with legacy)
  @MainActor
  private static func shouldApplyBlockAttributesPass(
    currentEditorState: EditorState,
    pendingEditorState: EditorState,
    editor: Editor,
    affectedKeys: Set<NodeKey>?,
    treatAllNodesAsDirty: Bool
  ) -> Bool {
    if treatAllNodesAsDirty { return true }

    let theme = editor.getTheme()
    var nodesToCheck: Set<NodeKey> = Set(editor.dirtyNodes.keys)
    for k in editor.dirtyNodes.keys {
      if let n = pendingEditorState.nodeMap[k] {
        for p in n.getParents() { nodesToCheck.insert(p.getKey()) }
      }
    }
    if let affectedKeys { nodesToCheck.formUnion(affectedKeys) }

    @inline(__always)
    func differs(_ a: BlockLevelAttributes?, _ b: BlockLevelAttributes?) -> Bool {
      switch (a, b) {
      case (nil, nil):
        return false
      case (let lhs?, let rhs?):
        return !lhs.isEqual(rhs)
      default:
        return true
      }
    }

    for key in nodesToCheck {
      let prevAttrs = currentEditorState.nodeMap[key]?.getBlockLevelAttributes(theme: theme)
      let nextNode = pendingEditorState.nodeMap[key]
      let nextAttrs = nextNode?.getBlockLevelAttributes(theme: theme)
      if nextNode == nil && prevAttrs != nil { return true }
      if differs(prevAttrs, nextAttrs) { return true }
    }

    return false
  }

  @MainActor
  private static func applyBlockAttributesPass(
    editor: Editor,
    pendingEditorState: EditorState,
    affectedKeys: Set<NodeKey>?,
    treatAllNodesAsDirty: Bool
  ) {
    guard let textStorage = reconcilerTextStorage(editor) else { return }
    let theme = editor.getTheme()

    // Build node set to apply
    var nodesToApply: Set<NodeKey> = []
    if treatAllNodesAsDirty {
      nodesToApply = Set(pendingEditorState.nodeMap.keys)
    } else {
      nodesToApply = Set(editor.dirtyNodes.keys)
      // include parents of each dirty node
      for k in editor.dirtyNodes.keys {
        if let n = pendingEditorState.nodeMap[k] { for p in n.getParents() { nodesToApply.insert(p.getKey()) } }
      }
      if let affectedKeys { nodesToApply.formUnion(affectedKeys) }
    }

    let lastDescendentAttributes = getRoot()?.getLastChild()?.getAttributedStringAttributes(theme: theme) ?? [:]

    let previousMode = textStorage.mode
    textStorage.mode = .controllerMode
    textStorage.beginEditing()
    let rangeCache = editor.rangeCache
    for nodeKey in nodesToApply {
      guard let node = getNodeByKey(key: nodeKey), node.isAttached(), let cacheItem = rangeCache[nodeKey], let attributes = node.getBlockLevelAttributes(theme: theme) else { continue }
      AttributeUtils.applyBlockLevelAttributes(
        attributes, cacheItem: cacheItem, textStorage: textStorage, nodeKey: nodeKey,
        lastDescendentAttributes: lastDescendentAttributes)
    }
    textStorage.endEditing()
    textStorage.mode = previousMode
  }

  // Collect all node keys in a subtree (DFS order), including the root key.
  @MainActor
  private static func subtreeKeysDFS(rootKey: NodeKey, state: EditorState) -> [NodeKey] {
    guard let node = state.nodeMap[rootKey] else { return [] }
    var out: [NodeKey] = [rootKey]
    if let el = node as? ElementNode {
      for c in el.getChildrenKeys(fromLatest: false) {
        out.append(contentsOf: subtreeKeysDFS(rootKey: c, state: state))
      }
    }
    return out
  }

  // Checks whether candidateKey is inside the subtree rooted at rootKey in the provided state.
  @MainActor
  private static func subtreeContains(rootKey: NodeKey, candidateKey: NodeKey, state: EditorState) -> Bool {
    if rootKey == candidateKey { return true }
    guard let node = state.nodeMap[rootKey] as? ElementNode else { return false }
    for c in node.getChildrenKeys(fromLatest: false) {
      if subtreeContains(rootKey: c, candidateKey: candidateKey, state: state) { return true }
    }
    return false
  }

  // MARK: - RangeCache pruning helpers
  @MainActor
  private static func pruneRangeCacheGlobally(nextState: EditorState, editor: Editor) {
    var attached = Set(subtreeKeysDFS(rootKey: kRootNodeKey, state: nextState))
    attached.insert(kRootNodeKey)
    editor.rangeCache = editor.rangeCache.filter { attached.contains($0.key) }
    editor.invalidateDFSOrderCache()
  }

  @MainActor
  private static func pruneRangeCacheUnderAncestor(
    ancestorKey: NodeKey, prevState: EditorState, nextState: EditorState, editor: Editor
  ) {
    // Compute keys previously under ancestor
    let prevKeys = Set(subtreeKeysDFS(rootKey: ancestorKey, state: prevState))
    let nextKeys = Set(subtreeKeysDFS(rootKey: ancestorKey, state: nextState))
    let toRemove = prevKeys.subtracting(nextKeys)
    if toRemove.isEmpty { return }
    editor.rangeCache = editor.rangeCache.filter { !toRemove.contains($0.key) }
    editor.invalidateDFSOrderCache()
  }

  // MARK: - Decorator reconciliation
  @MainActor
  private static func reconcileDecoratorOpsForSubtree(
    ancestorKey: NodeKey,
    prevState: EditorState,
    nextState: EditorState,
    editor: Editor
  ) {
    guard let textStorage = reconcilerTextStorage(editor) else { return }

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

    var attachmentLocations: [NodeKey: Int]? = nil
    @inline(__always)
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
        // Ignore detached nodes that still exist in nodeMap but are no longer part of the
        // attached editor tree in this state (e.g., deleted nodes awaiting GC).
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
      // Double-check: only skip removal if the decorator moved to a different subtree.
      // If we're scanning from root and can't find it, it's orphaned - must remove.
      let decoratorNode = nextState.nodeMap[k] as? DecoratorNode
      let existsInNextState = decoratorNode != nil
      let isAttachedInNextState = existsInNextState && isAttached(key: k, in: nextState)
      if existsInNextState && isAttachedInNextState && ancestorKey != kRootNodeKey {
        // The decorator still exists in the next state AND is attached, just not under this ancestor.
        // This can happen during paragraph merges. Don't remove it.
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
      // Prefer rangeCache if available; otherwise fall back to scanning the
      // TextStorage for the newly inserted attachment run.
      if let loc = attachmentLocation(for: k) {
        textStorage.decoratorPositionCache[k] = loc
        textStorage.decoratorPositionCacheDirtyKeys.insert(k)
        // Ensure TextKit recognizes attachment attributes immediately at the new location
        // to avoid first-frame flicker. Fix attributes over the single-character attachment run.
        let safe = NSIntersectionRange(NSRange(location: loc, length: 1), NSRange(location: 0, length: textStorage.length))
        if safe.length > 0 { textStorage.fixAttributes(in: safe) }
      }
    }

    // Persist positions for all present decorators in next subtree and mark dirty ones for decorating
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
}
