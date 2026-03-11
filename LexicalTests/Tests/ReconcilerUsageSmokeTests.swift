// Usage-oriented reconciler smoke tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical
import UniformTypeIdentifiers

@MainActor
final class ReconcilerUsageSmokeTests: XCTestCase {

  func testDeterministicEditingScenario_MaintainsTextParityAndSelectionBounds() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("Hello")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    // Move caret into the middle and insert.
    textView.selectedRange = NSRange(location: 2, length: 0)
    harness.syncSelection(textView)
    textView.insertText("X")
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "HeXllo")
    try harness.assertTextParity(editor, textView)

    // Insert paragraph break (Return) and keep typing.
    textView.insertText("\n")
    harness.drainMainQueue()
    textView.insertText("Y")
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "HeX\nYllo")
    try harness.assertTextParity(editor, textView)

    // Select across the newline and delete (exercise range delete across paragraph boundary).
    let newlineLoc = (textView.text as NSString?)?.range(of: "\n").location ?? NSNotFound
    XCTAssertNotEqual(newlineLoc, NSNotFound)
    textView.selectedRange = NSRange(location: newlineLoc, length: 2) // "\nY"
    harness.syncSelection(textView)
    textView.deleteBackward()
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "HeXllo")
    try harness.assertTextParity(editor, textView)

    // Move caret to end and backspace once.
    textView.selectedRange = NSRange(location: (textView.text as NSString?)?.length ?? 0, length: 0)
    harness.syncSelection(textView)
    textView.deleteBackward()
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "HeXll")
    try harness.assertTextParity(editor, textView)
  }

  func testStartOfDocPasteThenNewlineThenBackspace_JoinsParagraphsAndKeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    guard let (pasteboard, pasteboardName) = harness.makeUniquePasteboard() else {
      XCTFail("Could not create a unique pasteboard")
      return
    }
    defer { UIPasteboard.remove(withName: pasteboardName) }
    textView.pasteboard = pasteboard

    textView.insertText("World")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    // Go to start of document and paste.
    textView.selectedRange = NSRange(location: 0, length: 0)
    harness.syncSelection(textView)
    pasteboard.string = "Hello "
    textView.paste(nil)
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "Hello World")
    try harness.assertTextParity(editor, textView)

    // Insert a newline after "Hello".
    let helloLen = ("Hello" as NSString).length
    textView.selectedRange = NSRange(location: helloLen, length: 0)
    harness.syncSelection(textView)
    textView.insertText("\n")
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "Hello\n World")
    try harness.assertTextParity(editor, textView)

    // Move to the start of the second paragraph and backspace to join.
    let newlineLoc = (textView.text as NSString?)?.range(of: "\n").location ?? NSNotFound
    XCTAssertNotEqual(newlineLoc, NSNotFound)
    textView.selectedRange = NSRange(location: newlineLoc + 1, length: 0)
    harness.syncSelection(textView)
    textView.deleteBackward()
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "Hello World")
    try harness.assertTextParity(editor, textView)
  }

  func testReplaceSelectionByTyping_ReplacesRangeAndKeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("HelloWorld")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    // Select "World" and replace it by typing.
    let native = (textView.text ?? "") as NSString
    let worldRange = native.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)
    textView.selectedRange = worldRange
    harness.syncSelection(textView)

    textView.insertText("X")
    harness.drainMainQueue()

    XCTAssertEqual(textView.text, "HelloX")
    try harness.assertTextParity(editor, textView)
  }

  func testReplaceSelectionSpanningNewlineByPaste_ReplacesRangeAndKeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    guard let (pasteboard, pasteboardName) = harness.makeUniquePasteboard() else {
      XCTFail("Could not create a unique pasteboard")
      return
    }
    defer { UIPasteboard.remove(withName: pasteboardName) }
    textView.pasteboard = pasteboard

    textView.insertText("AA\nBB")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    // Select across the newline: "A\nB"
    let native = (textView.text ?? "") as NSString
    let aLoc = native.range(of: "AA").location
    let newlineLoc = native.range(of: "\n").location
    XCTAssertNotEqual(aLoc, NSNotFound)
    XCTAssertNotEqual(newlineLoc, NSNotFound)
    let start = aLoc + 1
    let end = newlineLoc + 2
    textView.selectedRange = NSRange(location: start, length: max(0, end - start))
    harness.syncSelection(textView)

    pasteboard.string = "X"
    textView.paste(nil)
    harness.drainMainQueue()

    XCTAssertEqual(textView.text, "AXB")
    try harness.assertTextParity(editor, textView)
  }

  func testEmojiGraphemeRangeDelete_DoesNotCrashAndKeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    let emoji = "👨‍👩‍👧‍👦"
    textView.insertText("a\(emoji)b")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    let prefixLen = ("a" as NSString).length
    let emojiLen = (emoji as NSString).length

    // Delete the emoji by selecting its full UTF-16 range.
    textView.selectedRange = NSRange(location: prefixLen, length: emojiLen)
    harness.syncSelection(textView)
    textView.deleteBackward()
    harness.drainMainQueue()

    XCTAssertEqual(textView.text, "ab")
    try harness.assertTextParity(editor, textView)

    // Reinsert and delete with a boundary backspace.
    textView.selectedRange = NSRange(location: 1, length: 0)
    harness.syncSelection(textView)
    textView.insertText(emoji)
    harness.drainMainQueue()
    XCTAssertEqual(textView.text, "a\(emoji)b")
    try harness.assertTextParity(editor, textView)

    textView.selectedRange = NSRange(location: prefixLen + emojiLen, length: 0)
    harness.syncSelection(textView)
    textView.deleteBackward()
    harness.drainMainQueue()

    XCTAssertEqual(textView.text, "ab")
    try harness.assertTextParity(editor, textView)
  }

  func testCopyPasteRoundTrip_PreservesTextAndFormattingAndDoesNotCrash() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    // Source editor/view
    let source = harness.createTestView()
    let sourceEditor = source.editor
    let sourceTextView = source.view.textView

    guard let (pasteboard, pasteboardName) = harness.makeUniquePasteboard() else {
      XCTFail("Could not create a unique pasteboard")
      return
    }
    defer { UIPasteboard.remove(withName: pasteboardName) }
    sourceTextView.pasteboard = pasteboard

    // Insert some content through the native input path.
    sourceTextView.insertText("Hello\nWorld")
    harness.drainMainQueue()
    try harness.assertTextParity(sourceEditor, sourceTextView)

    // Select "World" and toggle bold via the command path (exercises formatting + reconciliation).
    let native = (sourceTextView.text ?? "") as NSString
    let worldRange = native.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)
    sourceTextView.selectedRange = worldRange
    harness.syncSelection(sourceTextView)

    _ = sourceEditor.dispatchCommand(type: .formatText, payload: TextFormatType.bold)
    harness.drainMainQueue()

    // Append a character to create a mixed-format run that must reconcile correctly.
    let endLoc = (sourceTextView.text as NSString?)?.length ?? 0
    sourceTextView.selectedRange = NSRange(location: endLoc, length: 0)
    harness.syncSelection(sourceTextView)
    sourceTextView.insertText("!")
    harness.drainMainQueue()

    try harness.assertTextParity(sourceEditor, sourceTextView)
    let expectedText = sourceTextView.text ?? ""

    // Copy everything to the pasteboard (exercises Lexical node serialization path).
    sourceTextView.selectedRange = NSRange(location: 0, length: (expectedText as NSString).length)
    harness.syncSelection(sourceTextView)
    sourceTextView.copy(nil)
    harness.drainMainQueue()

    // Destination editor/view
    let dest = harness.createTestView()
    let destEditor = dest.editor
    let destTextView = dest.view.textView
    destTextView.pasteboard = pasteboard

    // Ensure a deterministic initial selection for paste paths that require a RangeSelection.
    try destEditor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "")
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 0, focusOffset: 0)
    }
    harness.drainMainQueue()

    destTextView.selectedRange = NSRange(location: 0, length: 0)
    harness.syncSelection(destTextView)
    destTextView.paste(nil)
    harness.drainMainQueue(timeout: 5)

    XCTAssertEqual(destTextView.text, expectedText)
    try harness.assertTextParity(destEditor, destTextView)

    // Assert we preserved at least some bold formatting in the model.
    var hasBold = false
    try destEditor.read {
      for node in destEditor.getEditorState().nodeMap.values {
        if let textNode = node as? TextNode, textNode.format.bold {
          hasBold = true
          break
        }
      }
    }
    XCTAssertTrue(hasBold, "Expected at least one bold text node after copy/paste round-trip")
  }

  func testDecoratorInsertionThenDeletion_DoesNotCrashAndRemovesNode() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    var decoratorKey: NodeKey = ""
    try editor.update {
      try registerTestDecoratorNode(on: editor)
      guard let root = getRoot() else { return }
      try root.clear()

      let paragraph = createParagraphNode()
      let a = createTextNode(text: "A")
      let decorator = TestDecoratorNodeCrossplatform(numTimes: 0)
      decoratorKey = decorator.getKey()
      let b = createTextNode(text: "B")

      try paragraph.append([a, decorator, b])
      try root.append([paragraph])
    }
    harness.drainMainQueue()

    // Select the decorator attachment range and delete it.
    var decoratorRange: NSRange?
    try editor.read {
      decoratorRange = editor.actualRange(for: decoratorKey)
    }
    guard let decoratorRange else {
      XCTFail("Missing decorator range")
      return
    }

    textView.selectedRange = decoratorRange
    harness.syncSelection(textView)
    textView.deleteBackward()
    harness.drainMainQueue(timeout: 5)

    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "AB")

    var decoratorStillExists = false
    try editor.read { decoratorStillExists = editor.getEditorState().nodeMap[decoratorKey] != nil }
    XCTAssertFalse(decoratorStillExists)
  }
}

#endif
