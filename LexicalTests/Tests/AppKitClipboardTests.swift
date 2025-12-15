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
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)

