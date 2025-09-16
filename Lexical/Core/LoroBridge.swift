/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
@preconcurrency import Loro
import UIKit

// MARK: - Position Index Types

/// Represents a position in the Loro document tree
struct LoroPosition {
  let nodeKey: NodeKey
  let part: NodePart
  let offset: Int

  enum NodePart {
    case preamble
    case text
    case postamble
    case element  // For positions between children in element nodes
  }
}

/// Item in the position index, similar to RangeCacheItem
struct PositionIndexItem {
  var location: Int = 0
  var preambleLength: Int = 0
  var preambleSpecialCharacterLength: Int = 0
  var childrenLength: Int = 0
  var textLength: Int = 0
  var postambleLength: Int = 0

  var range: NSRange {
    NSRange(
      location: location, length: preambleLength + childrenLength + textLength + postambleLength)
  }

  func textRange() -> NSRange {
    NSRange(location: location + preambleLength + childrenLength, length: textLength)
  }

  func childrenRange() -> NSRange {
    NSRange(location: location + preambleLength, length: childrenLength)
  }
}

// MARK: - Loro Bridge

/// Manages the integration between Lexical and Loro, replacing the reconciler
/// This class is NOT @MainActor and can process updates on any thread
public final class LoroBridge: Sendable {
  private let loroDoc: LoroDoc
  private let positionIndex: PositionIndex
  private let queue = DispatchQueue(label: "com.lexical.lorobridge", attributes: .concurrent)

  // Pending operations to be applied to TextStorage
  private var pendingOps: [TextStorageOp] = []
  private let pendingOpsLock = NSLock()

  // Loro container references
  private var rootTree: LoroMovableList?
  private var nodeContainers: [NodeKey: LoroContainer] = [:]

  init() {
    self.loroDoc = LoroDoc()
    self.positionIndex = PositionIndex()
    setupLoroSubscriptions()
    initializeRootStructure()
  }

  // MARK: - Public API

