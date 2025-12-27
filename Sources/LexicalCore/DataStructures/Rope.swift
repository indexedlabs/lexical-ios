/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

// MARK: - RopeChunk Protocol

/// Protocol for chunks that can be stored in a Rope.
/// A chunk represents a contiguous piece of content with a measurable length.
public protocol RopeChunk {
  /// The length of this chunk in abstract units (typically UTF-16 code units for text).
  var length: Int { get }

  /// Split this chunk at the given offset, returning left and right halves.
  /// - Parameter offset: The position at which to split (0 to length).
  /// - Returns: A tuple of (left chunk, right chunk).
  func split(at offset: Int) -> (Self, Self)

  /// Concatenate two chunks into one.
  /// - Parameters:
  ///   - left: The left chunk.
  ///   - right: The right chunk.
  /// - Returns: A new chunk containing both.
  static func concat(_ left: Self, _ right: Self) -> Self
}

// MARK: - RopeNode

/// A node in the rope tree.
/// Uses an AVL-like structure for O(log N) operations.
public enum RopeNode<T: RopeChunk> {
  /// A leaf node containing a chunk of content.
  case leaf(T)

  /// A branch node with left and right subtrees.
  /// - Parameters:
  ///   - left: Left subtree
  ///   - right: Right subtree
  ///   - leftLength: Cached length of left subtree for O(log N) indexing
  ///   - height: Height of this subtree for balancing
  indirect case branch(left: RopeNode<T>, right: RopeNode<T>, leftLength: Int, height: Int)

  /// The total length of this subtree.
  public var length: Int {
    switch self {
    case .leaf(let chunk):
      return chunk.length
    case .branch(let left, let right, _, _):
      return left.length + right.length
    }
  }

  /// The height of this subtree (0 for leaves).
  public var height: Int {
    switch self {
    case .leaf:
      return 0
    case .branch(_, _, _, let height):
      return height
    }
  }

  /// Get the chunk and offset within it for a given index.
  /// - Parameter index: The index to look up (0 to length-1).
  /// - Returns: The chunk containing the index and the offset within that chunk.
  public func chunk(at index: Int) -> (T, Int) {
    switch self {
    case .leaf(let chunk):
      return (chunk, index)
    case .branch(let left, let right, let leftLength, _):
      if index < leftLength {
        return left.chunk(at: index)
      } else {
        return right.chunk(at: index - leftLength)
      }
    }
  }

  /// Split this node at the given index.
  /// - Parameter index: The position to split at.
  /// - Returns: A tuple of (left node, right node), either may be nil if empty.
  func split(at index: Int) -> (RopeNode<T>?, RopeNode<T>?) {
    switch self {
    case .leaf(let chunk):
      if index == 0 {
        return (nil, self)
      } else if index >= chunk.length {
        return (self, nil)
      } else {
        let (leftChunk, rightChunk) = chunk.split(at: index)
        let leftNode: RopeNode<T>? = leftChunk.length > 0 ? .leaf(leftChunk) : nil
        let rightNode: RopeNode<T>? = rightChunk.length > 0 ? .leaf(rightChunk) : nil
        return (leftNode, rightNode)
      }

    case .branch(let left, let right, let leftLength, _):
      if index <= 0 {
        return (nil, self)
      } else if index >= self.length {
        return (self, nil)
      } else if index < leftLength {
        // Split point is in left subtree
        let (ll, lr) = left.split(at: index)
        let rightPart = RopeNode.concatOptional(lr, right)
        return (ll, rightPart)
      } else if index == leftLength {
        // Split at boundary
        return (left, right)
      } else {
        // Split point is in right subtree
        let (rl, rr) = right.split(at: index - leftLength)
        let leftPart = RopeNode.concatOptional(left, rl)
        return (leftPart, rr)
      }
    }
  }

  /// Concatenate two optional nodes.
  static func concatOptional(_ left: RopeNode<T>?, _ right: RopeNode<T>?) -> RopeNode<T>? {
    switch (left, right) {
    case (nil, nil):
      return nil
    case (let l?, nil):
      return l
    case (nil, let r?):
      return r
    case (let l?, let r?):
      return RopeNode.concat(l, r)
    }
  }

  /// Concatenate two nodes with balancing.
  static func concat(_ left: RopeNode<T>, _ right: RopeNode<T>) -> RopeNode<T> {
    // If heights are similar, just create a branch
    let heightDiff = left.height - right.height

    if abs(heightDiff) <= 1 {
      return makeBranch(left: left, right: right)
    }

    // Need to rebalance
    if heightDiff > 1 {
      // Left is taller - rotate right
      if case .branch(let ll, let lr, _, _) = left {
        if ll.height >= lr.height {
          // Single right rotation
          let newRight = RopeNode.concat(lr, right)
          return makeBranch(left: ll, right: newRight)
        } else {
          // Double rotation (left-right)
          if case .branch(let lrl, let lrr, _, _) = lr {
            let newLeft = makeBranch(left: ll, right: lrl)
            let newRight = RopeNode.concat(lrr, right)
            return makeBranch(left: newLeft, right: newRight)
          }
        }
      }
    } else if heightDiff < -1 {
      // Right is taller - rotate left
      if case .branch(let rl, let rr, _, _) = right {
        if rr.height >= rl.height {
          // Single left rotation
          let newLeft = RopeNode.concat(left, rl)
          return makeBranch(left: newLeft, right: rr)
        } else {
          // Double rotation (right-left)
          if case .branch(let rll, let rlr, _, _) = rl {
            let newLeft = RopeNode.concat(left, rll)
            let newRight = makeBranch(left: rlr, right: rr)
            return makeBranch(left: newLeft, right: newRight)
          }
        }
      }
    }

    // Fallback - just create a branch
    return makeBranch(left: left, right: right)
  }

