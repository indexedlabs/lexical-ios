#if os(macOS) && !targetEnvironment(macCatalyst)

import AppKit
import XCTest
@testable import Lexical
@testable import LexicalAppKit

@MainActor
final class DecoratorPositionCacheAppKitTests: XCTestCase {

  final class TestInlineDecorator: DecoratorNode {
    override public func clone() -> Self { Self() }
    override public func createView() -> NSView { NSView() }
    override public func decorate(view: NSView) {}
    override public func sizeForDecoratorView(
      textViewWidth: CGFloat,
      attributes: [NSAttributedString.Key: Any]
    ) -> CGSize {
      CGSize(width: 10, height: 10)
    }
  }

  private func makeContext() -> LexicalReadOnlyTextKitContextAppKit {
    let cfg = EditorConfig(theme: Theme(), plugins: [])
    return LexicalReadOnlyTextKitContextAppKit(editorConfig: cfg, featureFlags: FeatureFlags())
  }

  func testPositionCachePopulates_AfterInsertAtStartOfNewline() throws {
    let ctx = makeContext()
    let editor = ctx.editor

    var decoKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      let p1 = createParagraphNode()
      let t = createTextNode(text: "Hello")
      try p1.append([t])
      let p2 = createParagraphNode()
      try root.append([p1, p2])
      try p2.selectStart()
    }
    try editor.update {
      let d = TestInlineDecorator(); decoKey = d.getKey()
      _ = try (getSelection() as? RangeSelection)?.insertNodes(nodes: [d], selectStart: false)
    }

    guard let ts = ctx.textStorage as? TextStorageAppKit else {
      XCTFail("Expected TextStorageAppKit")
      return
    }

    XCTAssertGreaterThan(ts.length, 0)
    XCTAssertNotNil(ts.decoratorPositionCache[decoKey], "Expected cache entry for decorator after insert")

    var foundAttachment = false
    ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length)) { value, _, stop in
      if let att = value as? TextAttachmentAppKit, att.key == decoKey {
        foundAttachment = true
        stop.pointee = true
      }
    }
    XCTAssertTrue(foundAttachment, "Expected TextAttachmentAppKit for inserted decorator to be present")
  }

  func testPositionCachePopulates_MultipleDecoratorsSingleUpdate_MixedPositions() throws {
    let ctx = makeContext()
    let editor = ctx.editor
    var k1 = ""; var k2 = ""; var k3 = ""

    try editor.update {
      guard let root = getRoot() else { return }
      let p1 = createParagraphNode()
      let p2 = createParagraphNode()
      let d1 = TestInlineDecorator(); k1 = d1.getKey()
      let d2 = TestInlineDecorator(); k2 = d2.getKey()
      let d3 = TestInlineDecorator(); k3 = d3.getKey()
      let left = createTextNode(text: "He")
      let right = createTextNode(text: "llo")
      let t2 = createTextNode(text: "World")
      try p1.append([d1, left, d2, right])
      try p2.append([d3, t2])
      try root.append([p1, p2])
    }

    guard let ts = ctx.textStorage as? TextStorageAppKit else {
      XCTFail("Expected TextStorageAppKit")
      return
    }

    let cache = ts.decoratorPositionCache
    XCTAssertNotNil(cache[k1])
    XCTAssertNotNil(cache[k2])
    XCTAssertNotNil(cache[k3])
    for (_, loc) in cache {
      XCTAssertGreaterThanOrEqual(loc, 0)
    }
  }
}

#endif
