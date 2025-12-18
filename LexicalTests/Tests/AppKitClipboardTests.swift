/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(macOS) && !targetEnvironment(macCatalyst)

import AppKit
@testable import Lexical
@testable import LexicalAppKit
import XCTest

@MainActor
final class AppKitClipboardTests: XCTestCase {

  private func makeUniquePasteboard() -> NSPasteboard {
    let name = NSPasteboard.Name("lexical-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    return pasteboard
  }

  func testCopy_WritesLexicalNodesToCustomPasteboard() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let pasteboard = makeUniquePasteboard()

    testView.insertText("Hello world")

    let full = testView.attributedTextString as NSString
    let worldRange = full.range(of: "world")
    XCTAssertNotEqual(worldRange.location, NSNotFound, "Should find 'world' in text storage")

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try selection.applySelectionRange(worldRange, affinity: .forward)
      try onCopyFromTextView(editor: editor, pasteboard: pasteboard)

      let lexicalType = NSPasteboard.PasteboardType(LexicalConstants.pasteboardIdentifier)
      guard let data = pasteboard.data(forType: lexicalType) else {
        XCTFail("No lexical data on pasteboard")
        return
      }

      let json = try JSONDecoder().decode(SerializedNodeArray.self, from: data)
      let copiedText = json.nodeArray.compactMap { ($0 as? TextNode)?.getText_dangerousPropertyAccess() }.joined()
      XCTAssertEqual(copiedText, "world")
    }

