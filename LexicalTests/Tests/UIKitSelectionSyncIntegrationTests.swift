// UIKit-only selection sync integration tests
#if !os(macOS) || targetEnvironment(macCatalyst)

import UIKit
import XCTest
@testable import Lexical

@MainActor
final class UIKitSelectionSyncIntegrationTests: XCTestCase {

  private func makeView() -> LexicalView {
    LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
  }

  private func syncSelection(_ textView: UITextView) {
    textView.delegate?.textViewDidChangeSelection?(textView)
  }

  func testNativeSelectionChangeUpdatesLexicalSelection() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    var textNodeKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      textNodeKey = textNode.getKey()
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 11, focusOffset: 11)
    }

    let nativeString = (textView.attributedText?.string ?? "") as NSString
    let helloRange = nativeString.range(of: "Hello")
    XCTAssertNotEqual(helloRange.location, NSNotFound)

    let nativePositionAfterHello = helloRange.location + helloRange.length
    textView.selectedRange = NSRange(location: nativePositionAfterHello, length: 0)
    syncSelection(textView)

    var updatedAnchorKey: NodeKey = ""
    var updatedAnchorOffset = -1
    var updatedFocusOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection after selection sync")
        return
      }
      updatedAnchorKey = selection.anchor.key
      updatedAnchorOffset = selection.anchor.offset
      updatedFocusOffset = selection.focus.offset
    }

    XCTAssertEqual(updatedAnchorKey, textNodeKey)
    XCTAssertEqual(updatedAnchorOffset, 5)
    XCTAssertEqual(updatedFocusOffset, 5)
  }

  func testNativeRangeSelectionUpdatesLexicalSelection() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 0, focusOffset: 0)
    }

    let nativeString = (textView.attributedText?.string ?? "") as NSString
    let helloRange = nativeString.range(of: "Hello")
    XCTAssertNotEqual(helloRange.location, NSNotFound)

    textView.selectedRange = helloRange
    syncSelection(textView)

    var anchorOffset = -1
    var focusOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection after range selection sync")
        return
      }
      anchorOffset = selection.anchor.offset
      focusOffset = selection.focus.offset
    }

    XCTAssertEqual(anchorOffset, 0)
    XCTAssertEqual(focusOffset, 5)
  }

  func testBackspaceDeletesSelectedRange() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 11, focusOffset: 11)
    }

    let nativeString = (textView.attributedText?.string ?? "") as NSString
    let worldRange = nativeString.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)

    textView.selectedRange = worldRange
    syncSelection(textView)
    textView.deleteBackward()

    var finalText = ""
    try editor.read {
      finalText = getRoot()?.getTextContent() ?? ""
    }
    XCTAssertTrue(finalText.contains("Hello"))
    XCTAssertFalse(finalText.contains("World"))
  }

  func testBackspaceDeletesSelectedRangeWithoutSelectionSync() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "Hello World")
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 11, focusOffset: 11)
    }

    let nativeString = (textView.attributedText?.string ?? "") as NSString
    let worldRange = nativeString.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)

    // Regression: programmatic selection changes do not always fire `textViewDidChangeSelection`.
    // Backspace should still delete the selected text by syncing Lexical selection on demand.
    textView.selectedRange = worldRange
    textView.deleteBackward()

    var finalText = ""
    try editor.read { finalText = getRoot()?.getTextContent() ?? "" }
    XCTAssertTrue(finalText.contains("Hello"))
    XCTAssertFalse(finalText.contains("World"))
  }

  func testRepeatedSelectAndBackspace() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "AAABBBCCC")
      try paragraph.append([textNode])
      try root.append([paragraph])
    }

    var nativeString = (textView.attributedText?.string ?? "") as NSString
    var bbbRange = nativeString.range(of: "BBB")
    XCTAssertNotEqual(bbbRange.location, NSNotFound)

    textView.selectedRange = bbbRange
    syncSelection(textView)
    textView.deleteBackward()

    var afterFirst = ""
    try editor.read { afterFirst = getRoot()?.getTextContent() ?? "" }
    XCTAssertFalse(afterFirst.contains("BBB"))
    XCTAssertTrue(afterFirst.contains("AAA"))
    XCTAssertTrue(afterFirst.contains("CCC"))

    nativeString = (textView.attributedText?.string ?? "") as NSString
    let cccRange = nativeString.range(of: "CCC")
    XCTAssertNotEqual(cccRange.location, NSNotFound)

    textView.selectedRange = cccRange
    syncSelection(textView)
    textView.deleteBackward()

    var afterSecond = ""
    try editor.read { afterSecond = getRoot()?.getTextContent() ?? "" }
    XCTAssertFalse(afterSecond.contains("CCC"))
    XCTAssertTrue(afterSecond.contains("AAA"))
  }

  func testNativeSelectionWithMultipleParagraphs() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    var worldKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let p1 = createParagraphNode()
      let p2 = createParagraphNode()
      let hello = createTextNode(text: "Hello")
      let world = createTextNode(text: "World")
      worldKey = world.getKey()
      try p1.append([hello])
      try p2.append([world])
      try root.append([p1, p2])
      _ = try hello.select(anchorOffset: 0, focusOffset: 0)
    }

    let nativeString = (textView.attributedText?.string ?? "") as NSString
    let worldRange = nativeString.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)

    let nativePosition = worldRange.location + 2
    textView.selectedRange = NSRange(location: nativePosition, length: 0)
    syncSelection(textView)

    var anchorKey: NodeKey = ""
    var anchorOffset = -1
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection after multi-paragraph selection sync")
        return
      }
      anchorKey = selection.anchor.key
      anchorOffset = selection.anchor.offset
    }

    XCTAssertEqual(anchorKey, worldKey)
    XCTAssertEqual(anchorOffset, 2)
  }
}

#endif
