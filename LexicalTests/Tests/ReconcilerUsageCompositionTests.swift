// Usage-oriented composition tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical

@MainActor
final class ReconcilerUsageCompositionTests: XCTestCase {

  func testMarkedTextLifecycle_KeepsParityAndSelectionBounds() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "Hello")
      try paragraph.append([text])
      try root.append([paragraph])
    }
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    let start = testView.attributedTextLength
    testView.setSelectedRange(NSRange(location: start, length: 0))
    harness.syncSelection(textView)

    testView.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    testView.setMarkedText("漢字", selectedRange: NSRange(location: 2, length: 0))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    testView.unmarkText()
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertFalse(testView.hasMarkedText)
    XCTAssertEqual(textView.text?.trimmingCharacters(in: .newlines), "Hello漢字")
  }

  func testMarkedTextReplacesSelectedRange_KeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "Hello world")
      try paragraph.append([text])
      try root.append([paragraph])
    }
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    let worldRange = (testView.attributedTextString as NSString).range(of: "world")
    XCTAssertNotEqual(worldRange.location, NSNotFound)
    testView.setSelectedRange(worldRange)
    harness.syncSelection(textView)

    testView.setMarkedText("漢字", selectedRange: NSRange(location: 2, length: 0))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    testView.unmarkText()
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(textView.text?.trimmingCharacters(in: .newlines), "Hello 漢字")
  }

  func testMarkedTextEmojiCluster_KeepsParity() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let testView = harness.createTestView()
    let editor = testView.editor
    let textView = testView.view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "Hello")
      try paragraph.append([text])
      try root.append([paragraph])
    }
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    let base = "👍"
    let composed = "👍🏽"
    testView.setSelectedRange(NSRange(location: testView.attributedTextLength, length: 0))
    harness.syncSelection(textView)

    testView.setMarkedText(base, selectedRange: NSRange(location: base.lengthAsNSString(), length: 0))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    testView.setMarkedText(composed, selectedRange: NSRange(location: composed.lengthAsNSString(), length: 0))
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)

    testView.unmarkText()
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    XCTAssertEqual(textView.text?.trimmingCharacters(in: .newlines), "Hello\(composed)")
  }
}

#endif
