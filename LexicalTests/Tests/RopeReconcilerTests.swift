/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical
@testable import LexicalCore

// MARK: - RopeReconciler Tests

/// Tests for the RopeReconciler implementation.
/// Note: RopeReconciler is not yet integrated into the Editor.
/// These tests verify the reconciler's API and helper functions work correctly.
/// Full integration testing will be done in Task 5 (Integration & cleanup).
final class RopeReconcilerTests: XCTestCase {

  // MARK: - Helper to create test editor

  private func createTestEditor() throws -> Editor {
    let view = createTestEditorView()
    return view.editor
  }

  // MARK: 4.1 - buildAttributedContent for TextNode

  func testBuildAttributedContentForTextNode() throws {
    let editor = try createTestEditor()
    var capturedTextNode: TextNode?

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = ParagraphNode()
      let text = TextNode(text: "hello")
      capturedTextNode = text
      try paragraph.append([text])
      try root.append([paragraph])
    }

    try editor.read {
      guard let textNode = capturedTextNode else {
        XCTFail("Expected text node")
        return
      }

      let content = RopeReconciler.buildAttributedContent(for: textNode, state: editor.getEditorState(), theme: editor.getTheme())
      XCTAssertEqual(content.string, "hello")
    }
  }

  func testBuildAttributedContentWithFormatting() throws {
    let editor = try createTestEditor()
    var capturedTextNode: TextNode?

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = ParagraphNode()
      let text = TextNode(text: "bold text")
      try text.setBold(true)
      capturedTextNode = text
      try paragraph.append([text])
      try root.append([paragraph])
    }

    try editor.read {
      guard let textNode = capturedTextNode else {
        XCTFail("Expected text node")
        return
      }

      let content = RopeReconciler.buildAttributedContent(for: textNode, state: editor.getEditorState(), theme: editor.getTheme())
      XCTAssertEqual(content.string, "bold text")
      // Note: formatting attributes are applied by AttributeUtils
    }
  }

  // MARK: 4.1 - buildAttributedContent for ElementNode

  func testBuildAttributedContentForParagraphNode() throws {
    let editor = try createTestEditor()
    var capturedParagraph: ParagraphNode?

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = ParagraphNode()
      let text = TextNode(text: "content")
      try paragraph.append([text])
      capturedParagraph = paragraph
      try root.append([paragraph])
    }

    try editor.read {
      guard let paragraph = capturedParagraph else {
        XCTFail("Expected paragraph node")
        return
      }

      let content = RopeReconciler.buildAttributedContent(for: paragraph, state: editor.getEditorState(), theme: editor.getTheme())
      // Paragraph includes preamble + children content + postamble
      XCTAssertTrue(content.string.contains("content"))
    }
  }

  func testBuildAttributedContentForNestedElement() throws {
    let editor = try createTestEditor()
    var capturedParagraph: ParagraphNode?

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = ParagraphNode()
      let text1 = TextNode(text: "first")
      let text2 = TextNode(text: "second")
      try paragraph.append([text1, text2])
      capturedParagraph = paragraph
      try root.append([paragraph])
    }

    try editor.read {
      guard let paragraph = capturedParagraph else {
        XCTFail("Expected paragraph node")
        return
      }

      let content = RopeReconciler.buildAttributedContent(for: paragraph, state: editor.getEditorState(), theme: editor.getTheme())
      XCTAssertTrue(content.string.contains("first"))
      XCTAssertTrue(content.string.contains("second"))
    }
  }

  // MARK: 4.2 - RopeTextStorage integration

  func testRopeTextStorageBasicOperations() throws {
    let storage = RopeTextStorage()

    // Insert
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")
    XCTAssertEqual(storage.string, "hello")
    XCTAssertEqual(storage.length, 5)

    // Append
    storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")
    XCTAssertEqual(storage.string, "hello world")

    // Replace
    storage.replaceCharacters(in: NSRange(location: 6, length: 5), with: "there")
    XCTAssertEqual(storage.string, "hello there")

    // Delete
    storage.replaceCharacters(in: NSRange(location: 5, length: 6), with: "")
    XCTAssertEqual(storage.string, "hello")
  }

  func testRopeTextStorageWithAttributes() throws {
    let storage = RopeTextStorage()
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: LexicalColor.red]
    let attrStr = NSAttributedString(string: "colored", attributes: attrs)

    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: attrStr)

    XCTAssertEqual(storage.string, "colored")

    var range = NSRange()
    let resultAttrs = storage.attributes(at: 3, effectiveRange: &range)
    XCTAssertNotNil(resultAttrs[.foregroundColor])
  }

  // MARK: 4.3 - Editor integration (existing reconciler)

  /// These tests verify the existing editor infrastructure works correctly.
  /// They don't test RopeReconciler directly, but ensure the test setup is valid.

  func testEditorInsertNode() throws {
    let editor = try createTestEditor()

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = ParagraphNode()
      let text = TextNode(text: "hello")
      try paragraph.append([text])
      try root.append([paragraph])
    }

    // Verify text storage has content
    let textStorage = editor.textStorage
    XCTAssertTrue(textStorage?.string.contains("hello") ?? false)
  }

  func testEditorMultipleNodes() throws {
    let editor = try createTestEditor()

    try editor.update {
      guard let root = getRoot() else { return }

      let p1 = ParagraphNode()
      let t1 = TextNode(text: "first")
      try p1.append([t1])

      let p2 = ParagraphNode()
      let t2 = TextNode(text: "second")
      try p2.append([t2])

      try root.append([p1, p2])
    }

    let content = editor.textStorage?.string ?? ""
    XCTAssertTrue(content.contains("first"))
    XCTAssertTrue(content.contains("second"))
  }

  func testEditorMultipleUpdates() throws {
    let editor = try createTestEditor()

    for i in 0..<10 {
      try editor.update {
        guard let root = getRoot() else { return }
        let paragraph = ParagraphNode()
        let text = TextNode(text: "line \(i)")
        try paragraph.append([text])
        try root.append([paragraph])
      }
    }

    let content = editor.textStorage?.string ?? ""
    for i in 0..<10 {
      XCTAssertTrue(content.contains("line \(i)"), "Missing line \(i)")
    }
  }

  // MARK: 4.5 - Selection reconciliation

  func testSelectionState() throws {
    let editor = try createTestEditor()

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = ParagraphNode()
      let text = TextNode(text: "hello")
      try paragraph.append([text])
      try root.append([paragraph])

      // Set selection at end
      let anchor = Point(key: text.key, offset: 5, type: .text)
      let focus = Point(key: text.key, offset: 5, type: .text)
      let selection = RangeSelection(anchor: anchor, focus: focus, format: TextFormat())
      if let activeEditor = getActiveEditor() {
        activeEditor.getEditorState().selection = selection
      }
    }

    try editor.read {
      guard let selection = try? getSelection() as? RangeSelection else { return }
      XCTAssertEqual(selection.anchor.offset, 5)
      XCTAssertEqual(selection.focus.offset, 5)
    }
  }

  // MARK: - Rope data structure integration

  func testRopeBasicOperations() throws {
    var rope = Rope<AttributedChunk>()

    // Insert
    rope.insert(AttributedChunk(text: "hello"), at: 0)
    XCTAssertEqual(rope.length, 5)

    // Insert at end
    rope.insert(AttributedChunk(text: " world"), at: 5)
    XCTAssertEqual(rope.length, 11)

    // Check chunk at position
    let (chunk, offset) = rope.chunk(at: 0)
    XCTAssertEqual(chunk.text, "hello")
    XCTAssertEqual(offset, 0)
  }

  func testRopeSplitAndConcat() throws {
    var rope = Rope<AttributedChunk>()
    rope.insert(AttributedChunk(text: "hello world"), at: 0)

    let (left, right) = rope.split(at: 5)
    XCTAssertEqual(left.length, 5)
    XCTAssertEqual(right.length, 6)

    let combined = Rope<AttributedChunk>.concat(left, right)
    XCTAssertEqual(combined.length, 11)
  }
}
