/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore

/* The range cache is used when updating the NSTextStorage following a change to Lexical's
 * data model. In order to do the update with nuance, changing only the bits of the string
 * that have changed, we need to know where those bits of string are. The range cache
 * is how this information is stored, to save having to regenerate it (an expensive operation).
 */

public struct RangeCacheItem {
  // Legacy absolute location (TextKit 1)
  public var location: Int = 0
  // Stable node index (incrementing counter, never changes once assigned)
  public var nodeIndex: Int = 0
  // DFS position in document order (1-based), updated when DFS order is computed
  // Used for O(log N) Fenwick tree lookups without recomputing global order
  public var dfsPosition: Int = 0
  // the length of the full preamble, including any special characters
  public var preambleLength: Int = 0
  // the length of any special characters in the preamble
  public var preambleSpecialCharacterLength: Int = 0
  public var childrenLength: Int = 0
  public var textLength: Int = 0
  public var postambleLength: Int = 0

  public init() {}

  public var range: NSRange {
    NSRange(
      location: location, length: preambleLength + childrenLength + textLength + postambleLength)
  }

  /// The entire range length (preamble + children + text + postamble)
  public var entireLength: Int {
    preambleLength + childrenLength + textLength + postambleLength
  }

  // MARK: - Fenwick Tree Location Computation

  /// Computes the actual location using the Fenwick tree delta.
  /// - Parameter fenwickTree: The Fenwick tree containing accumulated deltas.
  /// - Returns: The computed location (baseLocation + accumulated delta).
  ///
  /// The `location` field stores the BASE location (from when the node was created or
  /// last fully recomputed). The Fenwick tree stores DELTAS that accumulate as edits
  /// happen. The actual location is: baseLocation + prefixSum(nodeIndex - 1).
  @MainActor
  public func locationFromFenwick(using fenwickTree: FenwickTree? = nil) -> Int {
    guard let tree = fenwickTree, nodeIndex > 0 else { return location }
    // prefixSum(nodeIndex - 1) gives us the accumulated delta for all nodes before this one
    let delta = tree.prefixSum(min(nodeIndex - 1, tree.size))
    return max(0, location + delta)
  }

  /// Computes the actual range using the Fenwick tree delta.
  @MainActor
  public func rangeFromFenwick(using fenwickTree: FenwickTree? = nil) -> NSRange {
    let computedLocation = locationFromFenwick(using: fenwickTree)
    return NSRange(location: computedLocation, length: entireLength)
  }
}

// MARK: - Search for nodes based on range

/*
 * This method is used to search a combination of the node tree and the range cache, to find a Point for a given
 * string location. The string location can be 0 <= x <= length. Location is specified in UTF16 code points, as
 * used by NSString. (Note that Swift string locations are not compatible.)
 *
 * If the string location falls in an invalid place (such as inside a multi-character preamble), this method
 * will return nil.
 *
 * searchDirection is used to break ties for when there would be more than one valid Point for a location. For
 * example, if the location sits between two consecutive Text nodes, the Point could either be at the end of the
 * first Text node, or at the start of the second Text node.
 */
