// Usage-oriented plugin scenarios (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical
import LexicalAutoLinkPlugin
import LexicalListPlugin

@MainActor
final class ReconcilerUsagePluginsTests: XCTestCase {

  func testAutoLinkPluginTyping_CreatesAutoLinkNode() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let auto = AutoLinkPlugin()
    let testView = harness.createTestView(plugins: [auto])
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("Visit example.com now")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    // Allow node transforms to run even if the last update was selection-only.
    try editor.update {}
    harness.drainMainQueue()

    var autoLinkCount = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values {
        if node is AutoLinkNode {
          autoLinkCount += 1
        }
      }
    }
    XCTAssertGreaterThan(autoLinkCount, 0)
  }

  func testListPluginInsertUnorderedListAndBackspaceJoin_DoesNotCrash() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let list = ListPlugin()
    let testView = harness.createTestView(plugins: [list])
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("One")
    harness.drainMainQueue()
    textView.insertText("\n")
    harness.drainMainQueue()
    textView.insertText("Two")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    // Convert the current selection's blocks into a bullet list.
    textView.selectedRange = NSRange(location: 0, length: (textView.text as NSString?)?.length ?? 0)
    harness.syncSelection(textView)
    _ = editor.dispatchCommand(type: .insertUnorderedList)
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    // Backspace at the start of the second line to join items (or at least remove a boundary).
    let native = (textView.text ?? "") as NSString
    let newlineLoc = native.range(of: "\n").location
    XCTAssertNotEqual(newlineLoc, NSNotFound)
    textView.selectedRange = NSRange(location: newlineLoc + 1, length: 0)
    harness.syncSelection(textView)
    textView.deleteBackward()
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
  }
}

#endif
