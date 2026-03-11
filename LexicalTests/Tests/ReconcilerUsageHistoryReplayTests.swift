// Usage-oriented history replay regressions for mixed documents (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
import UIKit
@testable import Lexical
@testable import EditorHistoryPlugin
import LexicalListPlugin

@MainActor
final class ReconcilerUsageHistoryReplayTests: XCTestCase {

  private let placeholderValue = "Add notes..."
  private let checklistTexts = ["Call BCBS", "Follow up with Kaisr"]
  private let paragraphTexts = ["primaryes...", "They'll give a reference no, call back"]

  private struct VisibleDocumentSnapshot: Equatable {
    let paragraphs: [String]
    let checklistItems: [String]
    let hasChecklist: Bool
  }

  private func makePlaceholder() -> LexicalPlaceholderText {
    LexicalPlaceholderText(
      text: placeholderValue,
      font: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize),
      color: .placeholderText
    )
  }

  private func placeholderLabel(in textView: UITextView) -> UILabel? {
    textView.subviews
      .compactMap { $0 as? UILabel }
      .first(where: { $0.text == placeholderValue })
  }

  private func assertPlaceholderHidden(
    _ textView: UITextView,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    let label = try? XCTUnwrap(placeholderLabel(in: textView), file: file, line: line)
    XCTAssertEqual(label?.isHidden, true, "Placeholder should be hidden", file: file, line: line)
  }

  private func assertPlaceholderVisible(
    _ textView: UITextView,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    let label = try? XCTUnwrap(placeholderLabel(in: textView), file: file, line: line)
    XCTAssertEqual(label?.isHidden, false, "Placeholder should be visible", file: file, line: line)
  }

  private func occurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, options: [], range: searchRange) {
      count += 1
      searchRange = found.upperBound..<haystack.endIndex
    }
    return count
  }

  private func appendParagraph(_ text: String, editor: Editor) throws {
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: text)
      try paragraph.append([textNode])
      try root.append([paragraph])
      try textNode.select(anchorOffset: text.lengthAsNSString(), focusOffset: text.lengthAsNSString())
    }
  }

  private func appendChecklistItem(_ text: String, editor: Editor) throws {
    try editor.update {
      guard let root = getRoot() else { return }

      let listNode: ListNode
      if let existing = root.getLastChild() as? ListNode, existing.getListType() == .check {
        listNode = existing
      } else {
        listNode = ListNode(listType: .check, start: 1)
        try root.append([listNode])
      }

      let item = ListItemNode()
      let textNode = createTextNode(text: text)
      try item.append([textNode])
      try listNode.append([item])
      try textNode.select(anchorOffset: text.lengthAsNSString(), focusOffset: text.lengthAsNSString())
    }
  }

  private func normalizeVisibleText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\u{200B}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func visibleSnapshot(editor: Editor) throws -> VisibleDocumentSnapshot {
    var paragraphs: [String] = []
    var checklistItems: [String] = []
    var hasChecklist = false

    try editor.read {
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        if let paragraph = child as? ParagraphNode {
          let text = normalizeVisibleText(paragraph.getTextContent())
          if !text.isEmpty {
            paragraphs.append(text)
          }
        } else if let list = child as? ListNode {
          hasChecklist = hasChecklist || list.getListType() == .check
          for item in list.getChildren() {
            guard let item = item as? ListItemNode else { continue }
            let text = normalizeVisibleText(item.getTextContent())
            if !text.isEmpty {
              checklistItems.append(text)
            }
          }
        }
      }
    }

    return VisibleDocumentSnapshot(
      paragraphs: paragraphs,
      checklistItems: checklistItems,
      hasChecklist: hasChecklist
    )
  }

  private func settleAndAssert(
    harness: ReconcilerIntegrationHarness,
    editor: Editor,
    textView: UITextView
  ) throws {
    harness.drainMainQueue()
    try harness.assertTextParity(editor, textView)
    try harness.assertSelectionRoundTrips(editor, textView)
  }

  @discardableResult
  private func selectText(
    _ text: String,
    in textView: UITextView,
    editor: Editor,
    harness: ReconcilerIntegrationHarness
  ) throws -> NSRange {
    let range = ((textView.text ?? "") as NSString).range(of: text)
    XCTAssertNotEqual(range.location, NSNotFound, "Missing selection text: \(text)")
    textView.selectedRange = range
    harness.syncSelection(textView)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)
    return range
  }

  private func applyLexicalSelection(
    _ range: NSRange,
    editor: Editor,
    textView: UITextView,
    harness: ReconcilerIntegrationHarness
  ) throws {
    textView.selectedRange = range
    harness.syncSelection(textView)

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try selection.applySelectionRange(range, affinity: .forward)
    }

    try settleAndAssert(harness: harness, editor: editor, textView: textView)
  }

  private func performCopy(
    range: NSRange,
    editor: Editor,
    textView: UITextView,
    harness: ReconcilerIntegrationHarness
  ) throws {
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try selection.applySelectionRange(range, affinity: .forward)
      textView.copy(nil)
    }

    try settleAndAssert(harness: harness, editor: editor, textView: textView)
  }

  private func performCut(
    range: NSRange,
    editor: Editor,
    textView: UITextView,
    harness: ReconcilerIntegrationHarness
  ) throws {
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try selection.applySelectionRange(range, affinity: .forward)
      textView.cut(nil)
    }

    try settleAndAssert(harness: harness, editor: editor, textView: textView)
  }

  private func copiedLexicalText(from pasteboard: UIPasteboard, editor: Editor) throws -> String {
    guard let itemSet = pasteboard.itemSet(withPasteboardTypes: [LexicalConstants.pasteboardIdentifier]),
          let data = pasteboard.data(
            forPasteboardType: LexicalConstants.pasteboardIdentifier,
            inItemSet: itemSet
          )?.last
    else {
      XCTFail("No lexical data on pasteboard")
      return ""
    }

    var copiedText = ""
    try editor.read {
      let json = try JSONDecoder().decode(SerializedNodeArray.self, from: data)
      copiedText = normalizeVisibleText(
        json.nodeArray
          .map { $0.getTextContent() }
          .joined()
      )
    }
    return copiedText
  }

  private func assertUniqueVisibleContent(
    _ textView: UITextView,
    expectedParagraphs: [String],
    expectedChecklist: [String],
    file: StaticString = #file,
    line: UInt = #line
  ) {
    let text = textView.text ?? ""
    for paragraph in paragraphTexts {
      let expectedCount = expectedParagraphs.contains(paragraph) ? 1 : 0
      XCTAssertEqual(
        occurrenceCount(of: paragraph, in: text),
        expectedCount,
        "Unexpected paragraph occurrence count for `\(paragraph)` in `\(text)`",
        file: file,
        line: line
      )
    }
    for checklist in checklistTexts {
      let expectedCount = expectedChecklist.contains(checklist) ? 1 : 0
      XCTAssertEqual(
        occurrenceCount(of: checklist, in: text),
        expectedCount,
        "Unexpected checklist occurrence count for `\(checklist)` in `\(text)`",
        file: file,
        line: line
      )
    }
  }

  func testCopyFromMixedChecklistSelection_DoesNotMutateContentOrPlaceholder() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let history = EditorHistoryPlugin()
    let list = ListPlugin()
    let testView = harness.createTestView(
      plugins: [history, list],
      placeholderText: makePlaceholder()
    )
    let editor = testView.editor
    let textView = testView.view.textView

    guard let (pasteboard, pasteboardName) = harness.makeUniquePasteboard() else {
      XCTFail("Could not create a unique pasteboard")
      return
    }
    defer { UIPasteboard.remove(withName: pasteboardName) }
    textView.pasteboard = pasteboard

    try appendParagraph(paragraphTexts[0], editor: editor)
    try appendParagraph(paragraphTexts[1], editor: editor)
    try appendChecklistItem(checklistTexts[0], editor: editor)
    try appendChecklistItem(checklistTexts[1], editor: editor)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)

    let before = try visibleSnapshot(editor: editor)
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)
    assertPlaceholderHidden(textView)

    let selectedRange = try selectText(paragraphTexts[1], in: textView, editor: editor, harness: harness)
    try applyLexicalSelection(selectedRange, editor: editor, textView: textView, harness: harness)
    try performCopy(range: selectedRange, editor: editor, textView: textView, harness: harness)

    XCTAssertEqual(try copiedLexicalText(from: pasteboard, editor: editor), paragraphTexts[1])
    XCTAssertEqual(try visibleSnapshot(editor: editor), before)
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)
    assertPlaceholderHidden(textView)
    assertUniqueVisibleContent(
      textView,
      expectedParagraphs: paragraphTexts,
      expectedChecklist: checklistTexts
    )
  }

  func testCutFromMixedChecklistSelection_UndoRedoPreservesStructureAndPlaceholder() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let history = EditorHistoryPlugin()
    let list = ListPlugin()
    let testView = harness.createTestView(
      plugins: [history, list],
      placeholderText: makePlaceholder()
    )
    let editor = testView.editor
    let textView = testView.view.textView

    guard let (pasteboard, pasteboardName) = harness.makeUniquePasteboard() else {
      XCTFail("Could not create a unique pasteboard")
      return
    }
    defer { UIPasteboard.remove(withName: pasteboardName) }
    textView.pasteboard = pasteboard

    try appendParagraph(paragraphTexts[0], editor: editor)
    try appendParagraph(paragraphTexts[1], editor: editor)
    try appendChecklistItem(checklistTexts[0], editor: editor)
    try appendChecklistItem(checklistTexts[1], editor: editor)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)

    let initial = try visibleSnapshot(editor: editor)
    let selectedRange = try selectText(paragraphTexts[1], in: textView, editor: editor, harness: harness)
    try applyLexicalSelection(selectedRange, editor: editor, textView: textView, harness: harness)

    try performCut(range: selectedRange, editor: editor, textView: textView, harness: harness)

    XCTAssertEqual(try copiedLexicalText(from: pasteboard, editor: editor), paragraphTexts[1])
    XCTAssertEqual(
      try visibleSnapshot(editor: editor),
      VisibleDocumentSnapshot(
        paragraphs: [paragraphTexts[0]],
        checklistItems: checklistTexts,
        hasChecklist: true
      )
    )
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)
    assertPlaceholderHidden(textView)
    assertUniqueVisibleContent(
      textView,
      expectedParagraphs: [paragraphTexts[0]],
      expectedChecklist: checklistTexts
    )

    _ = editor.dispatchCommand(type: .undo)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)

    XCTAssertEqual(try visibleSnapshot(editor: editor), initial)
    XCTAssertEqual(textView.selectedRange, selectedRange)
    XCTAssertTrue(history.canUndo)
    XCTAssertTrue(history.canRedo)
    assertPlaceholderHidden(textView)
    assertUniqueVisibleContent(
      textView,
      expectedParagraphs: paragraphTexts,
      expectedChecklist: checklistTexts
    )

    _ = editor.dispatchCommand(type: .redo)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)

    XCTAssertEqual(
      try visibleSnapshot(editor: editor),
      VisibleDocumentSnapshot(
        paragraphs: [paragraphTexts[0]],
        checklistItems: checklistTexts,
        hasChecklist: true
      )
    )
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)
    assertPlaceholderHidden(textView)
    assertUniqueVisibleContent(
      textView,
      expectedParagraphs: [paragraphTexts[0]],
      expectedChecklist: checklistTexts
    )
  }

  func testUndoRedoReplayAcrossMixedChecklistConstruction_DoesNotDuplicateOrSpliceContent() throws {
    let harness = ReconcilerIntegrationHarness(testCase: self)
    defer { harness.tearDown() }

    let history = EditorHistoryPlugin()
    let list = ListPlugin()
    let testView = harness.createTestView(
      plugins: [history, list],
      placeholderText: makePlaceholder()
    )
    let editor = testView.editor
    let textView = testView.view.textView

    guard let (pasteboard, pasteboardName) = harness.makeUniquePasteboard() else {
      XCTFail("Could not create a unique pasteboard")
      return
    }
    defer { UIPasteboard.remove(withName: pasteboardName) }
    textView.pasteboard = pasteboard

    assertPlaceholderVisible(textView)

    try appendParagraph(paragraphTexts[0], editor: editor)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)
    XCTAssertEqual(
      try visibleSnapshot(editor: editor),
      VisibleDocumentSnapshot(paragraphs: [paragraphTexts[0]], checklistItems: [], hasChecklist: false)
    )

    try appendParagraph(paragraphTexts[1], editor: editor)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)

    try appendChecklistItem(checklistTexts[0], editor: editor)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)

    try appendChecklistItem(checklistTexts[1], editor: editor)
    try settleAndAssert(harness: harness, editor: editor, textView: textView)

    let selectedRange = try selectText(paragraphTexts[1], in: textView, editor: editor, harness: harness)
    try applyLexicalSelection(selectedRange, editor: editor, textView: textView, harness: harness)
    try performCut(range: selectedRange, editor: editor, textView: textView, harness: harness)

    let expectedUndoStates: [VisibleDocumentSnapshot] = [
      VisibleDocumentSnapshot(
        paragraphs: paragraphTexts,
        checklistItems: checklistTexts,
        hasChecklist: true
      ),
      VisibleDocumentSnapshot(
        paragraphs: paragraphTexts,
        checklistItems: [checklistTexts[0]],
        hasChecklist: true
      ),
      VisibleDocumentSnapshot(
        paragraphs: paragraphTexts,
        checklistItems: [],
        hasChecklist: false
      ),
      VisibleDocumentSnapshot(
        paragraphs: [paragraphTexts[0]],
        checklistItems: [],
        hasChecklist: false
      ),
      VisibleDocumentSnapshot(
        paragraphs: [],
        checklistItems: [],
        hasChecklist: false
      )
    ]

    let expectedUndoVisibleParagraphs: [[String]] = [
      paragraphTexts,
      paragraphTexts,
      paragraphTexts,
      [paragraphTexts[0]],
      []
    ]

    let expectedUndoVisibleChecklist: [[String]] = [
      checklistTexts,
      [checklistTexts[0]],
      [],
      [],
      []
    ]

    for (index, expected) in expectedUndoStates.enumerated() {
      _ = editor.dispatchCommand(type: .undo)
      try settleAndAssert(harness: harness, editor: editor, textView: textView)
      XCTAssertEqual(
        try visibleSnapshot(editor: editor),
        expected,
        "Unexpected visible snapshot after undo step \(index + 1)"
      )
      assertUniqueVisibleContent(
        textView,
        expectedParagraphs: expectedUndoVisibleParagraphs[index],
        expectedChecklist: expectedUndoVisibleChecklist[index]
      )
    }

    XCTAssertFalse(history.canUndo)
    XCTAssertTrue(history.canRedo)
    assertPlaceholderVisible(textView)

    let expectedRedoStates: [VisibleDocumentSnapshot] = [
      VisibleDocumentSnapshot(
        paragraphs: [paragraphTexts[0]],
        checklistItems: [],
        hasChecklist: false
      ),
      VisibleDocumentSnapshot(
        paragraphs: paragraphTexts,
        checklistItems: [],
        hasChecklist: false
      ),
      VisibleDocumentSnapshot(
        paragraphs: paragraphTexts,
        checklistItems: [checklistTexts[0]],
        hasChecklist: true
      ),
      VisibleDocumentSnapshot(
        paragraphs: paragraphTexts,
        checklistItems: checklistTexts,
        hasChecklist: true
      ),
      VisibleDocumentSnapshot(
        paragraphs: [paragraphTexts[0]],
        checklistItems: checklistTexts,
        hasChecklist: true
      )
    ]

    let expectedRedoVisibleParagraphs: [[String]] = [
      [paragraphTexts[0]],
      paragraphTexts,
      paragraphTexts,
      paragraphTexts,
      [paragraphTexts[0]]
    ]

    let expectedRedoVisibleChecklist: [[String]] = [
      [],
      [],
      [checklistTexts[0]],
      checklistTexts,
      checklistTexts
    ]

    for (index, expected) in expectedRedoStates.enumerated() {
      _ = editor.dispatchCommand(type: .redo)
      try settleAndAssert(harness: harness, editor: editor, textView: textView)
      XCTAssertEqual(
        try visibleSnapshot(editor: editor),
        expected,
        "Unexpected visible snapshot after redo step \(index + 1)"
      )
      assertUniqueVisibleContent(
        textView,
        expectedParagraphs: expectedRedoVisibleParagraphs[index],
        expectedChecklist: expectedRedoVisibleChecklist[index]
      )
    }

    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)
    assertPlaceholderHidden(textView)
  }
}

#endif