@MainActor
public func pointAtStringLocation(
  _ location: Int, searchDirection: LexicalTextStorageDirection, rangeCache: [NodeKey: RangeCacheItem]
) throws -> Point? {
  do {
    let searchResult = try evaluateNode(
      kRootNodeKey, stringLocation: location, searchDirection: searchDirection,
      rangeCache: rangeCache)
    guard let searchResult else {
      return nil
    }

    @inline(__always)
    func deepestLastDescendant(of element: ElementNode) -> Node? {
      var current: Node = element
      while let el = current as? ElementNode {
        guard let lastKey = el.getChildrenKeys().last, let next = getNodeByKey(key: lastKey) else {
          break
        }
        current = next
      }
      return current
    }

    @inline(__always)
    func rootEndTextPointIfPossible(rootOffset: Int) -> Point? {
      guard searchResult.nodeKey == kRootNodeKey else { return nil }
      guard let root = getNodeByKey(key: kRootNodeKey) as? ElementNode else { return nil }
      guard rootOffset == root.getChildrenSize() else { return nil }
      guard let last = deepestLastDescendant(of: root) as? TextNode else { return nil }
      guard let item = rangeCache[last.getKey()] else { return nil }
      let lastEndLocation = item.location + item.preambleLength + item.childrenLength + item.textLength
      guard lastEndLocation == location else { return nil }
      return Point(key: last.getKey(), offset: last.getTextContentSize(), type: .text)
    }

    switch searchResult.type {
    case .text:
      guard let offset = searchResult.offset else { return nil }
      return Point(key: searchResult.nodeKey, offset: offset, type: .text)
    case .element:
      guard let offset = searchResult.offset else { return nil }
      if let point = rootEndTextPointIfPossible(rootOffset: offset) {
        return point
      }
      return Point(key: searchResult.nodeKey, offset: offset, type: .element)
    case .startBoundary:
      if let _ = getNodeByKey(key: searchResult.nodeKey) as? ElementNode {
        return Point(key: searchResult.nodeKey, offset: 0, type: .element)
      }
      if let _ = getNodeByKey(key: searchResult.nodeKey) as? TextNode {
        return Point(key: searchResult.nodeKey, offset: 0, type: .text)
      }
      return nil
    case .endBoundary:
      if let element = getNodeByKey(key: searchResult.nodeKey) as? ElementNode {
        let offset = element.getChildrenSize()
        if let point = rootEndTextPointIfPossible(rootOffset: offset) {
          return point
        }
        return Point(key: searchResult.nodeKey, offset: offset, type: .element)
      }
      if let text = getNodeByKey(key: searchResult.nodeKey) as? TextNode {
        return Point(key: searchResult.nodeKey, offset: text.getTextContentSize(), type: .text)
      }
      return nil
    case .illegal:
      return nil
    }
  } catch LexicalError.rangeCacheSearch {
    return nil
  }
}

