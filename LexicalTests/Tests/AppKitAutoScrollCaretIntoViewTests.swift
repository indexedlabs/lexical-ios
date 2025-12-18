#if os(macOS) && !targetEnvironment(macCatalyst)
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import XCTest
@testable import Lexical
@testable import LexicalAppKit

@MainActor
final class AppKitAutoScrollCaretIntoViewTests: XCTestCase {
  func testInsertParagraphScrollsCaretIntoViewWhenOffscreen() throws {
    let testView = createTestEditorView(featureFlags: FeatureFlags())
    let editor = testView.editor

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.contentView = testView.view
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(testView.view.textView)

    var lastTextKey: NodeKey?
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() { try? child.remove() }
      for i in 0..<120 {
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

    // Scroll to the top so the caret (at the end) is offscreen.
    testView.view.scrollView.contentView.scroll(to: .zero)
    testView.view.scrollView.reflectScrolledClipView(testView.view.scrollView.contentView)
    let offsetBefore = testView.view.scrollView.contentView.bounds.origin.y

    try editor.update { try (getSelection() as? RangeSelection)?.insertParagraph() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    let offsetAfter = testView.view.scrollView.contentView.bounds.origin.y
    XCTAssertGreaterThan(offsetAfter, offsetBefore)
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)

