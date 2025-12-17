/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)

import Foundation
import LexicalCore

@MainActor
struct NodePartDiff: Sendable {
  public let key: NodeKey
  public let preDelta: Int
  public let textDelta: Int
  public let postDelta: Int
  public var entireDelta: Int { preDelta + textDelta + postDelta }
}

/// Computes per-node deltas for preamble/text/postamble lengths between prev (range cache) and pending state
/// for the current update cycle.
///
/// - For nodes present in both prev (range cache) and next state, deltas are computed normally.
/// - For newly-inserted nodes missing from the prev range cache, the prev lengths are treated as zero.
/// - For removed/detached nodes where the next node is not attached, the next lengths are treated as zero.
@MainActor
func computePartDiffs(
  editor: Editor,
  prevState: EditorState,
  nextState: EditorState,
  prevRangeCache: [NodeKey: RangeCacheItem]? = nil,
  keys: [NodeKey]? = nil
) -> [NodeKey: NodePartDiff] {
  var out: [NodeKey: NodePartDiff] = [:]
  let prevMap = prevRangeCache ?? editor.rangeCache
  let sourceKeys: [NodeKey] = keys ?? Array(editor.dirtyNodes.keys)
  for key in sourceKeys {
    let prev = prevMap[key]
    let next = nextState.nodeMap[key]

    if prev == nil && next == nil {
      continue
    }

    let prePrev = prev?.preambleLength ?? 0
    let textPrev = prev?.textLength ?? 0
    let postPrev = prev?.postambleLength ?? 0

    let nextIsAttached: Bool = {
      guard let next else { return false }
      if key == kRootNodeKey { return true }
      return next.parent != nil
    }()

    let preNext = nextIsAttached ? (next?.getPreamble().lengthAsNSString() ?? 0) : 0
    let textNext = nextIsAttached ? (next?.getTextPart().lengthAsNSString() ?? 0) : 0
    let postNext = nextIsAttached ? (next?.getPostamble().lengthAsNSString() ?? 0) : 0

    let preDelta = preNext - prePrev
    let textDelta = textNext - textPrev
    let postDelta = postNext - postPrev
    if preDelta != 0 || textDelta != 0 || postDelta != 0 {
      out[key] = NodePartDiff(key: key, preDelta: preDelta, textDelta: textDelta, postDelta: postDelta)
    }
  }
  return out
}
#endif  // canImport(UIKit)
