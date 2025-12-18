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
final class AppKitAutoScrollCaretTests: XCTestCase {

  private func makeWindow(with contentView: NSView) -> NSWindow {
    contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 140)
    let window = NSWindow(
      contentRect: contentView.bounds,
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
  }

  func testPressingEnterAutoScrollsCaretIntoView() throws {
    let testView = createTestEditorView()
    let window = makeWindow(with: testView.view)
    XCTAssertTrue(window.makeFirstResponder(testView.view.textView))

    // Create enough content that the editor scrolls.
    testView.insertText((0..<200).map { "Line \($0)\n" }.joined())

    let scrollView = testView.view.scrollView
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    // Move caret to end without scrolling there.
    let end = NSRange(location: testView.attributedTextLength, length: 0)
    testView.setSelectedRange(end)

    // Ensure we're actually at the top before pressing Enter.
    XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)

    // Press Enter; the caret should be scrolled into view.
    testView.view.textView.insertNewline(nil)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    XCTAssertGreaterThan(
      scrollView.contentView.bounds.origin.y,
      0,
      "Expected the scroll view to follow the caret after inserting a newline"
    )
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)

