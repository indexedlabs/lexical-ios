#if os(macOS) && !targetEnvironment(macCatalyst)
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
@testable import Lexical
@testable import LexicalAppKit
import XCTest

@MainActor
final class AppKitRapidTypingSelectionOscillationTests: XCTestCase {
  func testRapidTypingDoesNotOscillateNativeSelection() throws {
    let testView = createTestEditorView(featureFlags: FeatureFlags(verboseLogging: true))
    let editor = testView.editor

    var firstTextKey: NodeKey?
    var secondTextKey: NodeKey?

    // Build a document with enough content "below" so layout/selection sync issues are more likely to show.
    try editor.update { @MainActor in
      guard let root = getRoot() else { return }
      for child in root.getChildren() { try? child.remove() }

      @MainActor
      func para(_ text: String) throws -> ParagraphNode {
        let p = createParagraphNode()
        let t = createTextNode(text: text)
        if firstTextKey == nil {
          firstTextKey = t.getKey()
        } else if secondTextKey == nil {
          secondTextKey = t.getKey()
        }
        try p.append([t])
        return p
      }

      let content: [Node] = [
        try para("first paragraph"),
        createParagraphNode(), // empty
        try para("second paragraph"),
        try para("third paragraph"),
        createParagraphNode(), // empty
        try para("fourth paragraph"),
      ]
      try root.append(content)
    }

    if let firstTextKey, let secondTextKey {
      XCTAssertEqual(
        editor.rangeCache[firstTextKey]?.location,
        0,
        "rangeCache location for first text node is unexpected (firstKey=\(firstTextKey), item=\(String(describing: editor.rangeCache[firstTextKey])))"
      )
      XCTAssertNotNil(
        editor.rangeCache[secondTextKey],
        "rangeCache missing for second text node (secondKey=\(secondTextKey))"
      )
    }

    func drainRunLoop(_ seconds: TimeInterval = 0.01) {
      RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // Put the caret at the start of the document and ensure Lexical selection is in sync before observing.
    // This avoids capturing deferred selection notifications from initial reconciliation as "oscillation".
    testView.setSelectedRange(NSRange(location: 0, length: 0))
    try editor.update {
      let selection = (try getSelection() as? RangeSelection) ?? createEmptyRangeSelection()
      try selection.applySelectionRange(NSRange(location: 0, length: 0), affinity: .forward)
      try setSelection(selection)
    }
    drainRunLoop(0.05)

    var selectionLocations: [Int] = []
    let observer = NotificationCenter.default.addObserver(
      forName: NSTextView.didChangeSelectionNotification,
      object: testView.view.textView,
      queue: nil
    ) { notification in
      if let tv = notification.object as? NSTextView {
        selectionLocations.append(tv.selectedRange().location)
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    // Rapid typing: do not drain the run loop between inserts to better match the reported issue.
    let inserts = 60
    for _ in 0..<inserts {
      testView.view.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    drainRunLoop(0.25)

    // Include the final, settled selection even if notifications were missed.
    let finalLoc = testView.selectedRange.location
    selectionLocations.append(finalLoc)

    let expectedPrefix = String(repeating: "a", count: inserts)
    XCTAssertTrue(
      testView.text.hasPrefix(expectedPrefix),
      "text did not insert at start as expected (prefix=\(String(testView.text.prefix(80))))"
    )

    for i in 1..<selectionLocations.count {
      if selectionLocations[i] < selectionLocations[i - 1] {
        XCTFail("native selection oscillated backward during rapid typing (sequence=\(selectionLocations))")
        return
      }
    }

    XCTAssertEqual(finalLoc, inserts, "final native selection did not advance by insert count")
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
