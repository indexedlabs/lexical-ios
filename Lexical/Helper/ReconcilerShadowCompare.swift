/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)
import UIKit
import Foundation
import LexicalCore

@MainActor
internal func shadowCompareOptimizedVsBaseline(
  activeEditor: Editor,
  currentEditorState: EditorState,
  pendingEditorState: EditorState
) {
  guard let optimizedText = activeEditor.frontend?.textStorage else { return }

  func verifyRangeCacheInvariants(editor: Editor, label: String) {
    // root length should match text storage length
    if let rootItem = editor.rangeCache[kRootNodeKey], let ts = editor.frontend?.textStorage {
      let total = rootItem.preambleLength + rootItem.childrenLength + rootItem.textLength + rootItem.postambleLength
      if total != ts.string.lengthAsNSString() {
        activeEditor.log(.reconciler, .warning, "SHADOW-COMPARE[\(label)]: root length mismatch total=\(total) text=\(ts.string.lengthAsNSString())")
      }
    }
    for (k, item) in editor.rangeCache {
      // Non-negative
      if item.location < 0 || item.preambleLength < 0 || item.childrenLength < 0 || item.textLength < 0 || item.postambleLength < 0 {
        activeEditor.log(.reconciler, .warning, "SHADOW-COMPARE[\(label)]: negative lengths for key \(k) -> \(item)")
      }
      // Preamble special <= preamble total
      if item.preambleSpecialCharacterLength > item.preambleLength {
        activeEditor.log(.reconciler, .warning, "SHADOW-COMPARE[\(label)]: preambleSpecial > preamble for key \(k)")
      }
      // Range math consistent
      let sum = item.preambleLength + item.childrenLength + item.textLength + item.postambleLength
      if sum != item.range.length {
        activeEditor.log(.reconciler, .warning, "SHADOW-COMPARE[\(label)]: sum(parts)=\(sum) != entireRange.length=\(item.range.length) for key \(k)")
      }
      let childrenStart = item.location + item.preambleLength
      if item.childrenLength > 0 && childrenStart < item.location {
        activeEditor.log(.reconciler, .warning, "SHADOW-COMPARE[\(label)]: childrenStart < location for key \(k)")
      }
      let textStart = item.location + item.preambleLength + item.childrenLength
      if item.textLength > 0 && textStart < item.location {
        activeEditor.log(.reconciler, .warning, "SHADOW-COMPARE[\(label)]: textStart < location for key \(k)")
      }
    }
  }

  // Build a baseline-optimized editor + frontend context
  let baselineFlags = FeatureFlags.optimizedBaseline()
  let cfg = EditorConfig(
    theme: activeEditor.getTheme(),
    plugins: [],
    editorStateVersion:  activeEditor.getEditorState().version,
    nodeKeyMultiplier: nil,
    keyCommands: nil,
    metricsContainer: nil
  )
  let ctx = LexicalReadOnlyTextKitContext(editorConfig: cfg, featureFlags: baselineFlags)
  let baselineEditor = ctx.editor

  // Apply pending editor state into baseline editor (reconciles with baseline optimized flags)
  try? baselineEditor.setEditorState(pendingEditorState)

  let baselineText = ctx.textStorage

  if optimizedText.string != baselineText.string {
    activeEditor.log(.reconciler, .error, "SHADOW-COMPARE: mismatch optimized vs baseline (optLen=\(optimizedText.string.lengthAsNSString()) baseLen=\(baselineText.string.lengthAsNSString()))")
  }

  // Range cache invariants for both editors
  verifyRangeCacheInvariants(editor: activeEditor, label: "optimized")
  verifyRangeCacheInvariants(editor: baselineEditor, label: "baseline")
}
#endif
