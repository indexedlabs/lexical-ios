#if os(macOS) && !targetEnvironment(macCatalyst)

import AppKit
import XCTest
@testable import Lexical
@testable import LexicalAppKit

@MainActor
final class AppKitSelectionIntegrationTests: XCTestCase {

  private func makeView() -> LexicalAppKit.LexicalView {
    LexicalAppKit.LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
  }

  func testProgrammaticSelectionSyncAfterUpdate() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    try editor.update {
      guard let root = getRoot() else { return }
      let p = createParagraphNode()
      let t = createTextNode(text: "Hello world")
      try p.append([t])
      try root.append([p])
    }

    let targetRange = NSRange(location: 6, length: 5)
    textView.setSelectedRange(targetRange)
    textView.handleSelectionChange()

    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection after selection change")
        return
      }
      let native = try createNativeSelectionAppKit(from: selection, editor: editor)
      XCTAssertEqual(native.range, targetRange)
    }
  }

  func testInsertTextAcrossParagraphsKeepsModelInSync() throws {
    let view = makeView()
    let editor = view.editor
    let textView = view.textView

    textView.insertText("Hello world", replacementRange: textView.selectedRange())
    textView.insertText("\n", replacementRange: textView.selectedRange())
    textView.insertText("here's para 2", replacementRange: textView.selectedRange())

    textView.setSelectedRange(NSRange(location: 5, length: 9))
    textView.deleteBackward(nil)

    let expected = textView.string
    try editor.read {
      guard let root = getRoot() else {
        XCTFail("Expected root node")
        return
      }
      XCTAssertEqual(root.getTextContent(), expected)
    }
  }
}

#endif
