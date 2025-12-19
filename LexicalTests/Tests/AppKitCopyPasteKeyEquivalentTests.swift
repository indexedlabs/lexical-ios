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
final class AppKitCopyPasteKeyEquivalentTests: XCTestCase {

  private func makeUniquePasteboard() -> NSPasteboard {
    let name = NSPasteboard.Name("lexical-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    return pasteboard
  }

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
    return window
  }

  private func makeCommandKeyDownEvent(
    characters: String,
    keyCode: UInt16,
    window: NSWindow
  ) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    ) else {
      throw XCTSkip("Could not construct NSEvent for Cmd+\(characters)")
    }
    return event
  }

  func testCmdCAndCmdV_CopyAndPasteViaKeyEquivalents() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    let pasteboard = makeUniquePasteboard()
    testView.view.textView.clipboardPasteboard = pasteboard

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
    }
    testView.setSelectedRange(worldRange)

    let window = makeWindow(with: testView.view)
    XCTAssertTrue(window.makeFirstResponder(testView.view.textView))

    // Cmd+C
    let cmdC = try makeCommandKeyDownEvent(characters: "c", keyCode: 8, window: window)
    XCTAssertTrue(window.performKeyEquivalent(with: cmdC))
    XCTAssertEqual(pasteboard.string(forType: .string), "world")

    // Cmd+V (paste back at end)
    pasteboard.clearContents()
    pasteboard.setString("!", forType: .string)

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try selection.applySelectionRange(
        NSRange(location: testView.attributedTextLength, length: 0),
        affinity: .forward
      )
    }
    testView.setSelectedRange(NSRange(location: testView.attributedTextLength, length: 0))

    let cmdV = try makeCommandKeyDownEvent(characters: "v", keyCode: 9, window: window)
    XCTAssertTrue(window.performKeyEquivalent(with: cmdV))

    var out = ""
    try editor.read { out = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(out, "Hello world!")
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
