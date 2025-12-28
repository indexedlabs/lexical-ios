/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore

@MainActor
internal func insertPlainText(selection: RangeSelection, text: String) throws {
  var stringArray: [String] = []
  let range = text.startIndex..<text.endIndex
  text.enumerateSubstrings(in: range, options: .byParagraphs) { subString, _, _, _ in
    stringArray.append(subString ?? "")
  }

  if stringArray.count == 1 {
    try selection.insertText(text)
  } else {
    var nodes: [Node] = []
    for (index, part) in stringArray.enumerated() {
      let textNode = createTextNode(text: String(part))
      if index != 0 {
        let paragraphNode = createParagraphNode()
        try paragraphNode.append([textNode])
        nodes.append(paragraphNode)
      } else {
        nodes.append(textNode)
      }
    }

    // Always position cursor at end of pasted content (selectStart: false)
    _ = try selection.insertNodes(nodes: nodes, selectStart: false)
  }
}

@MainActor
public func insertGeneratedNodes(editor: Editor, nodes: [Node], selection: RangeSelection) throws {
  return try basicInsertStrategy(nodes: nodes, selection: selection)
}

@MainActor
func basicInsertStrategy(nodes: [Node], selection: RangeSelection) throws {
  var topLevelBlocks = [Node]()
  var currentBlock: ElementNode?
  for node in nodes {
    if ((node as? ElementNode)?.isInline() ?? false) || isTextNode(node) || isLineBreakNode(node) {
      if let currentBlock {
        try currentBlock.append([node])
      } else {
        let paragraphNode = createParagraphNode()
        topLevelBlocks.append(paragraphNode)
        try paragraphNode.append([node])
        currentBlock = paragraphNode
      }
    } else {
      topLevelBlocks.append(node)
      currentBlock = nil
    }
  }

  _ = try selection.insertNodes(nodes: topLevelBlocks, selectStart: false)
}

@MainActor
func appendNodesToArray(
  editor: Editor,
  selection: BaseSelection?,
  currentNode: Node,
  targetArray: [Node] = []
) throws -> (shouldInclude: Bool, outArray: [Node]) {
  var array = targetArray
  var shouldInclude = selection != nil ? try currentNode.isSelected() : true
  let shouldExclude = (currentNode as? ElementNode)?.excludeFromCopy() ?? false
  var clone = try cloneWithProperties(node: currentNode)
  (clone as? ElementNode)?.children = []

  if let textClone = clone as? TextNode, let selection {
    clone = try sliceSelectedTextNodeContent(selection: selection, textNode: textClone)
  }

  guard let key = try generateKey(node: clone) else {
    throw LexicalError.invariantViolation("Could not generate key")
  }
  clone.key = key
  editor.getEditorState().nodeMap[key] = clone

  let children = (currentNode as? ElementNode)?.getChildren() ?? []
  var cloneChildren: [Node] = []

  for childNode in children {
    let internalCloneChildren: [Node] = []
    let shouldIncludeChild = try appendNodesToArray(
      editor: editor,
      selection: selection,
      currentNode: childNode,
      targetArray: internalCloneChildren
    )

    if !shouldInclude && shouldIncludeChild.shouldInclude
      && ((currentNode as? ElementNode)?.extractWithChild(
        child: childNode, selection: selection, destination: .clone) ?? false)
    {
      shouldInclude = true
    }

    cloneChildren.append(contentsOf: shouldIncludeChild.outArray)
  }

  for child in cloneChildren {
    (clone as? ElementNode)?.children.append(child.key)
  }

  if shouldInclude && !shouldExclude {
    array.append(clone)
  } else if let children = (clone as? ElementNode)?.children {
    for childKey in children {
      if let childNode = editor.getEditorState().nodeMap[childKey] {
        array.append(childNode)
      }
    }
  }

  return (shouldInclude, array)
}

@MainActor
public func generateArrayFromSelectedNodes(editor: Editor, selection: BaseSelection?) throws -> (
  namespace: String,
  nodes: [Node]
) {
  var nodes: [Node] = []
  guard let root = getRoot() else {
    return ("", [])
  }
  for topLevelNode in root.getChildren() {
    var nodeArray: [Node] = []
    nodeArray = try appendNodesToArray(
      editor: editor, selection: selection, currentNode: topLevelNode, targetArray: nodeArray
    ).outArray
    nodes.append(contentsOf: nodeArray)
  }
  return (
    namespace: "lexical",
    nodes
  )
}

// MARK: - Extensions

extension NSAttributedString {
  public func splitByNewlines() -> [NSAttributedString] {
    var result = [NSAttributedString]()
    var rangeArray: [NSRange] = []

    (string as NSString).enumerateSubstrings(
      in: NSRange(location: 0, length: (string as NSString).length),
      options: .byParagraphs
    ) { _, subStringRange, _, _ in
      rangeArray.append(subStringRange)
    }

    for range in rangeArray {
      let attributedString = attributedSubstring(from: range)
      result.append(attributedString)
    }
    return result
  }
}
