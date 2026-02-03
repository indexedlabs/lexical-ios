/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest

@testable import Lexical
@testable import LexicalListPlugin

#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import LexicalAppKit
#endif

@MainActor
class ListItemNodeTests: XCTestCase {
  #if os(macOS) && !targetEnvironment(macCatalyst)
  var view: LexicalAppKit.LexicalView?
  #else
  var view: Lexical.LexicalView?
  #endif

  var editor: Editor? {
    return view?.editor
  }

  override func setUp() {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    view = LexicalAppKit.LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    #else
    view = Lexical.LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    #endif
  }

  override func tearDown() {
    view = nil
  }

  func debugEditor(_ editor: Editor) {
    print((try? getNodeHierarchy(editorState: editor.getEditorState())) ?? "")
    #if !os(macOS) || targetEnvironment(macCatalyst)
    print(view?.textStorage.debugDescription ?? "")
    #endif
    print((try? getSelectionData(editorState: editor.getEditorState())) ?? "")
    print((try? editor.getEditorState().toJSON(outputFormatting: .sortedKeys)) ?? "")
  }

  func testItemCharacterWithNestedNumberedList() throws {
    guard let editor else {
      XCTFail("Editor unexpectedly nil")
      return
    }

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode()
      else {
        XCTFail("should have editor state")
        return
      }

      /*
       1. Item 1
       1. Nested item 1
       2. Nested item 2
       2. Item 2
       */

      // Root level
      let list = ListNode(listType: .number, start: 1)

      let item1 = ListItemNode()
      try item1.append([TextNode(text: "Item 1")])

      let item2 = ListItemNode()
      try item2.append([TextNode(text: "Item 2")])

      // Nested level
      let nestedList = ListNode(listType: .number, start: 1)

      let nestedListItem = ListItemNode()
      try nestedListItem.append([nestedList])

      let nestedItem1 = ListItemNode()
      try nestedItem1.append([TextNode(text: "Nested item 1")])

      let nestedItem2 = ListItemNode()
      try nestedItem2.append([TextNode(text: "Nested item 2")])

      try nestedList.append([nestedItem1, nestedItem2])

      // Putting it together
      try list.append([item1, nestedListItem, item2])
      try rootNode.append([list])

      // Assertions
      let theme = editor.getTheme()

      let item1Attrs =
        item1.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(item1Attrs?.listItemCharacter, "1.")

      let item2Attrs =
        item2.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(item2Attrs?.listItemCharacter, "2.")

      let nestedItem1Attrs =
        nestedItem1.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(nestedItem1Attrs?.listItemCharacter, "1.")

      let nestedItem2Attrs =
        nestedItem2.getAttributedStringAttributes(theme: theme)[.listItem] as? ListItemAttribute
      XCTAssertEqual(nestedItem2Attrs?.listItemCharacter, "2.")
    }
  }

  // Tests that use deleteCharacter - now implemented on both AppKit and UIKit
  func testRemoveEmptyListItemNodes() throws {
    guard let editor else {
      XCTFail("Editor unexpectedly nil")
      return
    }

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode(),
        let firstNode = rootNode.getChildren().first
      else {
        XCTFail("should have editor state")
        return
      }

      let list = ListNode(listType: .bullet, start: 1)

      let item1 = ListItemNode()
      let item2 = ListItemNode()

      try list.append([item1, item2])
      try firstNode.replace(replaceWith: list)

      // select the last list item node
      try item2.select(anchorOffset: nil, focusOffset: nil)
    }

    // from the last list item node, simulate pressing backspace
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      debugEditor(editor)

      try selection.deleteCharacter(isBackwards: true)
    }

    // verify we only have one list item left
    try editor.read {
      debugEditor(editor)

      guard let root = getRoot() else {
        XCTFail("should have root")
        return
      }

      XCTAssertEqual(root.getChildren().count, 1)
      guard let list = root.getChildren().first as? ListNode else {
        XCTFail("should have list")
        return
      }

      XCTAssertEqual(list.getChildren().count, 1)
      guard let item1 = list.getChildren().first as? ListItemNode else {
        XCTFail("should have item1")
        return
      }

      XCTAssertEqual(item1.getChildren().count, 0)

      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      XCTAssert(selection.anchor.type == .element)
      XCTAssert(selection.anchor.key == item1.key)
    }

    // simulate another backspace
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      debugEditor(editor)

      try selection.deleteCharacter(isBackwards: true)
    }

    // verify we collapse the list into a paragraph
    try editor.read {
      guard let root = getRoot() else {
        XCTFail("should have root")
        return
      }

      XCTAssertEqual(root.getChildren().count, 1)
      guard let firstNode = root.getChildren().first else {
        XCTFail("should have first node")
        return
      }

      debugEditor(editor)

      XCTAssertEqual(firstNode.type, .paragraph)
    }
  }

  func testCollapseListItemNodesWithContent() throws {
    guard let editor else {
      XCTFail("Editor unexpectedly nil")
      return
    }

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode(),
        let firstNode = rootNode.getChildren().first
      else {
        XCTFail("should have editor state")
        return
      }

      let list = ListNode(listType: .bullet, start: 1)

      let item1 = ListItemNode()
      let textNode1 = TextNode(text: "1")
      try item1.append([textNode1])

      let item2 = ListItemNode()
      let textNode2 = TextNode(text: "2")
      try item2.append([textNode2])

      try list.append([item1, item2])
      try firstNode.replace(replaceWith: list)

      // select the last list item node
      // select the start of the last line
      try textNode2.select(anchorOffset: 0, focusOffset: 0)
    }

    // from the last list item node, simulate pressing backspace
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      debugEditor(editor)

      try selection.deleteCharacter(isBackwards: true)
    }

    // verify we only have one list item left
    try editor.read {
      debugEditor(editor)

      guard let root = getRoot() else {
        XCTFail("should have root")
        return
      }

      XCTAssertEqual(root.getChildren().count, 1)
      guard let list = root.getChildren().first as? ListNode else {
        XCTFail("should have list")
        return
      }

      XCTAssertEqual(list.getChildren().count, 1)
      guard let item1 = list.getChildren().first as? ListItemNode else {
        XCTFail("should have item1")
        return
      }

      XCTAssertEqual(item1.getChildren().count, 1)
      guard let textNode1 = item1.getChildren().first as? TextNode else {
        XCTFail("should have textNode1")
        return
      }

      XCTAssertEqual(textNode1.getTextPart(), "12")
    }
  }

  func testRemoveListItemNodesWithContent() throws {
    guard let editor else {
      XCTFail("Editor unexpectedly nil")
      return
    }

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode(),
        let firstNode = rootNode.getChildren().first
      else {
        XCTFail("should have editor state")
        return
      }

      let list = ListNode(listType: .bullet, start: 1)

      let item1 = ListItemNode()
      let textNode1 = TextNode(text: "1")
      try item1.append([textNode1])

      let item2 = ListItemNode()
      let textNode2 = TextNode(text: "2")
      try item2.append([textNode2])

      try list.append([item1, item2])
      try firstNode.replace(replaceWith: list)

      // select the last list item node
      // select the start of the last line
      try textNode2.select(anchorOffset: nil, focusOffset: nil)
    }

    // from the last list item node, simulate pressing backspace
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      debugEditor(editor)

      try selection.deleteCharacter(isBackwards: true)
    }

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      guard let root = getRoot() else {
        XCTFail("should have root")
        return
      }

      XCTAssertEqual(root.getChildren().count, 1)
      guard let list = root.getChildren().first as? ListNode else {
        XCTFail("should have list")
        return
      }

      XCTAssertEqual(list.getChildren().count, 2)
      guard let item1 = list.getChildren().first as? ListItemNode,
        let item2 = list.getChildren().last as? ListItemNode
      else {
        XCTFail("should have items")
        return
      }

      XCTAssertEqual(item1.getChildren().count, 1)
      XCTAssertEqual(item2.getChildren().count, 0)

      try selection.deleteCharacter(isBackwards: true)
    }

    // verify we only have one list item left
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      guard let root = getRoot() else {
        XCTFail("should have root")
        return
      }

      XCTAssertEqual(root.getChildren().count, 1)
      guard let list = root.getChildren().first as? ListNode else {
        XCTFail("should have list")
        return
      }

      XCTAssertEqual(list.getChildren().count, 1)
      guard let item1 = list.getChildren().first as? ListItemNode else {
        XCTFail("should have items")
        return
      }

      XCTAssertEqual(item1.getChildren().count, 1)
    }
  }

  #if !os(macOS) || targetEnvironment(macCatalyst)
  // UIKit-specific tests that use UITextView APIs
  func testEditEmptyListItemNodesInMiddleOfList() throws {
    guard let editor else {
      XCTFail("Editor unexpectedly nil")
      return
    }

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode(),
        let firstNode = rootNode.getChildren().first
      else {
        XCTFail("should have editor state")
        return
      }

      let list = ListNode(listType: .bullet, start: 1)

      let item1 = ListItemNode()
      let textNode1 = TextNode(text: "1")
      try item1.append([textNode1])

      let item2 = ListItemNode()
      let item3 = ListItemNode()
      let item4 = ListItemNode()
      let textNode4 = TextNode(text: "4")
      try item4.append([textNode4])

      try list.append([item1, item2, item3, item4])
      try firstNode.replace(replaceWith: list)

      try textNode4.select(anchorOffset: nil, focusOffset: nil)
    }

    view?.textView.selectedRange = NSRange(location: 6, length: 0)

    try editor.update {
      guard let textView = view?.textView as? UITextView else {
        XCTFail("should have textView")
        return
      }

      debugEditor(editor)

      view?.textView.validateNativeSelection(textView)
      onSelectionChange(editor: editor)

      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      try selection.insertText("3")

    }

    try editor.read {
      debugEditor(editor)

      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      XCTAssertEqual(try selection.anchor.getNode().getTextPart(), "3")

      guard
        let list = try selection.anchor.getNode().getParentOrThrow().getParentOrThrow() as? ListNode
      else {
        XCTFail("should have list")
        return
      }

      guard let listItem3 = list.getChildAtIndex(index: 2) as? ListItemNode else {
        XCTFail("should have listItem4")
        return
      }

      XCTAssertEqual(
        listItem3.getTextContent().trimmingCharacters(in: .whitespacesAndNewlines), "3")

      guard let listItem4 = list.getChildAtIndex(index: 3) as? ListItemNode else {
        XCTFail("should have listItem4")
        return
      }

      XCTAssertEqual(
        listItem4.getTextContent().trimmingCharacters(in: .whitespacesAndNewlines), "4")
    }
  }

  /// Regression test: node transforms that create new nodes (e.g. a markdown shortcut
  /// converting "- " into a ListNode/ListItemNode) must have those nodes appear in the
  /// dirty set so the reconciler processes them into the text storage.
  func testTransformCreatedListNodesAreReconciledIntoTextStorage() throws {
    // Set up an editor with ListPlugin and a simple markdown-style text transform
    let listPlugin = ListPlugin()
    let markdownPlugin = MarkdownShortcutTransformPlugin()
    let view = Lexical.LexicalView(
      editorConfig: EditorConfig(
        theme: Theme(),
        plugins: [listPlugin, markdownPlugin]
      ),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode(),
        let paragraphNode = rootNode.getFirstChild() as? ParagraphNode
      else {
        XCTFail("should have editor state")
        return
      }

      let textNode = createTextNode(text: "")
      try paragraphNode.append([textNode])
    }

    // Type "- " to trigger the markdown transform
    try onInsertTextFromUITextView(text: "- ", editor: editor)

    // Allow reconciliation
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    // Verify tree structure
    try editor.read {
      guard let rootNode = getActiveEditorState()?.getRootNode() else {
        XCTFail("Root node not found")
        return
      }
      XCTAssertEqual(rootNode.getChildrenSize(), 1)
      XCTAssert(rootNode.getFirstChild() is ListNode)
    }

    // Verify the .listItem attribute is present in the text storage
    let attributedText = view.textView.attributedText ?? NSAttributedString()
    XCTAssert(attributedText.length > 0, "Text storage should not be empty")

    var foundListItemAttribute: ListItemAttribute?
    attributedText.enumerateAttribute(
      .listItem,
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, _, stop in
      if let attr = value as? ListItemAttribute {
        foundListItemAttribute = attr
        stop.pointee = true
      }
    }

    XCTAssertNotNil(
      foundListItemAttribute,
      "Text storage should contain a .listItem attribute after a transform creates a bullet list"
    )
    XCTAssertEqual(foundListItemAttribute?.listType, .bullet)
  }

  func testDeleteMultipleEmptyListItemNodes() throws {
    guard let editor else {
      XCTFail("Editor unexpectedly nil")
      return
    }

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode(),
        let firstNode = rootNode.getChildren().first
      else {
        XCTFail("should have editor state")
        return
      }

      let list = ListNode(listType: .bullet, start: 1)

      let item1 = ListItemNode()
      let item2 = ListItemNode()
      let item3 = ListItemNode()
      let item4 = ListItemNode()

      try list.append([item1, item2, item3, item4])
      try firstNode.replace(replaceWith: list)

      try item4.select(anchorOffset: nil, focusOffset: nil)
    }

    // from the last list item node, simulate pressing backspace
    try editor.update {
      guard let textView = view?.textView as? UITextView else {
        XCTFail("should have textView")
        return
      }

      debugEditor(editor)

      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      try selection.deleteCharacter(isBackwards: true)
    }

    // from the last list item node, simulate pressing backspace
    try editor.update {
      guard let textView = view?.textView as? UITextView else {
        XCTFail("should have textView")
        return
      }

      debugEditor(editor)

      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      try selection.deleteCharacter(isBackwards: true)
    }

    // from the last list item node, simulate pressing backspace
    try editor.update {
      guard let textView = view?.textView as? UITextView else {
        XCTFail("should have textView")
        return
      }

      debugEditor(editor)

      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("should have selection")
        return
      }

      try selection.deleteCharacter(isBackwards: true)
    }
  }
  #endif

  #if os(macOS) && !targetEnvironment(macCatalyst)
  /// AppKit variant of the transform-created dirty nodes regression test.
  func testTransformCreatedListNodesAreReconciledIntoTextStorage_AppKit() throws {
    let listPlugin = ListPlugin()
    let markdownPlugin = MarkdownShortcutTransformPlugin()
    let view = LexicalAppKit.LexicalView(
      editorConfig: EditorConfig(
        theme: Theme(),
        plugins: [listPlugin, markdownPlugin]
      ),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor

    try editor.update {
      guard
        let editorState = getActiveEditorState(),
        let rootNode = editorState.getRootNode(),
        let paragraphNode = rootNode.getFirstChild() as? ParagraphNode
      else {
        XCTFail("should have editor state")
        return
      }

      let textNode = createTextNode(text: "")
      try paragraphNode.append([textNode])
      try textNode.select(anchorOffset: 0, focusOffset: 0)
    }

    // Use AppKit's insertText to trigger the same command path as UIKit's onInsertTextFromUITextView
    view.textView.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))

    // Allow reconciliation
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    // Verify tree structure
    try editor.read {
      guard let rootNode = getActiveEditorState()?.getRootNode() else {
        XCTFail("Root node not found")
        return
      }
      XCTAssertEqual(rootNode.getChildrenSize(), 1)
      XCTAssert(rootNode.getFirstChild() is ListNode)
    }

    // Verify the .listItem attribute is present in the text storage
    let attributedText = view.attributedText
    XCTAssert(attributedText.length > 0, "Text storage should not be empty")

    var foundListItemAttribute: ListItemAttribute?
    attributedText.enumerateAttribute(
      .listItem,
      in: NSRange(location: 0, length: attributedText.length),
      options: []
    ) { value, _, stop in
      if let attr = value as? ListItemAttribute {
        foundListItemAttribute = attr
        stop.pointee = true
      }
    }

    XCTAssertNotNil(
      foundListItemAttribute,
      "Text storage should contain a .listItem attribute after a transform creates a bullet list"
    )
    XCTAssertEqual(foundListItemAttribute?.listType, .bullet)
  }
  #endif

}

// MARK: - Test Helpers

/// Minimal markdown shortcut plugin for testing transform-created dirty node reconciliation.
private class MarkdownShortcutTransformPlugin: Plugin {
  weak var editor: Editor?

  func setUp(editor: Editor) {
    self.editor = editor
    _ = editor.addNodeTransform(
      nodeType: NodeType.text,
      transform: { [weak self] node in
        try self?.transformToList(node: node)
      }
    )
  }

  func tearDown() {}

  private func transformToList(node: Node) throws {
    guard
      let textNode = node as? TextNode,
      let parent = textNode.getParent() as? ParagraphNode,
      textNode == parent.getFirstChild()
    else { return }

    let text = textNode.getTextContent()
    guard text.hasPrefix("- ") else { return }

    let listItemNode = ListItemNode()
    let listNode = createListNode(listType: .bullet)
    let newText = String(text.dropFirst(2))

    let listItemNodeChild = createTextNode(text: newText)
    try listItemNodeChild.select(anchorOffset: 0, focusOffset: 0)
    try listItemNode.append([listItemNodeChild])
    try listNode.append([listItemNode])
    try parent.replace(replaceWith: listNode)
  }
}
