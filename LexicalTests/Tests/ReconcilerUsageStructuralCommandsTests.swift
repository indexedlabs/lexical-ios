// Usage-oriented structural command tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical
import LexicalLinkPlugin
import LexicalListPlugin

@MainActor
final class ReconcilerUsageStructuralCommandsTests: XCTestCase {

  func testListInsert_KeepsParityAndStructure() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let list = ListPlugin()
    let testView = harness.createTestView(plugins: [list])
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

    var listCount = 0
    var listItemCount = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values {
        if node is ListNode {
          listCount += 1
        } else if node is ListItemNode {
          listItemCount += 1
        }
      }
    }
    XCTAssertGreaterThan(listCount, 0)
    XCTAssertGreaterThan(listItemCount, 0)
  }

  func testLinkToggleAndRemove_KeepsParityAndAttributes() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let link = LinkPlugin()
    let testView = harness.createTestView(plugins: [link])
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

    var effectiveRange = NSRange(location: 0, length: 0)
    let linkValue = textView.textStorage.attribute(.link, at: worldRange.location, effectiveRange: &effectiveRange) as? String
    XCTAssertEqual(linkValue, "https://example.com")
    XCTAssertEqual(effectiveRange.location, worldRange.location)
    XCTAssertGreaterThanOrEqual(effectiveRange.length, worldRange.length)

    var linkNodeCount = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values where node is LinkNode {
        linkNodeCount += 1
      }
    }
    XCTAssertEqual(linkNodeCount, 1)

    XCTAssertTrue(editor.dispatchCommand(type: .removeLink))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertNil(textView.textStorage.attribute(.link, at: worldRange.location, effectiveRange: nil))

    var linkNodeCountAfterRemoval = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values where node is LinkNode {
        linkNodeCountAfterRemoval += 1
      }
    }
    XCTAssertEqual(linkNodeCountAfterRemoval, 0)
  }

  func testIndentOutdentCommands_KeepParityAndIndentState() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    textView.insertText("Indented")
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    textView.selectedRange = NSRange(location: (textView.text as NSString?)?.length ?? 0, length: 0)
    harness.syncSelection(textView)

    XCTAssertTrue(editor.dispatchCommand(type: .indentContent, payload: ()))
    XCTAssertTrue(editor.dispatchCommand(type: .indentContent, payload: ()))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    var indentAfter = -1
    try editor.read {
      indentAfter = (getRoot()?.getFirstChild() as? ParagraphNode)?.getIndent() ?? -1
    }
    XCTAssertEqual(indentAfter, 2)

    XCTAssertTrue(editor.dispatchCommand(type: .outdentContent, payload: ()))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    var indentAfterOutdent = -1
    try editor.read {
      indentAfterOutdent = (getRoot()?.getFirstChild() as? ParagraphNode)?.getIndent() ?? -1
    }
    XCTAssertEqual(indentAfterOutdent, 1)
  }
}

#endif
