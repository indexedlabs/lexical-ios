/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import Lexical
@testable import EditorHistoryPlugin
import XCTest

#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import LexicalAppKit
#endif

/// Tests for insertParagraph at the start of a paragraph.
///
/// When pressing Enter at the start of a paragraph, a new empty paragraph should be
/// inserted before the current one, and the cursor should stay at the start of the
/// original content (not jump to the end of the document).
@MainActor
final class InsertParagraphAtStartParityTests: XCTestCase {

  private func makeEditors() -> (opt: (Editor, any ReadOnlyTextKitContextProtocol), leg: (Editor, any ReadOnlyTextKitContextProtocol)) {
    return makeParityTestEditors()
  }

  #if os(macOS) && !targetEnvironment(macCatalyst)
  /// Test that actual NSTextView.selectedRange is correct after insertParagraph at start.
  ///
  /// This test uses the full editable LexicalView (not the read-only context) to verify
  /// that the actual native selection is correctly synced after pressing Enter at the
  /// start of a paragraph. The bug is that the cursor ends up above the content instead
  /// of staying at the start of the original text.
  func testAppKit_InsertParagraphAtStart_ActualNativeSelectionCorrect() throws {
    let cfg = EditorConfig(theme: Theme(), plugins: [])
    let lexicalView = LexicalView(editorConfig: cfg, featureFlags: FeatureFlags())
    lexicalView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let editor = lexicalView.editor
    let textView = lexicalView.textView

    // Create content with cursor at start
    try editor.update {
      guard let root = getRoot() else { return }
      // Clear default paragraph
      for child in root.getChildren() { try? child.remove() }
      let p = createParagraphNode()
      let t = createTextNode(text: "Hello World")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 0, focusOffset: 0)
    }

    // Verify initial state
    XCTAssertEqual(textView.string, "Hello World", "Initial text should be 'Hello World'")
    let initialNativeRange = textView.selectedRange()
    XCTAssertEqual(initialNativeRange.location, 0, "Initial native selection should be at 0")

    // Insert paragraph at start (press Enter)
    try editor.update {
      try (getSelection() as? RangeSelection)?.insertParagraph()
    }

    // Verify text content after insert
    XCTAssertEqual(textView.string, "\nHello World", "Text should have newline prefix")

    // Verify the actual NSTextView selection is at position 1 (after the newline)
    let finalNativeRange = textView.selectedRange()
    XCTAssertEqual(finalNativeRange.location, 1, "Native selection should be at position 1 (after newline)")
    XCTAssertEqual(finalNativeRange.length, 0, "Native selection should be collapsed")

    // Verify Lexical selection is correct
    var lexicalAnchorOffset = -1
    var computedNativeLocation = -1
    try editor.read {
      if let sel = try getSelection() as? RangeSelection {
        lexicalAnchorOffset = sel.anchor.offset
        if let loc = try? stringLocationForPoint(sel.anchor, editor: editor) {
          computedNativeLocation = loc
        }
      }
    }
    XCTAssertEqual(lexicalAnchorOffset, 0, "Lexical anchor offset should be 0")
    XCTAssertEqual(computedNativeLocation, 1, "Computed native location should be 1")

