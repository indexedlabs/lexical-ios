/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)

import XCTest
@testable import Lexical

@MainActor
final class UIKitAutoScrollCaretIntoViewTests: XCTestCase {
  func testInsertParagraphScrollsCaretIntoViewWhenOffscreen() throws {
    let window = UIWindow(frame: UIScreen.main.bounds)
    let vc = UIViewController()
    window.rootViewController = vc
    window.makeKeyAndVisible()

    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags.optimizedProfile(.aggressiveEditor)
    )
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
    vc.view.addSubview(view)
    vc.view.layoutIfNeeded()

    XCTAssertNotNil(view.window)
    XCTAssertNotNil(view.textView.window)

    XCTAssertTrue(view.textViewBecomeFirstResponder())
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertTrue(view.textViewIsFirstResponder)

    let editor = view.editor
    var lastTextKey: NodeKey?
    try editor.update {
      guard let root = getRoot() else { return }
      for i in 0..<80 {
        let p = createParagraphNode()
        let t = createTextNode(text: "Line \(i)")
        lastTextKey = t.getKey()
        try p.append([t])
        try root.append([p])
      }
      if let lastTextKey, let t = getNodeByKey(key: lastTextKey) as? TextNode {
        _ = try t.select(anchorOffset: nil, focusOffset: nil)
      }
    }

    // Force layout so contentSize is accurate before scrolling assertions.
    view.textView.layoutIfNeeded()
    _ = view.layoutManager.glyphRange(for: view.textView.textContainer)

    XCTAssertGreaterThan(view.textView.contentSize.height, view.textView.bounds.height)

    view.textView.setContentOffset(.zero, animated: false)
    view.textView.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
    XCTAssertGreaterThan(view.textView.contentOffset.y, 0, "Expected manual scrolling to work in test harness")
    view.textView.setContentOffset(.zero, animated: false)
    XCTAssertGreaterThan(view.textView.selectedRange.location, view.textView.textStorage.length / 2)
    let selectionBefore = view.textView.selectedRange
    XCTAssertTrue(view.textView.isScrollEnabled)

    guard let endBefore = view.textView.selectedTextRange?.end else {
      return XCTFail("Missing selectedTextRange.end")
    }
    let caretRectBefore = view.textView.caretRect(for: endBefore)
    XCTAssertGreaterThan(caretRectBefore.maxY, view.textView.bounds.maxY, "Caret should start offscreen after scrolling to top")

    // Simulate pressing Return/Enter in the native text view.
    view.textView.insertText("\n")

    // Allow any deferred layout/scroll-to-visible work to settle.
    let exp = expectation(description: "Scroll settles")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)

    let selectionAfter = view.textView.selectedRange
    XCTAssertNotEqual(selectionAfter, selectionBefore)
    XCTAssertGreaterThan(view.textView.contentOffset.y, 0, "Expected textView to scroll vertically to keep caret visible")

    guard let endAfter = view.textView.selectedTextRange?.end else {
      return XCTFail("Missing selectedTextRange.end after insertParagraph")
    }
    let caretRectAfter = view.textView.caretRect(for: endAfter)
    XCTAssertLessThanOrEqual(caretRectAfter.maxY, view.textView.bounds.maxY + 1.0)
  }
}

#endif
