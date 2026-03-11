// Usage-oriented undo/redo tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical
import EditorHistoryPlugin
import LexicalLinkPlugin
import LexicalListPlugin

@MainActor
final class ReconcilerUsageUndoRedoTests: XCTestCase {

  func testUndoRedoAfterNativeTyping_KeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let history = EditorHistoryPlugin()
    let testView = harness.createTestView(plugins: [history])
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("Hello")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)

    textView.insertText("!")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "Hello!")
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)

    _ = editor.dispatchCommand(type: .undo)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "Hello")
    XCTAssertTrue(history.canUndo)
    XCTAssertTrue(history.canRedo)

    _ = editor.dispatchCommand(type: .redo)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "Hello!")
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)

    // Ensure selection remains valid after history operations.
    textView.selectedRange = NSRange(location: (textView.text as NSString?)?.length ?? 0, length: 0)
    harness.syncSelection(textView)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
  }

  func testUndoRedoAfterListTransform_KeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let history = EditorHistoryPlugin()
    let list = ListPlugin()
    let testView = harness.createTestView(plugins: [history, list])
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("One\nTwo")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    textView.selectedRange = NSRange(location: 0, length: (textView.text as NSString?)?.length ?? 0)
    harness.syncSelection(textView)
    XCTAssertTrue(editor.dispatchCommand(type: .insertUnorderedList))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertTrue(history.canUndo)

    var listCountAfterTransform = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values where node is ListNode {
        listCountAfterTransform += 1
      }
    }
    XCTAssertGreaterThan(listCountAfterTransform, 0)

    _ = editor.dispatchCommand(type: .undo)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "One\nTwo")

    var listCountAfterUndo = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values where node is ListNode {
        listCountAfterUndo += 1
      }
    }
    XCTAssertEqual(listCountAfterUndo, 0)

    _ = editor.dispatchCommand(type: .redo)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    var listCountAfterRedo = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values where node is ListNode {
        listCountAfterRedo += 1
      }
    }
    XCTAssertGreaterThan(listCountAfterRedo, 0)
  }

  func testUndoRedoAfterLinkToggle_KeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let history = EditorHistoryPlugin()
    let link = LinkPlugin()
    let testView = harness.createTestView(plugins: [history, link])
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("Hello World")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    let worldRange = ((textView.text ?? "") as NSString).range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)
    textView.selectedRange = worldRange
    harness.syncSelection(textView)

    var selectionCopy: RangeSelection?
    try editor.update {
      selectionCopy = try getSelection() as? RangeSelection
    }

    XCTAssertTrue(editor.dispatchCommand(
      type: .link,
      payload: LinkPayload(urlString: "https://example.com", originalSelection: selectionCopy)
    ))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertTrue(history.canUndo)

    var effectiveRange = NSRange(location: 0, length: 0)
    let linkValue = textView.textStorage.attribute(.link, at: worldRange.location, effectiveRange: &effectiveRange) as? String
    XCTAssertEqual(linkValue, "https://example.com")
    XCTAssertEqual(effectiveRange.location, worldRange.location)
    XCTAssertGreaterThanOrEqual(effectiveRange.length, worldRange.length)

    _ = editor.dispatchCommand(type: .undo)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertNil(textView.textStorage.attribute(.link, at: worldRange.location, effectiveRange: nil))

    _ = editor.dispatchCommand(type: .redo)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(
      textView.textStorage.attribute(.link, at: worldRange.location, effectiveRange: nil) as? String,
      "https://example.com"
    )
  }
}

#endif
