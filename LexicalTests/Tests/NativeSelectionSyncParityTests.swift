/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical

#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
@testable import LexicalAppKit
#endif

/// Tests for native selection to Lexical selection synchronization.
///
/// These tests verify that when the native NSTextView selection changes,
/// the Lexical selection is properly updated to match.
@MainActor
final class NativeSelectionSyncParityTests: XCTestCase {

  private func makeSelectionTestView() -> (
    testView: TestEditorView,
    tearDown: @MainActor () -> Void
  ) {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    let testView = createTestEditorView()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = testView.view
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(testView.view.textView)
    return (testView, {
      window.orderOut(nil)
    })
    #else
    let harness = ReconcilerIntegrationHarness(testCase: self)
    let testView = harness.createTestView()
    return (testView, { harness.tearDown() })
    #endif
  }

  private func applyNativeSelectionChange(_ testView: TestEditorView) {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    testView.view.textView.handleSelectionChange()
    #else
    let textView = testView.view.textView
    textView.delegate?.textViewDidChangeSelection?(textView)
    drainMainQueue()
    #endif
  }

  private func drainMainQueue(timeout: TimeInterval = 2) {
    let exp = expectation(description: "drain main queue")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: timeout)
  }

  #if canImport(UIKit)
  private func assertNativeSelectionRoundTrips(
    _ editor: Editor,
    _ testView: TestEditorView,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection", file: file, line: line)
        return
      }
      let native = try createNativeSelection(from: selection, editor: editor)
      XCTAssertEqual(native.range, testView.selectedRange, "Selection did not round-trip", file: file, line: line)
    }
  }
  #endif

  /// Test that changing native selection updates Lexical selection.
  ///
  /// This test reproduces a bug where `pointAtStringLocation` is called
  /// outside of `editor.read {}`, causing the conversion to fail because
  /// `getNodeByKey` requires an active Lexical context.
  func testNativeSelectionChangeUpdatesLexicalSelection() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    // Add some content: "Hello World"
    var textNodeKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      textNodeKey = textNode.getKey()
      try paragraph.append([textNode])
      try root.append([paragraph])

      // Set initial selection at end of text
      _ = try textNode.select(anchorOffset: 11, focusOffset: 11)
    }

    // Verify initial Lexical selection is at position 11 (end of "Hello World")
    var initialAnchorOffset = -1
    var initialFocusOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      initialAnchorOffset = selection.anchor.offset
      initialFocusOffset = selection.focus.offset
    }
    XCTAssertEqual(initialAnchorOffset, 11, "Initial anchor should be at 11")
    XCTAssertEqual(initialFocusOffset, 11, "Initial focus should be at 11")

    // Get the actual native string to find "Hello" position
    let nativeString = testView.attributedTextString as NSString
    let helloRange = nativeString.range(of: "Hello")
    XCTAssertNotEqual(helloRange.location, NSNotFound, "Should find 'Hello' in native text")

    // Native position right after "Hello" (accounting for any prefix characters)
    let nativePositionAfterHello = helloRange.location + helloRange.length
    let newRange = NSRange(location: nativePositionAfterHello, length: 0)
    testView.setSelectedRange(newRange)

    // Trigger the selection change handler
    applyNativeSelectionChange(testView)

    // Verify Lexical selection was updated to match native selection
    var updatedAnchorKey: NodeKey = ""
    var updatedAnchorOffset = -1
    var updatedFocusOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection after native selection change")
        return
      }
      updatedAnchorKey = selection.anchor.key
      updatedAnchorOffset = selection.anchor.offset
      updatedFocusOffset = selection.focus.offset
    }

    // The selection should now be at position 5 (after "Hello"), not still at 11
    XCTAssertEqual(updatedAnchorKey, textNodeKey, "Selection should be in text node")
    XCTAssertEqual(updatedAnchorOffset, 5, "Anchor offset should be updated to 5")
    XCTAssertEqual(updatedFocusOffset, 5, "Focus offset should be updated to 5")
  }

  /// Test that selecting a range in native view updates Lexical selection.
  func testNativeRangeSelectionUpdatesLexicalSelection() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    // Add content
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      try paragraph.append([textNode])
      try root.append([paragraph])

      // Set initial collapsed selection
      _ = try textNode.select(anchorOffset: 0, focusOffset: 0)
    }

    // Get the actual native string to find "Hello" position
    let nativeString = testView.attributedTextString as NSString
    let helloRange = nativeString.range(of: "Hello")
    XCTAssertNotEqual(helloRange.location, NSNotFound, "Should find 'Hello' in native text")

    // Select "Hello" in native view
    testView.setSelectedRange(helloRange)
    applyNativeSelectionChange(testView)

    // Verify Lexical selection matches - anchor at 0, focus at 5 (selecting "Hello")
    var anchorOffset = -1
    var focusOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      anchorOffset = selection.anchor.offset
      focusOffset = selection.focus.offset
    }

    XCTAssertEqual(anchorOffset, 0, "Anchor should be at start of 'Hello'")
    XCTAssertEqual(focusOffset, 5, "Focus should be at end of 'Hello'")
  }

  /// Test that backspace with a range selection deletes the selected text.
  ///
  /// This test verifies that when text is selected in the native view and backspace
  /// is pressed, the entire selection is deleted (not just a single character).
  func testBackspaceDeletesSelectedRange() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    // Add content: "Hello World"
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      try paragraph.append([textNode])
      try root.append([paragraph])

      // Initial cursor at end
      _ = try textNode.select(anchorOffset: 11, focusOffset: 11)
    }

    // Find "World" in native string and select it
    let nativeString = testView.attributedTextString as NSString
    let worldRange = nativeString.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)

    // Select "World"
    testView.setSelectedRange(worldRange)
    applyNativeSelectionChange(testView)

    // Verify selection is now "World" (length 5)
    var anchorOffset = -1
    var focusOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      anchorOffset = selection.anchor.offset
      focusOffset = selection.focus.offset
    }
    XCTAssertEqual(focusOffset - anchorOffset, 5, "Selection should span 'World' (5 chars)")

    // Now dispatch backspace command
    editor.dispatchCommand(type: .deleteCharacter, payload: true)

    // Verify "World" is deleted, "Hello " remains
    let finalString = testView.attributedTextString
    XCTAssertTrue(finalString.contains("Hello"), "Should still have 'Hello'")
    XCTAssertFalse(finalString.contains("World"), "'World' should be deleted")
  }

  /// Test that repeated select-and-backspace operations work correctly.
  ///
  /// This reproduces a bug where "selecting text + backspace doesn't delete consistently
  /// (works first time, then only deletes single character)".
  func testRepeatedSelectAndBackspace() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    // Add content: "AAABBBCCC"
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "AAABBBCCC")
      try paragraph.append([textNode])
      try root.append([paragraph])
    }

    // First deletion: Select "BBB" and delete
    var nativeString = testView.attributedTextString as NSString
    var bbbRange = nativeString.range(of: "BBB")
    XCTAssertNotEqual(bbbRange.location, NSNotFound, "Should find 'BBB'")

    testView.setSelectedRange(bbbRange)
    applyNativeSelectionChange(testView)
    editor.dispatchCommand(type: .deleteCharacter, payload: true)

    // Verify "BBB" is deleted
    var afterFirst = testView.attributedTextString
    XCTAssertFalse(afterFirst.contains("BBB"), "'BBB' should be deleted after first backspace")
    XCTAssertTrue(afterFirst.contains("AAA"), "'AAA' should remain")
    XCTAssertTrue(afterFirst.contains("CCC"), "'CCC' should remain")

    // Second deletion: Select "CCC" and delete
    nativeString = testView.attributedTextString as NSString
    let cccRange = nativeString.range(of: "CCC")
    XCTAssertNotEqual(cccRange.location, NSNotFound, "Should find 'CCC'")

    testView.setSelectedRange(cccRange)
    applyNativeSelectionChange(testView)
    editor.dispatchCommand(type: .deleteCharacter, payload: true)

    // Verify "CCC" is also deleted (not just single character)
    let afterSecond = testView.attributedTextString
    XCTAssertFalse(afterSecond.contains("CCC"), "'CCC' should be deleted after second backspace")
    XCTAssertTrue(afterSecond.contains("AAA"), "'AAA' should remain")
  }

  /// Test that native selection change with multiple paragraphs works correctly.
  ///
  /// Note: Adjacent text nodes in the same paragraph may have range cache issues
  /// that are separate from the main selection sync bug. This test uses separate
  /// paragraphs to avoid that complexity.
  func testNativeSelectionWithMultipleParagraphs() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    // Add content with two paragraphs: "Hello" and "World"
    var worldKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      let p1 = createParagraphNode()
      let p2 = createParagraphNode()
      let hello = createTextNode(text: "Hello")
      let world = createTextNode(text: "World")
      worldKey = world.getKey()
      try p1.append([hello])
      try p2.append([world])
      try root.append([p1, p2])

      // Initial selection at start of first paragraph
      _ = try hello.select(anchorOffset: 0, focusOffset: 0)
    }

    // Get the actual native string to find "World" position
    let nativeString = testView.attributedTextString as NSString
    let worldRange = nativeString.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound, "Should find 'World' in native text")

    // Select position 2 characters into "World"
    let nativePosition = worldRange.location + 2
    let newRange = NSRange(location: nativePosition, length: 0)
    testView.setSelectedRange(newRange)
    applyNativeSelectionChange(testView)

    // Verify selection moved to the second paragraph's text node
    var anchorKey: NodeKey = ""
    var anchorOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      anchorKey = selection.anchor.key
      anchorOffset = selection.anchor.offset
    }

    XCTAssertEqual(anchorKey, worldKey, "Selection should be in 'World' text node")
    XCTAssertEqual(anchorOffset, 2, "Offset should be 2 within 'World' node")
  }

  func testCollapsedNativeSelectionAtSiblingBoundaryCanonicalizesToFollowingTextNode() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    var rightTextKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let left = createTextNode(text: "AAA")
      try left.setBold(true)
      let right = createTextNode(text: "BBB")
      rightTextKey = right.getKey()
      try paragraph.append([left, right])
      try root.append([paragraph])
    }

    // On macOS, NSTextView.selectionAffinity doesn't reliably reflect
    // programmatically-set affinity, so handleSelectionChange defaults to
    // upstream which resolves to the preceding node. Apply the selection
    // range directly with forward affinity to test the canonicalization.
    #if os(macOS) && !targetEnvironment(macCatalyst)
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try selection.applySelectionRange(NSRange(location: 3, length: 0), affinity: .forward)
    }
    #else
    testView.setSelectedRange(NSRange(location: 3, length: 0))
    applyNativeSelectionChange(testView)
    #endif

    var anchorKey: NodeKey = ""
    var focusKey: NodeKey = ""
    var anchorOffset = -1
    var focusOffset = -1
    var anchorType: SelectionType = .element
    var focusType: SelectionType = .element
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection after boundary selection sync")
        return
      }
      anchorKey = selection.anchor.key
      focusKey = selection.focus.key
      anchorOffset = selection.anchor.offset
      focusOffset = selection.focus.offset
      anchorType = selection.anchor.type
      focusType = selection.focus.type
    }

    XCTAssertEqual(anchorKey, rightTextKey, "Collapsed boundary caret should canonicalize to the following text node")
    XCTAssertEqual(focusKey, rightTextKey, "Collapsed boundary caret should stay collapsed on the following text node")
    XCTAssertEqual(anchorOffset, 0)
    XCTAssertEqual(focusOffset, 0)
    XCTAssertEqual(anchorType, .text)
    XCTAssertEqual(focusType, .text)

    #if canImport(UIKit)
    try assertNativeSelectionRoundTrips(editor, testView)
    #endif
  }

  func testApplySelectionRangeAtSiblingBoundaryCanonicalizesToFollowingTextNode() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    var rightTextKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let left = createTextNode(text: "AAA")
      try left.setBold(true)
      let right = createTextNode(text: "BBB")
      rightTextKey = right.getKey()
      try paragraph.append([left, right])
      try root.append([paragraph])
    }

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection before applying native range")
        return
      }

      let backwardPoint = try pointAtStringLocation(
        3,
        searchDirection: .backward,
        rangeCache: editor.rangeCache
      )
      let forwardPoint = try pointAtStringLocation(
        3,
        searchDirection: .forward,
        rangeCache: editor.rangeCache
      )

      XCTAssertNotNil(backwardPoint)
      XCTAssertNotNil(forwardPoint)

      if let backwardPoint {
        XCTAssertEqual(
          try stringLocationForPoint(backwardPoint, editor: editor),
          3,
          "Backward boundary candidate should round-trip to the native location"
        )
      }

      if let forwardPoint {
        XCTAssertEqual(
          try stringLocationForPoint(forwardPoint, editor: editor),
          3,
          "Forward boundary candidate should round-trip to the native location"
        )
      }

      let rightStartPoint = Point(key: rightTextKey, offset: 0, type: .text)
      XCTAssertEqual(
        try stringLocationForPoint(rightStartPoint, editor: editor),
        3,
        "Following text node should begin at the collapsed boundary location"
      )

      try selection.applySelectionRange(NSRange(location: 3, length: 0), affinity: .forward)

      XCTAssertEqual(selection.anchor.key, rightTextKey)
      XCTAssertEqual(selection.focus.key, rightTextKey)
      XCTAssertEqual(selection.anchor.offset, 0)
      XCTAssertEqual(selection.focus.offset, 0)
      XCTAssertEqual(selection.anchor.type, .text)
      XCTAssertEqual(selection.focus.type, .text)
    }
  }

  func testNoOpUpdateRepairsNativeSelectionDrift() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 11, focusOffset: 11)
    }

    let nativeString = testView.attributedTextString as NSString
    let helloRange = nativeString.range(of: "Hello")
    XCTAssertNotEqual(helloRange.location, NSNotFound)

    // Simulate native drift without informing Lexical.
    let textView = testView.view.textView
    textView.isUpdatingNativeSelection = true
    testView.setSelectedRange(NSRange(location: helloRange.location + helloRange.length, length: 0))
    textView.isUpdatingNativeSelection = false
    XCTAssertEqual(testView.selectedRange.location, helloRange.location + helloRange.length)

    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection before repair")
        return
      }
      XCTAssertEqual(selection.anchor.offset, 11, "Lexical selection should remain authoritative before repair")
      XCTAssertEqual(selection.focus.offset, 11, "Lexical selection should remain authoritative before repair")
    }

    try editor.update {}

    XCTAssertEqual(
      testView.selectedRange,
      NSRange(location: nativeString.length, length: 0),
      "A no-op update should restore native selection to the authoritative Lexical caret"
    )

    #if canImport(UIKit)
    try assertNativeSelectionRoundTrips(editor, testView)
    #endif
  }

  func testTypingInsertsTextAndKeepsSelectionInSync() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    var textNodeKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      textNodeKey = textNode.getKey()
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 0, focusOffset: 0)
    }

    let nativeBefore = testView.attributedTextString as NSString
    let helloRange = nativeBefore.range(of: "Hello")
    XCTAssertNotEqual(helloRange.location, NSNotFound)

    testView.setSelectedRange(NSRange(location: helloRange.location + helloRange.length, length: 0))
    applyNativeSelectionChange(testView)

    testView.insertText("X")
    drainMainQueue()

    XCTAssertTrue(testView.attributedTextString.contains("HelloX World"))

    var lexicalText = ""
    var anchorKey: NodeKey = ""
    var anchorOffset = -1
    var focusOffset = -1
    try editor.read {
      lexicalText = getRoot()?.getTextContent() ?? ""
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection after typing")
        return
      }
      anchorKey = selection.anchor.key
      anchorOffset = selection.anchor.offset
      focusOffset = selection.focus.offset
    }
    XCTAssertEqual(lexicalText, testView.text)

    let nativeAfter = testView.attributedTextString as NSString
    let helloXRange = nativeAfter.range(of: "HelloX")
    XCTAssertNotEqual(helloXRange.location, NSNotFound)
    XCTAssertEqual(testView.selectedRange.length, 0)
    XCTAssertEqual(testView.selectedRange.location, helloXRange.location + helloXRange.length)

    XCTAssertEqual(anchorKey, textNodeKey)
    XCTAssertEqual(anchorOffset, 6)
    XCTAssertEqual(focusOffset, 6)

    #if canImport(UIKit)
    try assertNativeSelectionRoundTrips(editor, testView)
    #endif
  }

  func testInsertNewlineThenMoveCaretAndTypeKeepsSelectionInSync() throws {
    let mounted = makeSelectionTestView()
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "HelloWorld")
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 0, focusOffset: 0)
    }

    let nativeBefore = testView.attributedTextString as NSString
    let helloRange = nativeBefore.range(of: "Hello")
    XCTAssertNotEqual(helloRange.location, NSNotFound)

    testView.setSelectedRange(NSRange(location: helloRange.location + helloRange.length, length: 0))
    applyNativeSelectionChange(testView)

    testView.insertText("\n")
    drainMainQueue()

    XCTAssertTrue(testView.attributedTextString.contains("Hello\nWorld"))

    var lexicalAfterNewline = ""
    try editor.read { lexicalAfterNewline = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(lexicalAfterNewline, testView.text)

    // Move caret to the start of "World", sync selection, then type a character.
    let nativeAfterNewline = testView.attributedTextString as NSString
    let worldRange = nativeAfterNewline.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)

    testView.setSelectedRange(NSRange(location: worldRange.location, length: 0))
    applyNativeSelectionChange(testView)

    testView.insertText("X")
    drainMainQueue()

    XCTAssertTrue(testView.attributedTextString.contains("Hello\nXWorld"))
    var lexicalAfterType = ""
    try editor.read { lexicalAfterType = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(lexicalAfterType, testView.text)

    #if canImport(UIKit)
    try assertNativeSelectionRoundTrips(editor, testView)
    #endif
  }
}
