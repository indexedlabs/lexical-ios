/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore

/// Returns node keys sorted by their string location ascending, breaking ties by longer range first.
/// Mirrors sorting used in RangeHelpers.allNodeKeysSortedByLocation but operates on an explicit cache.
@MainActor
internal func sortedNodeKeysByLocation(rangeCache: [NodeKey: RangeCacheItem]) -> [NodeKey] {
  return rangeCache
    .map { $0 }
    .sorted { a, b in
      if a.value.location != b.value.location {
        return a.value.location < b.value.location
      }
      return a.value.range.length > b.value.range.length
    }
    .map { $0.key }
}

/// Attempts to compute node keys in DFS/location order by traversing the node tree
/// (root-first, then children in order), avoiding an O(n log n) sort.
///
/// Returns `nil` if the derived order does not match the canonical ordering:
/// (location asc, range.length desc).
@MainActor
internal func nodeKeysByTreeDFSOrder(
  state: EditorState,
  rangeCache: [NodeKey: RangeCacheItem]
) -> [NodeKey]? {
  guard !rangeCache.isEmpty else { return [] }

  var order: [NodeKey] = []
  order.reserveCapacity(rangeCache.count)

  var included: Set<NodeKey> = []
  included.reserveCapacity(rangeCache.count)

  var visited: Set<NodeKey> = []
  visited.reserveCapacity(rangeCache.count)

  var stack: [NodeKey] = [kRootNodeKey]
  while let key = stack.popLast() {
    if visited.contains(key) { continue }
    visited.insert(key)

    if rangeCache[key] != nil, included.insert(key).inserted {
      order.append(key)
    }

    guard let el = state.nodeMap[key] as? ElementNode else { continue }
    let children = el.getChildrenKeys(fromLatest: false)
    if children.isEmpty { continue }
    for child in children.reversed() {
      if !visited.contains(child) {
        stack.append(child)
      }
    }
  }

  // Append any keys present in rangeCache but not reachable from the root in this state.
  // Keep canonical ordering for these entries (they're usually detached/stale).
  if included.count != rangeCache.count {
    let remaining = rangeCache
      .filter { !included.contains($0.key) }
      .sorted { a, b in
        if a.value.location != b.value.location { return a.value.location < b.value.location }
        return a.value.range.length > b.value.range.length
      }
      .map { $0.key }
    for key in remaining where included.insert(key).inserted {
      order.append(key)
    }
  }

  guard order.count == rangeCache.count else { return nil }

  // Validate canonical order: (location asc, range.length desc).
  var lastLoc: Int?
  var lastLen: Int?
  for key in order {
    guard let item = rangeCache[key] else { return nil }
    let loc = item.location
    let len = item.range.length
    if let lastLoc {
      if loc < lastLoc { return nil }
      if loc == lastLoc, let lastLen, len > lastLen { return nil }
    }
    lastLoc = loc
    lastLen = len
  }

  return order
}
