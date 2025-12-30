// Cross-platform boundary regression tests
// These tests verify behaviors that were previously only tested on iOS

import XCTest
@testable import Lexical
@testable import LexicalListPlugin

#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import LexicalAppKit
#endif

@MainActor
final class CrossPlatformBoundaryRegressionTests: XCTestCase {

  // MARK: - Helpers

  private func drainMainQueue(timeout: TimeInterval = 2) {
    let exp = expectation(description: "drain main queue")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: timeout)
  }

  private func assertTextParity(_ testView: TestEditorView, file: StaticString = #file, line: UInt = #line) throws {
    let editor = testView.editor
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    let native = testView.attributedTextString
    XCTAssertEqual(lexical, native, "Native text diverged from Lexical", file: file, line: line)

    let selected = testView.selectedRange
    let length = native.lengthAsNSString()
    XCTAssertGreaterThanOrEqual(selected.location, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(selected.length, 0, file: file, line: line)
    XCTAssertLessThanOrEqual(selected.location, length, file: file, line: line)
    XCTAssertLessThanOrEqual(selected.location + selected.length, length, file: file, line: line)
  }

  // MARK: - Smoke Tests (7nw.11)

  /// Tests basic editing scenario maintains text parity and selection bounds.
  /// Cross-platform equivalent of ReconcilerUsageSmokeTests.testDeterministicEditingScenario
  func testDeterministicEditingScenario_MaintainsTextParityAndSelectionBounds() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Insert "Hello"
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("Hello")
    }
    drainMainQueue()
    try assertTextParity(testView)

    // Move caret into the middle and insert
    testView.setSelectedRange(NSRange(location: 2, length: 0))
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("X")
    }
    drainMainQueue()

    var text = ""
    try editor.read { text = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(text.trimmingCharacters(in: .newlines), "HeXllo")
    try assertTextParity(testView)

    // Insert paragraph break and keep typing
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertParagraph()
    }
    drainMainQueue()

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("Y")
    }
    drainMainQueue()

    try editor.read { text = getRoot()?.getTextContent() ?? "" }
    XCTAssertTrue(text.contains("HeX") && text.contains("Y"), "Expected HeX and Y in text: \(text)")
    try assertTextParity(testView)
  }

  /// Tests start-of-document paste doesn't corrupt state.
  /// Cross-platform equivalent of ReconcilerUsageSmokeTests paste tests.
  func testStartOfDocumentPaste_MaintainsTextParity() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Set up initial content
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "existing")
      try paragraph.append([text])
      try root.append([paragraph])
    }
    drainMainQueue()

    // Move to start of document
    testView.setSelectedRange(NSRange(location: 0, length: 0))

    // Simulate paste by inserting text at start
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("pasted ")
    }
    drainMainQueue()

    var text = ""
    try editor.read { text = getRoot()?.getTextContent() ?? "" }
    XCTAssertTrue(text.contains("pasted") && text.contains("existing"),
                  "Expected 'pasted' and 'existing' in text: \(text)")
    try assertTextParity(testView)
  }

  /// Tests backspace at start of document is a no-op.
  func testBackspaceAtStartOfDocument_IsNoOp() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Set up initial content
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "Hello")
      try paragraph.append([text])
      try root.append([paragraph])
    }
    drainMainQueue()

    let originalText: String = try {
      var t = ""
      try editor.read { t = getRoot()?.getTextContent() ?? "" }
      return t
    }()

    // Move to start and try backspace
    testView.setSelectedRange(NSRange(location: 0, length: 0))
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.deleteCharacter(isBackwards: true)
    }
    drainMainQueue()

    var text = ""
    try editor.read { text = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(text, originalText, "Backspace at start should be no-op")
    try assertTextParity(testView)
  }

  // MARK: - List Plugin Tests (7nw.9)

  /// Tests list plugin backspace join doesn't crash.
  /// Cross-platform equivalent of ReconcilerUsagePluginsTests.testListPluginInsertUnorderedListAndBackspaceJoin
  func testListPluginBackspaceJoin_DoesNotCrash() throws {
    let list = ListPlugin()
    let testView = createTestEditorView(plugins: [list])
    let editor = testView.editor

    // Set up two list items directly
    try editor.update {
      guard let root = getRoot() else { return }
      // Clear existing
      for child in root.getChildren() {
        try child.remove()
      }

      let listNode = createListNode(listType: .bullet)
      let item1 = ListItemNode()
      let text1 = createTextNode(text: "One")
      try item1.append([text1])

      let item2 = ListItemNode()
      let text2 = createTextNode(text: "Two")
      try item2.append([text2])

      try listNode.append([item1, item2])
      try root.append([listNode])
    }
    drainMainQueue()


    // Try to find newline position from native text
    let native = testView.attributedTextString as NSString
    let newlineLoc = native.range(of: "\n").location
    if newlineLoc != NSNotFound {
      testView.setSelectedRange(NSRange(location: newlineLoc + 1, length: 0))

      // Backspace to join items - the main goal is this should not crash
      try editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try selection.deleteCharacter(isBackwards: true)
      }
      drainMainQueue()

      // Verify we didn't crash and selection is valid
      let selectedRange = testView.selectedRange
      XCTAssertGreaterThanOrEqual(selectedRange.location, 0, "Selection should be valid after backspace")
    }
  }

  // MARK: - Boundary Delete Tests (7nw.10)

  /// Tests cross-paragraph range delete.
  func testCrossParagraphRangeDelete_MaintainsParity() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Set up two paragraphs
    try editor.update {
      guard let root = getRoot() else { return }
      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "First")
      try p1.append([t1])

      let p2 = createParagraphNode()
      let t2 = createTextNode(text: "Second")
      try p2.append([t2])

      try root.append([p1, p2])
    }
    drainMainQueue()

    // Select across the paragraph boundary (last char of first + newline + first char of second)
    let native = testView.attributedTextString as NSString
    let newlineLoc = native.range(of: "\n").location
    if newlineLoc != NSNotFound && newlineLoc > 0 {
      // Select from before newline to after it
      testView.setSelectedRange(NSRange(location: newlineLoc - 1, length: 3))

      try editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try selection.deleteCharacter(isBackwards: true)
      }
      drainMainQueue()
      try assertTextParity(testView)
    }
  }

  /// Tests backspace at paragraph start merges correctly.
  /// Based on BackspaceMergeAtParagraphStartParityTests approach.
  func testBackspaceAtParagraphStart_MergesCorrectly() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Set up two paragraphs using the same approach as existing parity tests
    try editor.update {
      guard let root = getRoot() else { return }
      // Clear existing
      for child in root.getChildren() {
        try child.remove()
      }

      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "First")
      try p1.append([t1])
      try root.append([p1])
      // Position at end of "First"
      try t1.select(anchorOffset: 5, focusOffset: 5)
    }
    drainMainQueue()

    // Insert paragraph break to create second paragraph
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertParagraph()
    }
    drainMainQueue()

    // Insert "Second" in the new paragraph
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("Second")
    }
    drainMainQueue()

    // Position caret at start of second paragraph's text
    try editor.update {
      guard let root = getRoot(),
            let p2 = root.getLastChild() as? ParagraphNode,
            let t2 = p2.getLastChild() as? TextNode else { return }
      try t2.select(anchorOffset: 0, focusOffset: 0)
    }
    drainMainQueue()

    // Backspace should merge paragraphs
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.deleteCharacter(isBackwards: true)
    }
    drainMainQueue()

    var text = ""
    try editor.read { text = getRoot()?.getTextContent() ?? "" }
    // After merge, should have FirstSecond on same line
    XCTAssertEqual(text.trimmingCharacters(in: .newlines), "FirstSecond",
                   "Should have merged into 'FirstSecond', got: \(text)")
    try assertTextParity(testView)
  }

  /// Tests multiple empty paragraphs backspace behavior.
  func testMultipleEmptyParagraphs_BackspaceDeletesOneAtATime() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Clear and create paragraph with text followed by empty paragraphs
    try editor.update {
      guard let root = getRoot() else { return }
      // Clear existing children
      for child in root.getChildren() {
        try child.remove()
      }

      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "Text")
      try p1.append([t1])

      let p2 = createParagraphNode() // empty
      let p3 = createParagraphNode() // empty

      try root.append([p1, p2, p3])
    }
    drainMainQueue()

    // Count initial paragraphs
    var initialCount = 0
    try editor.read {
      initialCount = getRoot()?.getChildrenSize() ?? 0
    }
    XCTAssertEqual(initialCount, 3, "Should have exactly 3 paragraphs after setup")

    // Position at end (in last empty paragraph)
    let len = testView.attributedTextString.lengthAsNSString()
    testView.setSelectedRange(NSRange(location: len, length: 0))

    // Backspace once
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.deleteCharacter(isBackwards: true)
    }
    drainMainQueue()

    var afterFirst = 0
    try editor.read {
      afterFirst = getRoot()?.getChildrenSize() ?? 0
    }
    XCTAssertEqual(afterFirst, initialCount - 1, "Should delete one empty paragraph")
    try assertTextParity(testView)
  }

  // MARK: - Enter Key Tests

  /// Tests that pressing Enter at end of line moves cursor to new line, not start of current line.
  /// Regression test for bug where cursor jumped to beginning of current line after Enter.
  func testEnterAtEndOfLine_CursorMovesToNewLine() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Set up a paragraph with text
    try editor.update {
      guard let root = getRoot() else { return }
      // Clear existing
      for child in root.getChildren() {
        try child.remove()
      }

      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "Hello world")
      try p1.append([t1])
      try root.append([p1])

      // Position at end of text
      try t1.select(anchorOffset: 11, focusOffset: 11)
    }
    drainMainQueue()

    let beforeNativePos = testView.selectedRange.location
    let beforeTextLen = testView.attributedTextString.lengthAsNSString()

    // Press Enter (insert paragraph)
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertParagraph()
    }
    drainMainQueue()

    // After Enter, native text should be longer (added newline)
    let afterTextLen = testView.attributedTextString.lengthAsNSString()
    XCTAssertGreaterThan(afterTextLen, beforeTextLen, "Text length should increase after Enter")

    // The cursor should be AFTER the newline, not at the start of the previous line
    let afterNativePos = testView.selectedRange.location
    XCTAssertGreaterThan(afterNativePos, beforeNativePos,
                         "Cursor should move forward after Enter, not backward. Before: \(beforeNativePos), After: \(afterNativePos)")

    // Verify the selection is in the new paragraph
    var isInNewParagraph = false
    var anchorKey = ""
    var anchorOffset = 0
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else { return }
      anchorKey = selection.anchor.key
      anchorOffset = selection.anchor.offset

      // The selection should be at offset 0 in a new node (new paragraph or its child)
      // NOT at offset 0 in the original text node
      guard let root = getRoot() else { return }
      let paragraphs = root.getChildren()
      XCTAssertEqual(paragraphs.count, 2, "Should have 2 paragraphs after Enter")

      if let secondPara = paragraphs.last as? ElementNode {
        // Check if anchor is in or is the second paragraph
        if selection.anchor.key == secondPara.key {
          isInNewParagraph = true
        } else if let firstChild = secondPara.getFirstChild(),
                  selection.anchor.key == firstChild.key {
          isInNewParagraph = true
        }
      }
    }

    XCTAssertTrue(isInNewParagraph,
                  "Cursor should be in new paragraph after Enter. Anchor: (\(anchorKey), \(anchorOffset))")

    try assertTextParity(testView)
  }

  /// Tests Enter at end of line followed by typing inserts text on new line.
  func testEnterThenType_TextAppearsOnNewLine() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    // Set up a paragraph with text
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        try child.remove()
      }

      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "Line1")
      try p1.append([t1])
      try root.append([p1])

      // Position at end
      try t1.select(anchorOffset: 5, focusOffset: 5)
    }
    drainMainQueue()

    // Press Enter
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertParagraph()
    }
    drainMainQueue()

    // Type on new line
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("Line2")
    }
    drainMainQueue()

    var text = ""
    try editor.read { text = getRoot()?.getTextContent() ?? "" }

    // Should have Line1 and Line2 on separate lines
    XCTAssertTrue(text.contains("Line1"), "Should contain Line1")
    XCTAssertTrue(text.contains("Line2"), "Should contain Line2")

    // The two lines should be separated by a newline
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    XCTAssertEqual(lines.count, 2, "Should have 2 non-empty lines")
    if lines.count >= 2 {
      XCTAssertEqual(lines[0], "Line1", "First line should be Line1")
      XCTAssertEqual(lines[1], "Line2", "Second line should be Line2")
    }

    try assertTextParity(testView)
  }
}
