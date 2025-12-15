#if os(macOS) && !targetEnvironment(macCatalyst)
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import EditorHistoryPlugin
@testable import Lexical
@testable import LexicalAppKit
import XCTest

@MainActor
final class AppKitUndoRedoIntegrationTests: XCTestCase {

  func testUndoRedo_UsesLexicalHistoryAndKeepsSelectionStable() throws {
    let testView = createTestEditorView(plugins: [EditorHistoryPlugin()])
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      let p = ParagraphNode()
      let t = TextNode()
      try t.setText("Hello")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 5, focusOffset: 5)
    }

    let textView = testView.view.textView
    let undoItem = NSMenuItem(title: "Undo", action: #selector(TextViewAppKit.undo(_:)), keyEquivalent: "z")
    let redoItem = NSMenuItem(title: "Redo", action: #selector(TextViewAppKit.redo(_:)), keyEquivalent: "Z")

    XCTAssertFalse(textView.validateMenuItem(undoItem))
    XCTAssertFalse(textView.validateMenuItem(redoItem))

    let initialSelectionLocation = testView.selectedRange.location

    testView.insertText("!")
    XCTAssertEqual(testView.text.trimmingCharacters(in: .newlines), "Hello!")

    let selectionAfterInsert = testView.selectedRange.location
    XCTAssertEqual(selectionAfterInsert, initialSelectionLocation + 1)
    XCTAssertTrue(textView.validateMenuItem(undoItem))
    XCTAssertFalse(textView.validateMenuItem(redoItem))

    textView.undo(nil)
    XCTAssertEqual(testView.text.trimmingCharacters(in: .newlines), "Hello")
    XCTAssertEqual(testView.selectedRange.location, initialSelectionLocation)
    XCTAssertFalse(textView.validateMenuItem(undoItem))
    XCTAssertTrue(textView.validateMenuItem(redoItem))

    textView.redo(nil)
    XCTAssertEqual(testView.text.trimmingCharacters(in: .newlines), "Hello!")
    XCTAssertEqual(testView.selectedRange.location, selectionAfterInsert)
    XCTAssertTrue(textView.validateMenuItem(undoItem))
    XCTAssertFalse(textView.validateMenuItem(redoItem))
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)

