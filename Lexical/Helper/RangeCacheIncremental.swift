/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore
@MainActor
internal func applyLengthDelta(
  editor: Editor,
  nodeKey: NodeKey,
  part: NodePart,
  delta: Int
) {
  guard delta != 0 else { return }
  // Update this node's cached length field by delta.
  if var item = editor.rangeCache[nodeKey] {
    switch part {
    case .preamble: item.preambleLength &+= delta
    case .postamble: item.postambleLength &+= delta
    case .text: item.textLength &+= delta
    }
    editor.rangeCache[nodeKey] = item
  }
  // Propagate childrenLength change to all parents
  if let node = getNodeByKey(key: nodeKey) {
    var parent = node.getParent()
    while let p = parent {
      let pk = p.getKey()
      if var it = editor.rangeCache[pk] { it.childrenLength &+= delta; editor.rangeCache[pk] = it }
      parent = p.getParent()
    }
  }
}

// Incrementally shift absolute locations in the range cache without a full rebuild.
// For each (startKey, endKeyExclusive, delta), apply `delta` to all nodes strictly after
// startKey up to (but excluding) endKeyExclusive, if provided. Uses one prefix pass.
@MainActor
internal func applyIncrementalLocationShifts(
  rangeCache: inout [NodeKey: RangeCacheItem],
  ranges: [(startKey: NodeKey, endKeyExclusive: NodeKey?, delta: Int)],
  order: [NodeKey],
  indexOf: [NodeKey: Int]
) {
  var scratch: [Int] = []
  applyIncrementalLocationShifts(
    rangeCache: &rangeCache,
    ranges: ranges,
    order: order,
    indexOf: indexOf,
    diffScratch: &scratch
  )
}

@MainActor
internal func applyIncrementalLocationShifts(
  rangeCache: inout [NodeKey: RangeCacheItem],
  ranges: [(startKey: NodeKey, endKeyExclusive: NodeKey?, delta: Int)],
  order: [NodeKey],
  indexOf: [NodeKey: Int],
  diffScratch: inout [Int]
) {
  let n = order.count
  guard !ranges.isEmpty, n > 0 else { return }
  if diffScratch.count < n {
    diffScratch.append(contentsOf: repeatElement(0, count: n - diffScratch.count))
  }

  var didMutate = false
  var touched: [Int] = []
  touched.reserveCapacity(min(ranges.count * 2, 64))

  for (s, e, d) in ranges {
    guard d != 0, let si1 = indexOf[s] else { continue }
    let si = si1 - 1 // convert 1-based to 0-based index in `order`
    let startPos = si + 1 // exclusive: start shifting strictly after startKey
    if startPos < n {
      diffScratch[startPos] &+= d
      touched.append(startPos)
      didMutate = true
    }
    if let e, let ei1 = indexOf[e] {
      let ei = ei1 - 1
      if ei < n {
        diffScratch[ei] &-= d
        touched.append(ei)
        didMutate = true
      }
    }
  }

  guard didMutate else { return }

  // Prefix accumulate and apply to rangeCache locations
  var running = 0
  for (i, key) in order.enumerated() {
    running &+= diffScratch[i]
    if running == 0 { continue }
    if var item = rangeCache[key] {
      item.location = max(0, item.location + running)
      rangeCache[key] = item
    }
  }

  // Reset touched indices for next run (duplicates OK)
  for idx in touched { diffScratch[idx] = 0 }
}

// Batch-apply length deltas for multiple nodes/parts and propagate
// childrenLength to ancestors in an aggregated manner. Returns a map of
// startKey -> total delta suitable for Fenwick range shifts (exclusive start).
@MainActor
internal func applyLengthDeltasBatch(
  editor: Editor,
  changes: [(nodeKey: NodeKey, part: NodePart, delta: Int)]
) -> [NodeKey: Int] {
  if changes.isEmpty { return [:] }
  var startShift: [NodeKey: Int] = [:]
  startShift.reserveCapacity(changes.count)
  var parentAccum: [NodeKey: Int] = [:]
  parentAccum.reserveCapacity(changes.count * 4)

  // 1) Update node part lengths and collect per-node total deltas
  for (key, part, delta) in changes {
    if delta == 0 { continue }
    if var item = editor.rangeCache[key] {
      switch part {
      case .preamble: item.preambleLength &+= delta
      case .postamble: item.postambleLength &+= delta
      case .text: item.textLength &+= delta
      }
      editor.rangeCache[key] = item
    }
    startShift[key, default: 0] &+= delta
    // 2) Accumulate childrenLength propagation for all ancestors
    if let node = getNodeByKey(key: key) {
      var parent = node.getParent()
      while let p = parent {
        parentAccum[p.getKey(), default: 0] &+= delta
        parent = p.getParent()
      }
    }
  }

  // 3) Apply aggregated childrenLength changes to ancestors
  if !parentAccum.isEmpty {
    for (pk, d) in parentAccum { if d != 0, var it = editor.rangeCache[pk] { it.childrenLength &+= d; editor.rangeCache[pk] = it } }
  }
  return startShift
}
