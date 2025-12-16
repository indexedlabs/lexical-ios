import XCTest
@testable import Lexical

#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import LexicalAppKit
#endif

@MainActor
final class MarkedTextEditorStateIntegrationTests: XCTestCase {

  func testMarkedTextUpdatesEditorState_EndAndCommit() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "Hello")
      try paragraph.append([text])
      try root.append([paragraph])
    }

    let len = testView.attributedTextLength
    testView.setSelectedRange(NSRange(location: len, length: 0))

    testView.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
    testView.setMarkedText("漢字", selectedRange: NSRange(location: 2, length: 0))
    testView.unmarkText()

    var out = ""
    try editor.read { out = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(out.trimmingCharacters(in: .newlines), "Hello漢字")
  }

  func testMarkedTextReplacesSelectedRange() throws {
    let testView = createTestEditorView()
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "Hello world")
      try paragraph.append([text])
      try root.append([paragraph])
    }

    let full = testView.attributedTextString as NSString
    let worldRange = full.range(of: "world")
    XCTAssertNotEqual(worldRange.location, NSNotFound)

    testView.setSelectedRange(worldRange)
    testView.setMarkedText("漢字", selectedRange: NSRange(location: 2, length: 0))
    testView.unmarkText()

    var out = ""
    try editor.read { out = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(out.trimmingCharacters(in: .newlines), "Hello 漢字")
  }
}

