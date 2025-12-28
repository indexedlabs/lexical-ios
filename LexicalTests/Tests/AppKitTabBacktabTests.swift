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
final class AppKitTabBacktabTests: XCTestCase {

  private func firstParagraphIndent(editor: Editor) throws -> Int {
    var indent = 0
    try editor.read {
      guard let root = getRoot(),
            let paragraph = root.getFirstChild() as? ParagraphNode
      else {
        return
      }
      indent = paragraph.getIndent()
    }
    return indent
  }

  func testTabAndBacktab_IndentAndOutdentParagraph() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      // Editor initialization always creates a default paragraph. Clear it so this test operates
      // on a single known paragraph node.
      _ = try root.clear()
      let p = createParagraphNode()
      let t = createTextNode(text: "Hello")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 5, focusOffset: 5)
    }

    XCTAssertEqual(try firstParagraphIndent(editor: editor), 0)

    testView.view.textView.insertTab(nil)
    XCTAssertEqual(try firstParagraphIndent(editor: editor), 1)

    testView.view.textView.insertBacktab(nil)
    XCTAssertEqual(try firstParagraphIndent(editor: editor), 0)
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