  /// Apply a native text replacement from UITextView
  func applyNativeReplace(range: NSRange, replacement: String) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async(flags: .barrier) { [self] in
        do {
          // Resolve range to Loro positions
          let startPos = try self.positionIndex.resolve(
            location: range.location, direction: .forward)
          let endPos = try self.positionIndex.resolve(
            location: NSMaxRange(range), direction: .backward)

          // Build and apply Loro ops
          try self.buildAndApplyLoroOps(from: startPos, to: endPos, replacement: replacement)

          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Flush pending operations to TextStorage (must be called on main thread)
  @MainActor
  func flushPendingOpsToTextStorage(textStorage: TextStorage) throws {
    let ops = collectPendingOps()
    guard !ops.isEmpty else { return }

    // Apply ops in a single edit session
    let previousMode = textStorage.mode
    textStorage.mode = .controllerMode
    textStorage.beginEditing()
    defer {
      textStorage.endEditing()
      textStorage.mode = previousMode
    }

    // Apply deletions in reverse order
    for op in ops.reversed() {
      if case .delete(let range) = op {
        textStorage.deleteCharacters(in: range)
      }
    }

    // Apply insertions
    for op in ops {
      if case .insert(let location, let attributedString) = op {
        textStorage.insert(attributedString, at: location)
      }
    }
  }

  /// Initialize from Lexical JSON
  func importFromJSON(_ json: String) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async(flags: .barrier) { [self] in
        do {
          // Parse JSON and build Loro tree
          try self.buildLoroTreeFromJSON(json)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Export to Lexical JSON
  func exportToJSON() async throws -> String {
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          let json = try self.buildJSONFromLoroTree()
          continuation.resume(returning: json)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - Private Implementation

  private func setupLoroSubscriptions() {
    // Subscribe to Loro document changes
    // This will be implemented when we understand Loro's subscription API better
  }

    private func initializeRootStructure() {
    // Create the root container
    rootTree = loroDoc.getMovableList(id: "root")
    
    // Store reference for root node
    if let root = rootTree {
      nodeContainers[kRootNodeKey] = .movableList(root)
    }
  }

  private func buildAndApplyLoroOps(
    from startPos: LoroPosition, to endPos: LoroPosition, replacement: String
  ) throws {
    // Implementation will handle:
    // - Same-node edits
    // - Cross-node edits
    // - Structural changes (merges, splits)
    fatalError("Not implemented yet")
  }

  private func collectPendingOps() -> [TextStorageOp] {
    pendingOpsLock.lock()
    defer { pendingOpsLock.unlock() }

    let ops = pendingOps
    pendingOps.removeAll()
    return ops
  }

  private func buildLoroTreeFromJSON(_ json: String) throws {
    // This will be implemented when we have a proper editor context
    // For now, we need an Editor instance to properly deserialize the JSON
    throw LexicalError.internal("JSON import requires an Editor context")
  }

    /// Build Loro tree from an EditorState
  @MainActor
  func buildLoroTreeFromEditorState(_ editorState: EditorState) throws {
    // Clear existing containers
    nodeContainers.removeAll()
    
    // Re-initialize root
    initializeRootStructure()
    
    // Build Loro tree from the root node
    if let rootNode = editorState.getRootNode(), let rootContainer = rootTree {
      try buildLoroNodeFromLexicalNode(
        node: rootNode,
        parentContainer: rootContainer,
        parentKey: nil
      )
    }
    
    // Rebuild position index
    rebuildPositionIndex()
  }
  
  @MainActor
  private func buildLoroNodeFromLexicalNode(
    node: Node,
    parentContainer: LoroMovableList,
    parentKey: NodeKey?
  ) throws {
    let nodeKey = node.key
    
    // Create node metadata container
    let nodeMetadata = loroDoc.getMap(id: "node_\(nodeKey)")
    try nodeMetadata.insert(key: "type", v: node.type.asLoroValue())
    try nodeMetadata.insert(key: "version", v: node.version.asLoroValue())
    
    // Handle different node types
    if let textNode = node as? TextNode {
      // Create LoroText for text nodes
      let textContainer = loroDoc.getText(id: "text_\(nodeKey)")
      
      let text = textNode.getTextPart()
      if !text.isEmpty {
        try textContainer.insert(pos: 0, s: text)
      }
      
      nodeContainers[nodeKey] = .text(textContainer)
      
      // Add to parent
      let nodeIndex = parentContainer.len()
      try parentContainer.insert(pos: nodeIndex, v: nodeMetadata.id())
      
    } else if let elementNode = node as? ElementNode {
      // Create LoroMovableList for element nodes
      let childrenContainer = loroDoc.getMovableList(id: "children_\(nodeKey)")
      nodeContainers[nodeKey] = .movableList(childrenContainer)
      
      // Add to parent (unless this is root)
      if !(node is RootNode) {
        let nodeIndex = parentContainer.len()
        try parentContainer.insert(pos: nodeIndex, v: nodeMetadata.id())
      }
      
      // Process children
      for child in elementNode.getChildren() {
        try buildLoroNodeFromLexicalNode(
          node: child,
          parentContainer: childrenContainer,
          parentKey: nodeKey
        )
      }
    } else {
      // Handle other node types (DecoratorNode, etc.) as needed
      let nodeIndex = parentContainer.len()
      try parentContainer.insert(pos: nodeIndex, v: nodeMetadata.id())
    }
  }

  private func generateNodeKey() -> NodeKey {
    // Generate a unique node key
    // This should match Lexical's key generation logic
    return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  private func rebuildPositionIndex() {
    // Rebuild the position index from the Loro tree
    positionIndex.rebuild(from: nodeContainers, loroDoc: loroDoc)
  }

  private func buildJSONFromLoroTree() throws -> String {
    // Export Loro tree as Lexical JSON
    fatalError("Not implemented yet")
  }
}

// MARK: - Supporting Types

enum TextStorageOp {
  case delete(NSRange)
  case insert(location: Int, attributedString: NSAttributedString)
}

enum LoroContainer {
  case movableList(LoroMovableList)  // For element nodes with children
  case text(LoroText)  // For text content
  case map(LoroMap)  // For node metadata/attributes
}

// MARK: - Position Index

final class PositionIndex: Sendable {
  private var index: [NodeKey: PositionIndexItem] = [:]
  private let lock = NSLock()

  func resolve(location: Int, direction: UITextStorageDirection) throws -> LoroPosition {
    lock.lock()
    defer { lock.unlock() }

    // Binary search or interval tree implementation
    // For now, linear search as placeholder
    for (nodeKey, item) in index {
      if NSLocationInRange(location, item.range) {
        let relativeLocation = location - item.location

        if relativeLocation < item.preambleLength {
          return LoroPosition(nodeKey: nodeKey, part: .preamble, offset: relativeLocation)
        } else if relativeLocation < item.preambleLength + item.childrenLength {
          // This would need to recurse into children
          continue
        } else if relativeLocation < item.preambleLength + item.childrenLength + item.textLength {
          let textOffset = relativeLocation - item.preambleLength - item.childrenLength
          return LoroPosition(nodeKey: nodeKey, part: .text, offset: textOffset)
        } else {
          let postambleOffset =
            relativeLocation - item.preambleLength - item.childrenLength - item.textLength
          return LoroPosition(nodeKey: nodeKey, part: .postamble, offset: postambleOffset)
        }
      }
    }

    throw LexicalError.invariantViolation("Could not resolve location \(location) to a position")
  }

  func updateFromLoroOps(_ ops: [Any]) {
    lock.lock()
    defer { lock.unlock() }

    // Update index based on Loro operations
    // This will track length changes and update downstream locations
    fatalError("Not implemented yet")
  }

  /// Map an NSRange to a list of node positions it covers
  func map(range: NSRange) -> [(
    nodeKey: NodeKey, part: LoroPosition.NodePart, localStart: Int, localEnd: Int
  )] {
    lock.lock()
    defer { lock.unlock() }

    var results: [(NodeKey, LoroPosition.NodePart, Int, Int)] = []

    for (nodeKey, item) in index {
      let nodeRange = item.range

      // Check if this node intersects with the requested range
      let intersection = NSIntersectionRange(range, nodeRange)
      guard intersection.length > 0 else { continue }

      // Calculate local positions within this node
      let localStart = intersection.location - item.location
      let localEnd = localStart + intersection.length

      // Determine which part(s) of the node are affected
      if localStart < item.preambleLength {
        let preambleEnd = min(localEnd, item.preambleLength)
        results.append((nodeKey, .preamble, localStart, preambleEnd))
      }

      let textStart = item.preambleLength + item.childrenLength
      let textEnd = textStart + item.textLength

      if localEnd > textStart && localStart < textEnd {
        let textLocalStart = max(0, localStart - textStart)
        let textLocalEnd = min(item.textLength, localEnd - textStart)
        results.append((nodeKey, .text, textLocalStart, textLocalEnd))
      }

      if localEnd > textEnd {
        let postambleStart = max(0, localStart - textEnd)
        let postambleEnd = localEnd - textEnd
        results.append((nodeKey, .postamble, postambleStart, postambleEnd))
      }
    }

    return results
  }

  /// Update a node's text length and propagate location changes
  func updateTextLength(nodeKey: NodeKey, newLength: Int, delta: Int) {
    lock.lock()
    defer { lock.unlock() }

    // Update the node's text length
    index[nodeKey]?.textLength = newLength

    // Update all downstream node locations
    var foundNode = false
    for (key, _) in index {
      if foundNode {
        index[key]?.location += delta
      }
      if key == nodeKey {
        foundNode = true
      }
    }
  }

  /// Rebuild the entire index from Loro containers
  func rebuild(from nodeContainers: [NodeKey: LoroContainer], loroDoc: LoroDoc) {
    lock.lock()
    defer { lock.unlock() }

    index.removeAll()
    var currentLocation = 0

    // Start with root node
    if let rootContainer = nodeContainers[kRootNodeKey] {
      currentLocation = buildIndexForNode(
        nodeKey: kRootNodeKey,
        container: rootContainer,
        nodeContainers: nodeContainers,
        loroDoc: loroDoc,
        startLocation: currentLocation
      )
    }
  }

  private func buildIndexForNode(
    nodeKey: NodeKey,
    container: LoroContainer,
    nodeContainers: [NodeKey: LoroContainer],
    loroDoc: LoroDoc,
    startLocation: Int
  ) -> Int {
    var item = PositionIndexItem()
    item.location = startLocation
    var currentLocation = startLocation

    // Get node metadata
    let nodeMetadata = loroDoc.getMap(id: "node_\(nodeKey)")
    // Calculate preamble based on node type
    if let typeValueOrContainer = try? nodeMetadata.get(key: "type"),
       let typeValue = typeValueOrContainer.asValue(),
       case .string(value: let typeString) = typeValue {
      let nodeType = NodeType(rawValue: typeString)

      // Add preamble length based on node type
      switch nodeType {
      case NodeType.heading:
        item.preambleLength = 2  // "# " or "## " etc.
        item.preambleSpecialCharacterLength = 2
      case NodeType.quote:
        item.preambleLength = 2  // "> "
        item.preambleSpecialCharacterLength = 2
      case NodeType.code:
        item.preambleLength = 3  // "```"
        item.preambleSpecialCharacterLength = 3
      default:
        item.preambleLength = 0
        item.preambleSpecialCharacterLength = 0
      }

      currentLocation += item.preambleLength
    }

    // Handle container content
    switch container {
    case .text(let textContainer):
      // Get text length
      item.textLength = Int(textContainer.lenUnicode())
      currentLocation += item.textLength

    case .movableList(let listContainer):
      // Process children
      let childrenStart = currentLocation

      for i in 0..<listContainer.len() {
        if let childValueOrContainer = try? listContainer.get(index: i),
           let childValue = childValueOrContainer.asValue(),
           case .container(value: let childId) = childValue {
          // Extract child key from container ID
          // This is a simplified approach - in reality we'd need proper mapping
          if let childKey = extractNodeKey(from: childId) {
            if let childContainer = nodeContainers[childKey] {
              currentLocation = buildIndexForNode(
                nodeKey: childKey,
                container: childContainer,
                nodeContainers: nodeContainers,
                loroDoc: loroDoc,
                startLocation: currentLocation
              )
            }
          }
        }
      }

      item.childrenLength = currentLocation - childrenStart

    case .map:
      // Maps don't contribute to text length
      break
    }

    // Add postamble if needed
    switch container {
    case .movableList(let listContainer) where listContainer.len() > 0:
      item.postambleLength = 1  // Newline after element nodes with children
      currentLocation += item.postambleLength
    default:
      item.postambleLength = 0
    }

    // Store the item
    index[nodeKey] = item

    return currentLocation
  }

  private func extractNodeKey(from containerId: ContainerId) -> NodeKey? {
    // Extract node key from container ID
    // This is a simplified implementation
    switch containerId {
    case .root(let name, _):
      if name.hasPrefix("children_") {
        return String(name.dropFirst("children_".count))
      } else if name.hasPrefix("text_") {
        return String(name.dropFirst("text_".count))
      }
    default:
      break
    }
    return nil
  }
}

// MARK: - Extensions for Loro Integration

extension NodeType {
  func asLoroValue() -> LoroValue {
    return LoroValue.string(value: self.rawValue)
  }
}

extension Int {
  func asLoroValue() -> LoroValue {
    return LoroValue.i64(value: Int64(self))
  }
}