@MainActor
private func evaluateNode(
  _ nodeKey: NodeKey, stringLocation: Int, searchDirection: LexicalTextStorageDirection,
  rangeCache: [NodeKey: RangeCacheItem]
) throws -> RangeCacheSearchResult? {
  guard let rangeCacheItem = rangeCache[nodeKey], let node = getNodeByKey(key: nodeKey) else {
    throw LexicalError.rangeCacheSearch("Couldn't find node or range cache item for key \(nodeKey)")
  }

  if let parentKey = node.parent, let parentRangeCacheItem = rangeCache[parentKey] {
    if stringLocation == parentRangeCacheItem.location
      && rangeCacheItem.location == parentRangeCacheItem.location
      && parentRangeCacheItem.preambleSpecialCharacterLength - parentRangeCacheItem.preambleLength
        == 0
    {
      if node is TextNode {
        return RangeCacheSearchResult(nodeKey: nodeKey, type: .text, offset: 0)
      }
    }
  }

  if !rangeCacheItem.entireRange().byAddingOne().contains(stringLocation) {
    return nil
  }

  if node is TextNode {
    let expandedTextRange = rangeCacheItem.textRange().byAddingOne()
    if expandedTextRange.contains(stringLocation) {
      return RangeCacheSearchResult(
        nodeKey: nodeKey, type: .text, offset: stringLocation - expandedTextRange.location)
    }
  }

  if let node = node as? ElementNode {
    let childrenKeys = node.getChildrenKeys()
    var possibleBoundaryElementResult: RangeCacheSearchResult?
    if !childrenKeys.isEmpty {
      var low = 0
      var high = childrenKeys.count
      while low < high {
        let mid = (low + high) / 2
        guard let item = rangeCache[childrenKeys[mid]] else {
          low = childrenKeys.count
          break
        }
        let end = item.location + item.entireLength
        if end < stringLocation {
          low = mid + 1
        } else {
          high = mid
        }
      }

      if low < childrenKeys.count {
        let leftIndex = low
        var firstIndex = leftIndex
        var secondIndex: Int?
        if let leftItem = rangeCache[childrenKeys[leftIndex]] {
          let leftEnd = leftItem.location + leftItem.entireLength
          let rightCandidate = leftIndex + 1
          if leftEnd == stringLocation,
             rightCandidate < childrenKeys.count,
             let rightItem = rangeCache[childrenKeys[rightCandidate]],
             rightItem.location == stringLocation
          {
            if searchDirection == .forward {
              secondIndex = rightCandidate
            } else {
              firstIndex = rightCandidate
              secondIndex = leftIndex
            }
          }
        }

        // note: I'm using try? because that lets us attempt to still return a selection even if there's an error deeper in the tree.
        // This might be a mistake, in which case we can change it to just `try` and propagate the exception. @amyworrall
        do {
          let childKey = childrenKeys[firstIndex]
          if let result = try? evaluateNode(
            childKey, stringLocation: stringLocation, searchDirection: searchDirection,
            rangeCache: rangeCache)
          {
            if result.type == .text || result.type == .element {
              return result
            }
            if result.type == .startBoundary {
              possibleBoundaryElementResult = RangeCacheSearchResult(
                nodeKey: nodeKey, type: .element, offset: firstIndex)
            }
            if result.type == .endBoundary {
              possibleBoundaryElementResult = RangeCacheSearchResult(
                nodeKey: nodeKey, type: .element, offset: firstIndex + 1)
            }
          }
        }

        if let secondIndex {
          let childKey = childrenKeys[secondIndex]
          if let result = try? evaluateNode(
            childKey, stringLocation: stringLocation, searchDirection: searchDirection,
            rangeCache: rangeCache)
          {
            if result.type == .text || result.type == .element {
              return result
            }
            if result.type == .startBoundary {
              possibleBoundaryElementResult = RangeCacheSearchResult(
                nodeKey: nodeKey, type: .element, offset: secondIndex)
            }
            if result.type == .endBoundary {
              possibleBoundaryElementResult = RangeCacheSearchResult(
                nodeKey: nodeKey, type: .element, offset: secondIndex + 1)
            }
          }
        }
      }
    }

    if let possibleBoundaryElementResult {
      // We do this 'possible result' check so that we prioritise text results where we can.
      return possibleBoundaryElementResult
    }
  }

  if rangeCacheItem.entireRange().length == 0 {
    // caret is at the last row - element with no children
    if stringLocation == rangeCacheItem.location {
      return RangeCacheSearchResult(nodeKey: nodeKey, type: .element, offset: 0)
    }

    // return the appropriate boundary for the search direction!
    let boundary: RangeCacheSearchResultType =
      (searchDirection == .forward) ? .startBoundary : .endBoundary
    return RangeCacheSearchResult(nodeKey: nodeKey, type: boundary, offset: nil)
  }

  if stringLocation == rangeCacheItem.location {
    if rangeCacheItem.preambleLength == 0 && node is ElementNode {
      return RangeCacheSearchResult(nodeKey: nodeKey, type: .element, offset: 0)
    }

    return RangeCacheSearchResult(nodeKey: nodeKey, type: .startBoundary, offset: nil)
  }

  if stringLocation == rangeCacheItem.entireRange().upperBound {
    if rangeCacheItem.selectableRange().length == 0 {
      return RangeCacheSearchResult(nodeKey: nodeKey, type: .element, offset: 0)
    }

    return RangeCacheSearchResult(nodeKey: nodeKey, type: .endBoundary, offset: nil)
  }

  let preambleEnd = rangeCacheItem.location + rangeCacheItem.preambleLength
  if stringLocation == preambleEnd {
    if rangeCacheItem.selectableRange().length == 0 {
      return RangeCacheSearchResult(nodeKey: nodeKey, type: .element, offset: 0)
    }

    if rangeCacheItem.childrenLength == 0 {
      return RangeCacheSearchResult(nodeKey: nodeKey, type: .element, offset: 0)
    }

    return RangeCacheSearchResult(nodeKey: nodeKey, type: .startBoundary, offset: nil)
  }

  return RangeCacheSearchResult(nodeKey: nodeKey, type: .illegal, offset: nil)
}

extension NSRange {
  fileprivate func byAddingOne() -> NSRange {
    return NSRange(location: location, length: length + 1)
  }
}

extension RangeCacheItem {
  public func entireRange() -> NSRange {
    return NSRange(
      location: location, length: preambleLength + childrenLength + textLength + postambleLength)
  }
  public func textRange() -> NSRange {
    return NSRange(location: location + preambleLength + childrenLength, length: textLength)
  }
  public func childrenRange() -> NSRange {
    return NSRange(location: location + preambleLength, length: childrenLength)
  }
  public func selectableRange() -> NSRange {
    return NSRange(
      location: location,
      length: preambleLength + childrenLength + textLength + postambleLength
        - preambleSpecialCharacterLength)
  }
}