    // The key assertion: actual native selection should match computed location
    XCTAssertEqual(finalNativeRange.location, computedNativeLocation,
                   "Actual native selection (\(finalNativeRange.location)) should match computed location (\(computedNativeLocation))")
  }

  /// Test multiple insertParagraph at start results in correct native selection.
  func testAppKit_MultipleInsertParagraphAtStart_NativeSelectionCorrect() throws {
    let cfg = EditorConfig(theme: Theme(), plugins: [])
    let lexicalView = LexicalView(editorConfig: cfg, featureFlags: FeatureFlags())
    lexicalView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let editor = lexicalView.editor
    let textView = lexicalView.textView

    // Create content with cursor at start
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() { try? child.remove() }
      let p = createParagraphNode()
      let t = createTextNode(text: "Content")
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 0, focusOffset: 0)
    }

    // Insert 3 paragraphs at start
    for i in 1...3 {
      try editor.update {
        try (getSelection() as? RangeSelection)?.insertParagraph()
      }

      // Verify native selection after each insert
      let nativeRange = textView.selectedRange()
      var computedLocation = -1
      try editor.read {
        if let sel = try getSelection() as? RangeSelection,
           let loc = try? stringLocationForPoint(sel.anchor, editor: editor) {
          computedLocation = loc
        }
      }
      XCTAssertEqual(nativeRange.location, i, "After \(i) inserts, native selection should be at \(i)")
      XCTAssertEqual(nativeRange.location, computedLocation,
                     "Insert \(i): Actual native (\(nativeRange.location)) should match computed (\(computedLocation))")
    }

    // Final text should have 3 newlines before "Content"
    XCTAssertEqual(textView.string, "\n\n\nContent", "Text should have 3 newlines before Content")
  }

  /// Test insertParagraph at start with multi-paragraph document like demo app.
  ///
  /// This replicates the demo app scenario where there are multiple paragraphs
  /// and the user presses Enter at the very beginning of the first paragraph.
  func testAppKit_InsertParagraphAtStart_WithMultipleParagraphs_LikeDemoApp() throws {
    let cfg = EditorConfig(theme: Theme(), plugins: [])
    let lexicalView = LexicalView(editorConfig: cfg, featureFlags: FeatureFlags())
    lexicalView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let editor = lexicalView.editor
    let textView = lexicalView.textView

    // Set up content similar to demo app (multiple paragraphs)
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() { try? child.remove() }

      // Paragraph 1: Bold heading
      let heading = createParagraphNode()
      let headingText = createTextNode(text: "Welcome to Lexical!")
      try? headingText.setBold(true)
      try heading.append([headingText])

      // Paragraph 2: Normal text
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "This is the demo.")
      try paragraph.append([text])

      // Paragraph 3: More text
      let paragraph2 = createParagraphNode()
      let text2 = createTextNode(text: "Features include bold and italic.")
      try paragraph2.append([text2])

      try root.append([heading, paragraph, paragraph2])

      // Position cursor at start of first text node
      try headingText.select(anchorOffset: 0, focusOffset: 0)
    }

    // Verify initial state
    let initialText = textView.string
    XCTAssertTrue(initialText.hasPrefix("Welcome to Lexical!"), "Should start with welcome text")
    XCTAssertEqual(textView.selectedRange().location, 0, "Initial cursor should be at 0")

    // Press Enter 3 times at the start
    for i in 1...3 {
      try editor.update {
        try (getSelection() as? RangeSelection)?.insertParagraph()
      }

      // After each Enter, verify native selection
      let nativeRange = textView.selectedRange()
      var computedLocation = -1
      try editor.read {
        if let sel = try getSelection() as? RangeSelection,
           let loc = try? stringLocationForPoint(sel.anchor, editor: editor) {
          computedLocation = loc
        }
      }

      XCTAssertEqual(nativeRange.location, computedLocation,
                     "After Enter \(i): Actual native (\(nativeRange.location)) should match computed (\(computedLocation))")
    }

    // Final verification: cursor should be at position 3, text should have 3 newlines at start
    let finalNativeRange = textView.selectedRange()
    XCTAssertEqual(finalNativeRange.location, 3, "Final cursor should be at position 3")
    XCTAssertTrue(textView.string.hasPrefix("\n\n\nWelcome"), "Text should have 3 newlines before 'Welcome'")
  }

  /// Test that native selection is correctly set after insertParagraph at start.
  ///
  /// This tests the fix for the bug where the native cursor would jump to the end
  /// of the document after pressing Enter at the start of a paragraph. The issue was
  /// that `applySelection(range:affinity:)` had a guard checking `isUpdatingNativeSelection`,
  /// but this flag was already set by the reconciler, causing the selection update to be skipped.
  func testAppKit_InsertParagraphAtStart_NativeSelectionSyncedCorrectly() throws {
    let flags = FeatureFlags()
    let context = LexicalReadOnlyTextKitContextAppKit(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: flags
    )
    let editor = context.editor

    // Create content with cursor at start
    var textKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      // Clear default paragraph
      for child in root.getChildren() { try? child.remove() }
      let p = createParagraphNode()
      let t = createTextNode(text: "Hello World")
      textKey = t.getKey()
      try p.append([t])
      try root.append([p])
      try t.select(anchorOffset: 0, focusOffset: 0)
    }

    // Verify initial state
    var initialNativeLocation: Int = -1
    try editor.read {
      if let sel = try getSelection() as? RangeSelection {
        if let loc = try? stringLocationForPoint(sel.anchor, editor: editor) {
          initialNativeLocation = loc
        }
      }
    }
    XCTAssertEqual(initialNativeLocation, 0, "Initial native location should be 0")

    // Insert paragraph at start (press Enter)
    try editor.update {
      try (getSelection() as? RangeSelection)?.insertParagraph()
    }

    // Verify selection is still at start of original content, not at end
    var finalAnchorOffset = -1
    var finalNativeLocation: Int = -1
    try editor.read {
      if let sel = try getSelection() as? RangeSelection {
        finalAnchorOffset = sel.anchor.offset
        if let loc = try? stringLocationForPoint(sel.anchor, editor: editor) {
          finalNativeLocation = loc
        }
      }
    }

    // After inserting empty paragraph before "Hello World", the native location
    // should be 1 (after the newline from the new empty paragraph), not at the end
    XCTAssertEqual(finalAnchorOffset, 0, "Lexical anchor offset should stay at 0")
    XCTAssertEqual(finalNativeLocation, 1, "Native location should be 1 (after new paragraph's newline)")

    // Also verify text content is correct - should have a newline from the new empty paragraph
    var textContent = ""
    var paragraphCount = 0
    try editor.read {
      textContent = getRoot()?.getTextContent() ?? ""
      paragraphCount = getRoot()?.getChildrenSize() ?? 0
    }
    // Should have 2 paragraphs now (empty + "Hello World")
    XCTAssertEqual(paragraphCount, 2, "Should have 2 paragraphs after insert")
    // Text content should include the empty paragraph's contribution
    XCTAssertTrue(textContent.hasSuffix("Hello World"), "Content should end with original text")
  }
  #endif

  /// Test that insertParagraph at start of paragraph keeps cursor at start of original content.
  ///
  /// Scenario:
  /// 1. Document has "Hello" with cursor at offset 0 (start)
  /// 2. insertParagraph is called (Enter key)
  /// 3. Expected: New empty paragraph before "Hello", cursor stays at start of "Hello"
  /// 4. NOT: Cursor jumps to end of document
  func testParity_InsertParagraphAtStart_KeepsCursorAtOriginalPosition() throws {
    let (opt, leg) = makeEditors()

    func run(on editor: Editor) throws -> (text: String, anchorOffset: Int, nativeLocation: Int?) {
      // Create a paragraph with text
      var textKey: NodeKey = ""
      try editor.update {
        guard let root = getRoot() else { return }
        let p = createParagraphNode()
        let t = createTextNode(text: "Hello")
        textKey = t.getKey()
        try p.append([t])
        try root.append([p])
        // Position cursor at start of text
        try t.select(anchorOffset: 0, focusOffset: 0)
      }

      // Verify initial selection
      var beforeAnchorOffset = -1
      try editor.read {
        if let sel = try getSelection() as? RangeSelection {
          beforeAnchorOffset = sel.anchor.offset
        }
      }
      XCTAssertEqual(beforeAnchorOffset, 0, "Initial cursor should be at offset 0")

      // Insert paragraph (press Enter at start)
      try editor.update {
        try (getSelection() as? RangeSelection)?.insertParagraph()
      }

      // Check result
      var textContent = ""
      var anchorKey: NodeKey = ""
      var anchorOffset = -1
      var anchorType: SelectionType = .text
      try editor.read {
        textContent = getRoot()?.getTextContent() ?? ""
        if let sel = try getSelection() as? RangeSelection {
          anchorKey = sel.anchor.key
          anchorOffset = sel.anchor.offset
          anchorType = sel.anchor.type
        }
      }

      // Get native selection position for debugging
      var nativeLocation: Int? = nil
      #if os(macOS) && !targetEnvironment(macCatalyst)
      if let ctx = editor.frontendAppKit as? LexicalReadOnlyTextKitContextAppKit {
        nativeLocation = ctx.textStorage.length > 0 ? nil : nil // Can't easily get native selection from read-only context
      }
      #endif

      // The cursor should still be at offset 0 (start of the "Hello" text)
      // Not at the end of the document
      XCTAssertEqual(anchorOffset, 0, "Cursor should stay at offset 0, not jump")
      XCTAssertEqual(anchorType, .text, "Selection should remain text type")

      return (textContent, anchorOffset, nativeLocation)
    }

    let optResult = try run(on: opt.0)
    let legResult = try run(on: leg.0)

    // Both should have same text content (newline + Hello)
    XCTAssertEqual(optResult.text, legResult.text, "Text content should match between reconcilers")
    // Text should be newline followed by "Hello"
    XCTAssertEqual(optResult.text, "\nHello", "Content should be newline + original text")

    // Both should have cursor at offset 0
    XCTAssertEqual(optResult.anchorOffset, 0, "Optimized reconciler: cursor should be at offset 0")
    XCTAssertEqual(legResult.anchorOffset, 0, "Legacy reconciler: cursor should be at offset 0")
  }

  /// Test that insertParagraph at start of first paragraph creates new paragraph above.
  func testParity_InsertParagraphAtStartOfFirstParagraph_CreatesNewParagraphAbove() throws {
    let (opt, leg) = makeEditors()

    func run(on editor: Editor) throws -> Int {
      // Get initial paragraph count (there's a default empty paragraph)
      var initialCount = 0
      try editor.read { initialCount = getRoot()?.getChildrenSize() ?? 0 }

      try editor.update {
        guard let root = getRoot() else { return }
        let p = createParagraphNode()
        let t = createTextNode(text: "First paragraph")
        try p.append([t])
        try root.append([p])
        try t.select(anchorOffset: 0, focusOffset: 0)
      }

      try editor.update {
        try (getSelection() as? RangeSelection)?.insertParagraph()
      }

      var count = 0
      try editor.read {
        count = getRoot()?.getChildrenSize() ?? 0
      }
      // Account for default paragraph + our paragraph + new empty paragraph from Enter
      return count - initialCount
    }

    let optCount = try run(on: opt.0)
    let legCount = try run(on: leg.0)

    // Should have added 2 paragraphs (our content + empty from Enter)
    XCTAssertEqual(optCount, 2, "Should have 2 new paragraphs after insert")
    XCTAssertEqual(legCount, 2, "Should have 2 new paragraphs after insert")
  }

  /// Test that multiple insertParagraph at start creates multiple empty paragraphs.
  func testParity_MultipleInsertParagraphAtStart_CreatesMultipleEmptyParagraphs() throws {
    let (opt, leg) = makeEditors()

    func run(on editor: Editor) throws -> (addedParagraphs: Int, textContent: String) {
      // Get initial paragraph count
      var initialCount = 0
      try editor.read { initialCount = getRoot()?.getChildrenSize() ?? 0 }

      try editor.update {
        guard let root = getRoot() else { return }
        let p = createParagraphNode()
        let t = createTextNode(text: "Content")
        try p.append([t])
        try root.append([p])
        try t.select(anchorOffset: 0, focusOffset: 0)
      }

      // Insert 3 paragraphs at start
      for _ in 0..<3 {
        try editor.update {
          try (getSelection() as? RangeSelection)?.insertParagraph()
        }
      }

      var count = 0
      var text = ""
      try editor.read {
        count = getRoot()?.getChildrenSize() ?? 0
        text = getRoot()?.getTextContent() ?? ""
      }
      return (count - initialCount, text)
    }

    let optResult = try run(on: opt.0)
    let legResult = try run(on: leg.0)

    // Should have added 4 paragraphs (1 content + 3 empty from Enter)
    XCTAssertEqual(optResult.addedParagraphs, 4, "Should have added 4 paragraphs")
    XCTAssertEqual(legResult.addedParagraphs, 4, "Should have added 4 paragraphs")
    // Text content should contain 3 newlines + "Content" (plus initial empty paragraph newline)
    XCTAssertTrue(optResult.textContent.hasSuffix("\n\n\nContent"), "Should end with 3 newlines + Content")
    XCTAssertTrue(legResult.textContent.hasSuffix("\n\n\nContent"), "Should end with 3 newlines + Content")
  }

  /// Test insertParagraph at start with multiple paragraphs - cursor should stay with original text node.
  func testParity_InsertParagraphAtStart_WithMultipleParagraphs_CursorStaysWithOriginalText() throws {
    let (opt, leg) = makeEditors()

    func run(on editor: Editor) throws -> (anchorKey: NodeKey, anchorOffset: Int) {
      var targetTextKey: NodeKey = ""
      try editor.update {
        guard let root = getRoot() else { return }
        // Create multiple paragraphs
        for i in 0..<3 {
          let p = createParagraphNode()
          let t = createTextNode(text: "Para \(i)")
          if i == 1 { targetTextKey = t.getKey() } // Will put cursor here
          try p.append([t])
          try root.append([p])
        }
        // Position cursor at start of second paragraph
        if let t = getNodeByKey(key: targetTextKey) as? TextNode {
          try t.select(anchorOffset: 0, focusOffset: 0)
        }
      }

      // Insert paragraph at start of second paragraph
      try editor.update {
        try (getSelection() as? RangeSelection)?.insertParagraph()
      }

      // Check where cursor is now
      var anchorKey: NodeKey = ""
      var anchorOffset = -1
      try editor.read {
        if let sel = try getSelection() as? RangeSelection {
          anchorKey = sel.anchor.key
          anchorOffset = sel.anchor.offset
        }
      }

      // The cursor should still be at the start of the original "Para 1" text node
      XCTAssertEqual(anchorKey, targetTextKey, "Cursor should stay with original text node")
      XCTAssertEqual(anchorOffset, 0, "Cursor should stay at offset 0")

      return (anchorKey, anchorOffset)
    }

    let optResult = try run(on: opt.0)
    let legResult = try run(on: leg.0)

    XCTAssertEqual(optResult.anchorOffset, legResult.anchorOffset, "Both reconcilers should have same anchor offset")
  }

  #if os(macOS) && !targetEnvironment(macCatalyst)
  /// Test insertParagraph at start with EditorHistoryPlugin enabled.
  ///
  /// This replicates the demo app scenario where EditorHistoryPlugin is active.
  /// The history plugin could potentially interfere with selection during updates.
  func testAppKit_InsertParagraphAtStart_WithEditorHistoryPlugin() throws {
    let historyPlugin = EditorHistoryPlugin()
    let cfg = EditorConfig(theme: Theme(), plugins: [historyPlugin])
    let lexicalView = LexicalView(editorConfig: cfg, featureFlags: FeatureFlags())
    lexicalView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let editor = lexicalView.editor
    let textView = lexicalView.textView

    // Set up content similar to demo app
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() { try? child.remove() }

      // Bold heading like demo app
      let heading = createParagraphNode()
      let headingText = createTextNode(text: "Welcome to Lexical!")
      try? headingText.setBold(true)
      try heading.append([headingText])

      // Normal paragraph
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "This is the demo.")
      try paragraph.append([text])

      try root.append([heading, paragraph])
      try headingText.select(anchorOffset: 0, focusOffset: 0)
    }

    // Verify initial state
    XCTAssertEqual(textView.selectedRange().location, 0, "Initial cursor should be at 0")

    // Press Enter at the start
    try editor.update {
      try (getSelection() as? RangeSelection)?.insertParagraph()
    }

    // Verify native selection is at position 1 (after the new empty paragraph's newline)
    let nativeRange = textView.selectedRange()
    XCTAssertEqual(nativeRange.location, 1,
                   "Native selection should be at position 1 (after newline), got \(nativeRange.location)")

    // Press Enter again
    try editor.update {
      try (getSelection() as? RangeSelection)?.insertParagraph()
    }

    let nativeRange2 = textView.selectedRange()
    XCTAssertEqual(nativeRange2.location, 2,
                   "Native selection should be at position 2, got \(nativeRange2.location)")

    // Third Enter
    try editor.update {
      try (getSelection() as? RangeSelection)?.insertParagraph()
    }

    let nativeRange3 = textView.selectedRange()
    XCTAssertEqual(nativeRange3.location, 3,
                   "Native selection should be at position 3, got \(nativeRange3.location)")

    // Verify text content
    XCTAssertTrue(textView.string.hasPrefix("\n\n\nWelcome"),
                  "Text should have 3 newlines before 'Welcome'")
  }

  /// Test insertParagraph using dispatchCommand (like the demo app's keyboard handler).
  ///
  /// This tests the exact code path the demo app uses when the user presses Enter.
  func testAppKit_InsertParagraphAtStart_ViaDispatchCommand() throws {
    let historyPlugin = EditorHistoryPlugin()
    let cfg = EditorConfig(theme: Theme(), plugins: [historyPlugin])
    let lexicalView = LexicalView(editorConfig: cfg, featureFlags: FeatureFlags())
    lexicalView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let editor = lexicalView.editor
    let textView = lexicalView.textView

    // Set up content similar to demo app
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() { try? child.remove() }

      // Bold heading like demo app
      let heading = createParagraphNode()
      let headingText = createTextNode(text: "Welcome to Lexical!")
      try? headingText.setBold(true)
      try heading.append([headingText])

      // Normal paragraph
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "This is the demo.")
      try paragraph.append([text])

      try root.append([heading, paragraph])
      try headingText.select(anchorOffset: 0, focusOffset: 0)
    }

    // Verify initial state
    XCTAssertEqual(textView.selectedRange().location, 0, "Initial cursor should be at 0")

    // Press Enter using dispatchCommand (like the demo app keyboard handler)
    _ = editor.dispatchCommand(type: .insertParagraph, payload: nil)

    // Verify native selection is at position 1 (after the new empty paragraph's newline)
    let nativeRange = textView.selectedRange()
    XCTAssertEqual(nativeRange.location, 1,
                   "Native selection should be at position 1 (after newline), got \(nativeRange.location)")

    // Press Enter again
    _ = editor.dispatchCommand(type: .insertParagraph, payload: nil)

    let nativeRange2 = textView.selectedRange()
    XCTAssertEqual(nativeRange2.location, 2,
                   "Native selection should be at position 2, got \(nativeRange2.location)")

    // Third Enter
    _ = editor.dispatchCommand(type: .insertParagraph, payload: nil)

    let nativeRange3 = textView.selectedRange()
    XCTAssertEqual(nativeRange3.location, 3,
                   "Native selection should be at position 3, got \(nativeRange3.location)")

    // Verify text content
    XCTAssertTrue(textView.string.hasPrefix("\n\n\nWelcome"),
                  "Text should have 3 newlines before 'Welcome'")
  }
  #endif
}