  /// Create a branch node with correct metadata.
  private static func makeBranch(left: RopeNode<T>, right: RopeNode<T>) -> RopeNode<T> {
    let leftLength = left.length
    let height = max(left.height, right.height) + 1
    return .branch(left: left, right: right, leftLength: leftLength, height: height)
  }

  /// Convenience method to create a branch node with computed metadata.
  public static func branch(left: RopeNode<T>, right: RopeNode<T>) -> RopeNode<T> {
    makeBranch(left: left, right: right)
  }

  // MARK: - Chunk Iteration

  /// Iterate over all chunks in order, calling the body for each.
  /// This is O(N) total time, visiting each leaf exactly once.
  /// - Parameter body: Closure called with each chunk in order.
  public func forEachChunk(_ body: (T) throws -> Void) rethrows {
    switch self {
    case .leaf(let chunk):
      try body(chunk)
    case .branch(let left, let right, _, _):
      try left.forEachChunk(body)
      try right.forEachChunk(body)
    }
  }

  /// Collect all chunks into an array in order.
  /// This is O(N) total time.
  public var chunks: [T] {
    var result: [T] = []
    forEachChunk { result.append($0) }
    return result
  }
}

// MARK: - Rope

/// A rope data structure for efficient text operations.
/// Provides O(log N) insert, delete, and random access.
public struct Rope<T: RopeChunk> {
  /// The root node, nil for empty rope.
  var root: RopeNode<T>?

  /// Create an empty rope.
  public init() {
    self.root = nil
  }

  /// Create a rope from a single chunk.
  public init(chunk: T) {
    if chunk.length > 0 {
      self.root = .leaf(chunk)
    } else {
      self.root = nil
    }
  }

  /// The total length of the rope.
  public var length: Int {
    root?.length ?? 0
  }

  /// The height of the rope (for debugging/testing).
  public var height: Int {
    root?.height ?? 0
  }

  /// Get the chunk and offset for a given index.
  /// - Parameter index: The index to look up.
  /// - Returns: The chunk containing the index and the offset within it.
  public func chunk(at index: Int) -> (T, Int) {
    guard let root = root else {
      fatalError("Index out of bounds: rope is empty")
    }
    guard index >= 0 && index < root.length else {
      fatalError("Index out of bounds: \(index) not in 0..<\(root.length)")
    }
    return root.chunk(at: index)
  }

  /// Split the rope at the given index.
  /// - Parameter index: The position to split at (0 to length).
  /// - Returns: A tuple of (left rope, right rope).
  public func split(at index: Int) -> (Rope<T>, Rope<T>) {
    guard let root = root else {
      return (Rope(), Rope())
    }

    if index <= 0 {
      return (Rope(), self)
    }
    if index >= root.length {
      return (self, Rope())
    }

    let (leftNode, rightNode) = root.split(at: index)
    return (Rope(root: leftNode), Rope(root: rightNode))
  }

  /// Concatenate two ropes.
  public static func concat(_ left: Rope<T>, _ right: Rope<T>) -> Rope<T> {
    switch (left.root, right.root) {
    case (nil, nil):
      return Rope()
    case (let l?, nil):
      return Rope(root: l)
    case (nil, let r?):
      return Rope(root: r)
    case (let l?, let r?):
      return Rope(root: RopeNode.concat(l, r))
    }
  }

  /// Insert a chunk at the given position.
  /// - Parameters:
  ///   - chunk: The chunk to insert.
  ///   - index: The position to insert at (0 to length).
  public mutating func insert(_ chunk: T, at index: Int) {
    guard chunk.length > 0 else { return }

    let newNode = RopeNode.leaf(chunk)

    if root == nil {
      root = newNode
      return
    }

    let (leftNode, rightNode) = root!.split(at: index)
    let withInsert = RopeNode.concatOptional(leftNode, newNode)
    root = RopeNode.concatOptional(withInsert, rightNode)
  }

  /// Delete a range from the rope.
  /// - Parameter range: The range to delete.
  public mutating func delete(range: Range<Int>) {
    guard range.lowerBound < range.upperBound else { return }
    guard let root = root else { return }

    let (leftPart, rest) = root.split(at: range.lowerBound)
    let (_, rightPart) = rest?.split(at: range.upperBound - range.lowerBound) ?? (nil, nil)

    self.root = RopeNode.concatOptional(leftPart, rightPart)
  }

  /// Replace a range with a new chunk.
  /// - Parameters:
  ///   - range: The range to replace.
  ///   - chunk: The new chunk.
  public mutating func replace(range: Range<Int>, with chunk: T) {
    // Delete the range
    delete(range: range)
    // Insert the new chunk
    insert(chunk, at: range.lowerBound)
  }

  /// Internal initializer from an optional root.
  private init(root: RopeNode<T>?) {
    self.root = root
  }

  // MARK: - Chunk Iteration

  /// Iterate over all chunks in order, calling the body for each.
  /// This is O(N) total time, visiting each leaf exactly once.
  /// - Parameter body: Closure called with each chunk in order.
  public func forEachChunk(_ body: (T) throws -> Void) rethrows {
    try root?.forEachChunk(body)
  }

  /// Collect all chunks into an array in order.
  /// This is O(N) total time.
  public var chunks: [T] {
    root?.chunks ?? []
  }
}
