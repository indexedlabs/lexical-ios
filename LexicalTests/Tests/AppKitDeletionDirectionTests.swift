#if os(macOS) && !targetEnvironment(macCatalyst)
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
@testable import Lexical
@testable import LexicalAppKit
import XCTest

@MainActor
final class AppKitDeletionDirectionTests: XCTestCase {
  func testDeleteForward_DeletesNextCharacter() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      let p = createParagraphNode()
      let t = createTextNode(text: "Hello")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 0, focusOffset: 0)
    }

    testView.view.textView.deleteForward(nil)
    XCTAssertEqual(testView.text.trimmingCharacters(in: .newlines), "ello")
  }

  func testDeleteWordForward_DeletesWordAhead() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      let p = createParagraphNode()
      let t = createTextNode(text: "Hello world")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 6, focusOffset: 6) // start of 'world'
    }

    testView.view.textView.deleteWordForward(nil)
    XCTAssertEqual(testView.text.trimmingCharacters(in: .newlines), "Hello ")
  }

  func testDeleteToEndOfLine_DeletesRemainderOfLine() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      let p = createParagraphNode()
      let t = createTextNode(text: "Hello world")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 2, focusOffset: 2) // after "He"
    }

    testView.view.textView.deleteToEndOfLine(nil)
    XCTAssertEqual(testView.text.trimmingCharacters(in: .newlines), "He")
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)

