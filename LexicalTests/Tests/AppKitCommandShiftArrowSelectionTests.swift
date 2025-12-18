/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(macOS) && !targetEnvironment(macCatalyst)

import AppKit
@testable import LexicalAppKit
import XCTest

@MainActor
final class AppKitCommandShiftArrowSelectionTests: XCTestCase {

  private func makeWindow(with contentView: NSView) -> NSWindow {
    contentView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
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

  private func makeCmdShiftLeftArrowKeyDownEvent(window: NSWindow) throws -> NSEvent {
    let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    guard let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command, .shift],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: leftArrow,
      charactersIgnoringModifiers: leftArrow,
      isARepeat: false,
      keyCode: 123 // Left arrow
    ) else {
      throw XCTSkip("Could not construct NSEvent for Cmd+Shift+Left")
    }
    return event
  }

  func testCmdShiftLeft_SelectsToBeginningOfLineOnFirstPress() throws {
    let testView = createTestEditorView()

    let window = makeWindow(with: testView.view)
    XCTAssertTrue(window.makeFirstResponder(testView.view.textView))

    // Type text (this primes AppKit selection interception paths used to avoid transient caret jumps).
    testView.insertText("Test this")

    XCTAssertEqual(testView.attributedTextString, "Test this")
    let fullLength = (testView.attributedTextString as NSString).length

    // Ensure caret is at end after typing.
    XCTAssertEqual(testView.selectedRange, NSRange(location: fullLength, length: 0))

    // Cmd+Shift+Left should select to the beginning of the current line on the first press.
    let event = try makeCmdShiftLeftArrowKeyDownEvent(window: window)
    testView.view.textView.keyDown(with: event)

    XCTAssertEqual(testView.selectedRange, NSRange(location: 0, length: fullLength))
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
