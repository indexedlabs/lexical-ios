/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical

#if canImport(UIKit)
@MainActor
final class RapidTypingCaretLayoutTests: XCTestCase {

  func testCaretLayoutDoesNotLagAfterRapidInsertText_ModernOptimizations() throws {
    let cfg = EditorConfig(theme: Theme(), plugins: [])
    let view = TestEditorView(editorConfig: cfg, featureFlags: FeatureFlags.optimizedProfile(.aggressiveEditor))
    // Use a wide view to keep everything on one line so caret X should move monotonically.
    view.view.frame = CGRect(x: 0, y: 0, width: 2000, height: 200)
    view.view.layoutIfNeeded()

    try view.editor.update {
      guard let root = getRoot() else { return }
      let p = createParagraphNode()
      let t = createTextNode(text: "")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 0, focusOffset: 0)
    }

    let textView = view.view.textView
    XCTAssertNotNil(textView.textStorage as? TextStorage, "Expected Lexical TextStorage")

    // Simulate rapid user typing by inserting many single-character updates back-to-back.
    let startPos = textView.position(from: textView.beginningOfDocument, offset: 0)
    XCTAssertNotNil(startPos)
    var lastCaretX = startPos.map { textView.caretRect(for: $0).origin.x } ?? 0
    for i in 0..<50 {
      view.insertText("a")

      let storageLen = textView.textStorage.length
      XCTAssertEqual(textView.selectedRange.length, 0, "selection must stay collapsed at step \(i)")
      XCTAssertEqual(textView.selectedRange.location, storageLen, "caret must stay at end at step \(i)")

      let caretPos = textView.position(from: textView.beginningOfDocument, offset: storageLen)
      XCTAssertNotNil(caretPos, "expected caret position to exist at step \(i)")
      if let caretPos {
        let caretX = textView.caretRect(for: caretPos).origin.x
        XCTAssertGreaterThanOrEqual(caretX, lastCaretX, "caret must not move backwards at step \(i)")
        lastCaretX = caretX
      }
    }

    XCTAssertGreaterThan(lastCaretX, 0, "caret must move forward after typing")
  }
}
#endif
