// Tests for the modern TextKit reconciliation path (UIKit-only).
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical

@MainActor
final class ModernTextKitOptimizationsTests: XCTestCase {

  private func makeView() -> LexicalView {
    let flags = FeatureFlags(
      reconcilerSanityCheck: false,
      proxyTextViewInputDelegate: false,
      reconcilerStrictMode: true
    )
    return LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: flags
    )
  }

  private func seedDocument(editor: Editor) throws {
    try editor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "Hello")
      try p1.append([t1])
      let p2 = createParagraphNode()
      let t2 = createTextNode(text: "World")
      try p2.append([t2])
      try root.append([p1, p2])
    }
  }

  private func applyEdits(editor: Editor) throws {
    try editor.update {
      guard let root = getRoot() else { return }
      guard let p1 = root.getFirstChild() as? ParagraphNode,
            let p2 = root.getLastChild() as? ParagraphNode,
            let t1 = p1.getFirstChild() as? TextNode,
            let t2 = p2.getFirstChild() as? TextNode
      else { return }

      try t1.setText("Hello brave new world")
      try t2.setText("Wide")
      try t1.setBold(true)
      try t2.setItalic(true)
    }
  }

  func testModernTextKitTextAndAttributes() throws {
    let view = makeView()
    try seedDocument(editor: view.editor)
    try applyEdits(editor: view.editor)

    XCTAssertEqual(view.textView.text, "Hello brave new world\nWide")

    let full = (view.textView.text ?? "") as NSString
    let range = full.range(of: "Hello brave new world")
    XCTAssertNotEqual(range.location, NSNotFound)

    var foundBold = false
    if range.location != NSNotFound {
      for i in 0..<range.length {
        let attrs = view.textView.textStorage.attributes(at: range.location + i, effectiveRange: nil)
        if let font = attrs[.font] as? UIFont,
           font.fontDescriptor.symbolicTraits.contains(.traitBold) {
          foundBold = true
          break
        }
      }
    }
    XCTAssertTrue(foundBold)
  }
}

#endif