private struct RangeCacheSearchResult {
  let nodeKey: NodeKey
  let type: RangeCacheSearchResultType
  let offset: Int?
}

private enum RangeCacheSearchResultType {
  case startBoundary  // the boundary types are converted to element type for the parent element
  case endBoundary
  case text
  case element
  case illegal  // used for if the search is inside a multi-character preamble/postamble
}

@MainActor
internal func updateRangeCacheForTextChange(nodeKey: NodeKey, delta: Int) {
  guard let editor = getActiveEditor(), let node = getNodeByKey(key: nodeKey) as? TextNode else {
    fatalError()
  }

  editor.rangeCache[nodeKey]?.textLength = node.getTextPart().lengthAsNSString()
  let parentKeys = node.getParents().map { $0.getKey() }

  for parentKey in parentKeys {
    editor.rangeCache[parentKey]?.childrenLength += delta
  }

  updateNodeLocationFor(
    nodeKey: kRootNodeKey, nodeIsAfterChangedNode: false, changedNodeKey: nodeKey,
    changedNodeParents: parentKeys, delta: delta)
}

@MainActor
internal func updateRangeCacheForNodePartChange(
  nodeKey: NodeKey,
  part: NodePart,
  newPartLength: Int,
  preambleSpecialCharacterLength: Int? = nil,
  delta: Int
) {
  guard let editor = getActiveEditor(), let node = getNodeByKey(key: nodeKey) else {
    fatalError()
  }

  // Update this node's cached lengths for the part that changed
  if editor.rangeCache[nodeKey] == nil {
    editor.rangeCache[nodeKey] = RangeCacheItem()
    // Assign a future Fenwick node index if missing
    if var item = editor.rangeCache[nodeKey] {
      if item.nodeIndex == 0 {
        item.nodeIndex = editor.nextFenwickNodeIndex
        editor.nextFenwickNodeIndex += 1
        editor.rangeCache[nodeKey] = item
      }
    }
  }
  if part == .preamble {
    editor.rangeCache[nodeKey]?.preambleLength = newPartLength
    if let special = preambleSpecialCharacterLength {
      editor.rangeCache[nodeKey]?.preambleSpecialCharacterLength = special
    }
  } else if part == .postamble {
    editor.rangeCache[nodeKey]?.postambleLength = newPartLength
  } else {
    editor.rangeCache[nodeKey]?.textLength = newPartLength
  }

  // propagate delta to parents' childrenLength, since a child grew/shrank in total length
  let parentKeys = node.getParents().map { $0.getKey() }
  for parentKey in parentKeys {
    editor.rangeCache[parentKey]?.childrenLength += delta
  }

  updateNodeLocationFor(
    nodeKey: kRootNodeKey, nodeIsAfterChangedNode: false, changedNodeKey: nodeKey,
    changedNodeParents: parentKeys, delta: delta)
}

@MainActor
private func updateNodeLocationFor(
  nodeKey: NodeKey, nodeIsAfterChangedNode: Bool, changedNodeKey: NodeKey,
  changedNodeParents: [NodeKey], delta: Int
) {
  guard let editor = getActiveEditor() else {
    fatalError()
  }

  if nodeIsAfterChangedNode {
    editor.rangeCache[nodeKey]?.location += delta
  }

  var isAfterChangedNode = nodeIsAfterChangedNode

  if let elementNode = getNodeByKey(key: nodeKey) as? ElementNode,
    isAfterChangedNode || changedNodeParents.contains(nodeKey)
  {
    for child in elementNode.getChildren() {
      updateNodeLocationFor(
        nodeKey: child.getKey(), nodeIsAfterChangedNode: isAfterChangedNode,
        changedNodeKey: changedNodeKey, changedNodeParents: changedNodeParents, delta: delta)
      if child.getKey() == changedNodeKey || changedNodeParents.contains(child.getKey()) {
        isAfterChangedNode = true
      }
    }
  }
}