    XCTAssertEqual(pasteboard.string(forType: .string), "world")
    XCTAssertNotNil(pasteboard.data(forType: .rtf), "Expected RTF payload for rich-text paste")
  }

  func testCut_WritesLexicalNodesToCustomPasteboardAndDeletesSelection() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let pasteboard = makeUniquePasteboard()

    testView.insertText("Hello world")

    let full = testView.attributedTextString as NSString
    let worldRange = full.range(of: "world")
    XCTAssertNotEqual(worldRange.location, NSNotFound, "Should find 'world' in text storage")

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try selection.applySelectionRange(worldRange, affinity: .forward)
      try onCutFromTextView(editor: editor, pasteboard: pasteboard)

      let lexicalType = NSPasteboard.PasteboardType(LexicalConstants.pasteboardIdentifier)
      guard let data = pasteboard.data(forType: lexicalType) else {
        XCTFail("No lexical data on pasteboard")
        return
      }

      let json = try JSONDecoder().decode(SerializedNodeArray.self, from: data)
      let cutText = json.nodeArray.compactMap { ($0 as? TextNode)?.getText_dangerousPropertyAccess() }.joined()
      XCTAssertEqual(cutText, "world")
    }

    var out = ""
    try editor.read { out = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(out, "Hello ", "Cut should remove the selected text from the editor")
  }

  func testPaste_InsertsLexicalNodesFromCustomPasteboard() throws {
    let pasteboard = makeUniquePasteboard()

    // Copy "world" to the custom pasteboard from a source editor
    do {
      let source = createTestEditorView()
      let editor = source.editor

      source.insertText("Hello world")

      let full = source.attributedTextString as NSString
      let worldRange = full.range(of: "world")
      XCTAssertNotEqual(worldRange.location, NSNotFound, "Should find 'world' in text storage")

      try editor.update {
        guard let selection = try getSelection() as? RangeSelection else {
          XCTFail("Expected RangeSelection")
          return
        }
        try selection.applySelectionRange(worldRange, affinity: .forward)
        try onCopyFromTextView(editor: editor, pasteboard: pasteboard)
      }
    }

    // Paste into a destination editor
    let dest = createTestEditorView()
    let destEditor = dest.editor
    dest.insertText("Hello ")

    try destEditor.update {
      try onPasteFromTextView(editor: destEditor, pasteboard: pasteboard)
    }

    var out = ""
    try destEditor.read { out = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(out, "Hello world")
  }

  func testPaste_FallsBackToPlainText_WhenNoLexicalData() throws {
    let pasteboard = makeUniquePasteboard()
    pasteboard.setString("Plain", forType: .string)

    let dest = createTestEditorView()
    let editor = dest.editor
    try editor.update {
      try onPasteFromTextView(editor: editor, pasteboard: pasteboard)
    }

    var out = ""
    try editor.read { out = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(out, "Plain")
  }

  func testPaste_FallsBackToLegacyPlainTextType_WhenNoLexicalData() throws {
    let pasteboard = makeUniquePasteboard()
    let legacyStringType = NSPasteboard.PasteboardType("NSStringPboardType")
    pasteboard.declareTypes([legacyStringType], owner: nil)
    pasteboard.setString("Plain", forType: legacyStringType)

    let dest = createTestEditorView()
    let editor = dest.editor
    try editor.update {
      try onPasteFromTextView(editor: editor, pasteboard: pasteboard)
    }

    var out = ""
    try editor.read { out = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(out, "Plain")
  }

  func testPaste_FallsBackToRTF_WhenNoLexicalData() throws {
    let pasteboard = makeUniquePasteboard()

    let bold = NSAttributedString(
      string: "Bold",
      attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
    )
    let data = try bold.data(
      from: NSRange(location: 0, length: bold.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    pasteboard.declareTypes([.rtf], owner: nil)
    pasteboard.setData(data, forType: .rtf)

    let dest = createTestEditorView()
    let editor = dest.editor
    try editor.update {
      try onPasteFromTextView(editor: editor, pasteboard: pasteboard)
    }

    try editor.read {
      guard let root = getRoot(),
            let p = root.getFirstChild() as? ParagraphNode,
            let t = p.getFirstChild() as? TextNode
      else {
        XCTFail("Expected a paragraph with a text node")
        return
      }
      XCTAssertEqual(t.getTextPart(), "Bold")
      XCTAssertTrue(t.format.bold, "Expected bold formatting to be preserved from RTF")
    }
  }

  func testPaste_FallsBackToLegacyRTFType_WhenNoLexicalData() throws {
    let pasteboard = makeUniquePasteboard()

    let bold = NSAttributedString(
      string: "Bold",
      attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
    )
    let data = try bold.data(
      from: NSRange(location: 0, length: bold.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )

    let legacyRTFType = NSPasteboard.PasteboardType("NSRTFPboardType")
    pasteboard.declareTypes([legacyRTFType], owner: nil)
    pasteboard.setData(data, forType: legacyRTFType)

    let dest = createTestEditorView()
    let editor = dest.editor
    try editor.update {
      try onPasteFromTextView(editor: editor, pasteboard: pasteboard)
    }

    try editor.read {
      guard let root = getRoot(),
            let p = root.getFirstChild() as? ParagraphNode,
            let t = p.getFirstChild() as? TextNode
      else {
        XCTFail("Expected a paragraph with a text node")
        return
      }
      XCTAssertEqual(t.getTextPart(), "Bold")
      XCTAssertTrue(t.format.bold, "Expected bold formatting to be preserved from RTF")
    }
  }

  func testPaste_PrefersLexicalNodesOverRTF_WhenBothPresent_PreservesDecoratorNode() throws {
    let pasteboard = makeUniquePasteboard()

    // Copy a decorator node into the pasteboard (writes Lexical nodes + RTF + plain text)
    do {
      let source = createTestEditorView()
      let editor = source.editor
      try registerTestSerializableDecoratorNode(on: editor)

      var decoratorKey: NodeKey?
      try editor.update {
        guard let root = getRoot() else { return }
        for child in root.getChildren() { try child.remove() }
        let paragraph = createParagraphNode()
        let left = createTextNode(text: "A")
        let decorator = TestSerializableDecoratorNodeCrossplatform()
        let right = createTextNode(text: "B")
        try paragraph.append([left, decorator, right])
        decoratorKey = decorator.getKey()
        try root.append([paragraph])

        guard let decoratorKey else { return }
        try setSelection(NodeSelection(nodes: [decoratorKey]))
      }

      try editor.update {
        try onCopyFromTextView(editor: editor, pasteboard: pasteboard)
      }
    }

    func containsDecoratorNode(_ editor: Editor) throws -> Bool {
      var found = false
      try editor.read {
        found = editor.getEditorState().nodeMap.values.contains(where: { $0 is TestSerializableDecoratorNodeCrossplatform })
      }
      return found
    }

    // Paste with Lexical nodes present → decorator should round-trip
    do {
      let dest = createTestEditorView()
      let editor = dest.editor
      try registerTestSerializableDecoratorNode(on: editor)

      try editor.update {
        guard let root = getRoot() else { return }
        for child in root.getChildren() { try child.remove() }
        let paragraph = createParagraphNode()
        try root.append([paragraph])
        try paragraph.selectStart()
      }

      try editor.update {
        try onPasteFromTextView(editor: editor, pasteboard: pasteboard)
      }

      XCTAssertTrue(try containsDecoratorNode(editor))
    }

    // Copy only RTF into a new pasteboard (simulate non-Lexical source) → decorator should NOT be recreated
    guard let rtfData = pasteboard.data(forType: .rtf) else {
      XCTFail("Expected RTF data on pasteboard")
      return
    }
    let rtfOnlyPasteboard = makeUniquePasteboard()
    rtfOnlyPasteboard.declareTypes([.rtf], owner: nil)
    rtfOnlyPasteboard.setData(rtfData, forType: .rtf)

    do {
      let dest = createTestEditorView()
      let editor = dest.editor
      try registerTestSerializableDecoratorNode(on: editor)

      try editor.update {
        guard let root = getRoot() else { return }
        for child in root.getChildren() { try child.remove() }
        let paragraph = createParagraphNode()
        try root.append([paragraph])
        try paragraph.selectStart()
      }

      try editor.update {
        try onPasteFromTextView(editor: editor, pasteboard: rtfOnlyPasteboard)
      }

      XCTAssertFalse(try containsDecoratorNode(editor))
    }
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
