import XCTest
@testable import Lexical
import LexicalListPlugin

#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
@testable import LexicalAppKit
#endif

@MainActor
final class MarkdownHeadingTransformReconcilerTests: XCTestCase {
  private let settleDelay: TimeInterval = 0.05

  private final class MarkdownHeadingShortcutPlugin: Plugin {
    weak var editor: Editor?

    func setUp(editor: Editor) {
      self.editor = editor

      _ = editor.addNodeTransform(
        nodeType: NodeType.text,
        transform: { [weak self] node in
          try self?.transformToHeadingIfNeeded(node: node)
        }
      )
    }

    func tearDown() {}

    private func transformToHeadingIfNeeded(node: Node) throws {
      guard
        let textNode = node as? TextNode,
        let parent = textNode.getParent(),
        isFirstTextNodeInAnElementNode(textNode: textNode)
      else { return }

      guard parent is ParagraphNode || parent is HeadingNode else {
        return
      }

      let text = textNode.getTextContent()
      guard text.hasPrefix("## ") else { return }

      let headingNode = HeadingNode(tag: HeadingTagType.h2)
      let headingTextNode = createTextNode(text: String(text.dropFirst(3)))
      try headingNode.append([headingTextNode])
      try parent.replace(replaceWith: headingNode)
      try headingTextNode.select(anchorOffset: nil, focusOffset: nil)
    }

    private func isFirstTextNodeInAnElementNode(textNode: TextNode) -> Bool {
      guard
        let parent = textNode.getParent(),
        let firstChild = parent.getFirstChild() as? TextNode
      else { return false }

      return firstChild == textNode
    }
  }

  private final class MarkdownBulletShortcutPlugin: Plugin {
    weak var editor: Editor?

    func setUp(editor: Editor) {
      self.editor = editor
      _ = editor.addNodeTransform(
        nodeType: NodeType.text,
        transform: { [weak self] node in
          try self?.transformToBulletListIfNeeded(node: node)
        }
      )
    }

    func tearDown() {}

    private func transformToBulletListIfNeeded(node: Node) throws {
      guard
        let textNode = node as? TextNode,
        let parent = textNode.getParent() as? ParagraphNode,
        textNode == parent.getFirstChild()
      else { return }

      let text = textNode.getTextContent()
      guard text.hasPrefix("- ") else { return }

      let listNode = createListNode(listType: .bullet)
      let listItemNode = ListItemNode()
      let itemTextNode = createTextNode(text: String(text.dropFirst(2)))
      try listItemNode.append([itemTextNode])
      try listNode.append([listItemNode])
      try parent.replace(replaceWith: listNode)
      try itemTextNode.select(anchorOffset: 0, focusOffset: 0)
    }
  }

  func testMarkdownHeadingShortcutTextStorageMatchesRehydratedLexicalState() throws {
    let plugin = MarkdownHeadingShortcutPlugin()
    let mounted = makeHostedTestView(plugins: [plugin])
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    try seedMultilineDocument(in: testView)
    try focusFirstLine(editor: editor)
    settle()
    testView.setSelectedRange(NSRange(location: 0, length: 0))

    testView.insertText("## ")
    settle()

    try assertFirstBlockIsH2Heading(editor: editor)

    let liveTextStorage = testView.attributedTextString
    let stateJSON = try editor.getEditorState().toJSON()
    let rehydratedTextStorage = try rehydratedTextStorage(
      from: stateJSON,
      plugins: []
    )

    XCTAssertEqual(
      liveTextStorage,
      rehydratedTextStorage,
      """
      Heading shortcut text storage diverged from rehydrated lexical state.
      live: \(String(reflecting: liveTextStorage))
      rehydrated: \(String(reflecting: rehydratedTextStorage))
      """
    )
  }

  func testMarkdownBulletShortcutTextStorageMatchesRehydratedLexicalState() throws {
    let listPlugin = ListPlugin()
    let markdownPlugin = MarkdownBulletShortcutPlugin()
    let mounted = makeHostedTestView(plugins: [listPlugin, markdownPlugin])
    defer { mounted.tearDown() }
    let testView = mounted.testView
    let editor = testView.editor

    try seedMultilineDocument(in: testView)
    try focusFirstLine(editor: editor)
    settle()
    testView.setSelectedRange(NSRange(location: 0, length: 0))

    testView.insertText("- ")
    settle()

    try assertFirstBlockIsBulletList(editor: editor)

    let liveTextStorage = testView.attributedTextString
    let stateJSON = try editor.getEditorState().toJSON()
    let rehydratedTextStorage = try rehydratedTextStorage(
      from: stateJSON,
      plugins: [ListPlugin()]
    )

    XCTAssertEqual(
      liveTextStorage,
      rehydratedTextStorage,
      """
      Bullet shortcut text storage diverged from rehydrated lexical state.
      live: \(String(reflecting: liveTextStorage))
      rehydrated: \(String(reflecting: rehydratedTextStorage))
      """
    )
  }

  private func seedMultilineDocument(in testView: TestEditorView) throws {
    let editor = testView.editor
    try editor.update {
      guard let root = getRoot() else {
        throw LexicalError.invariantViolation("Missing root node")
      }

      for child in root.getChildren() {
        try child.remove()
      }

      // Build the multi-line document entirely via the editor API to avoid
      // native text-input interception issues on macOS.
      for _ in 0..<3 {
        let p = createParagraphNode()
        let t = createTextNode(text: "")
        try p.append([t])
        try root.append([p])
      }

      let lastParagraph = createParagraphNode()
      let lastText = createTextNode(text: "Testing this")
      try lastParagraph.append([lastText])
      try root.append([lastParagraph])
      try lastText.select(anchorOffset: 12, focusOffset: 12)
    }
    settle()
  }

  private func focusFirstLine(editor: Editor) throws {
    try editor.update {
      guard
        let root = getRoot(),
        let firstParagraph = root.getFirstChild() as? ParagraphNode,
        let firstText = firstParagraph.getFirstChild() as? TextNode
      else {
        throw LexicalError.invariantViolation("Missing first paragraph/text node")
      }

      try firstText.select(anchorOffset: 0, focusOffset: 0)
    }
  }

  private func assertFirstBlockIsH2Heading(editor: Editor, label: String = "editor") throws {
    try editor.getEditorState().read {
      guard let root = getRoot(), let heading = root.getFirstChild() as? HeadingNode else {
        let firstDescription: String
        let childCount: Int
        if let root = getRoot(), let first = root.getFirstChild() {
          firstDescription = String(describing: type(of: first))
          childCount = root.getChildrenSize()
        } else {
          firstDescription = "nil"
          childCount = getRoot()?.getChildrenSize() ?? 0
        }
        XCTFail("Expected first block to be a heading (\(label)), got \(firstDescription), root children: \(childCount)")
        return
      }
      XCTAssertEqual(heading.getTag(), .h2)
    }
  }

  private func assertFirstBlockIsBulletList(editor: Editor) throws {
    try editor.getEditorState().read {
      guard let root = getRoot(), let list = root.getFirstChild() as? ListNode else {
        let firstDescription: String
        if let root = getRoot(), let first = root.getFirstChild() {
          firstDescription = String(describing: type(of: first))
        } else {
          firstDescription = "nil"
        }
        XCTFail("Expected first block to be a list, got \(firstDescription)")
        return
      }
      XCTAssertEqual(list.getListType(), .bullet)
    }
  }

  private func rehydratedTextStorage(from stateJSON: String, plugins: [Plugin]) throws -> String {
    let rehydratedView = createTestEditorView(plugins: plugins)
    let rehydratedState = try EditorState.fromJSON(
      json: stateJSON,
      editor: rehydratedView.editor
    )
    try rehydratedView.editor.setEditorState(rehydratedState)
    settle()
    return rehydratedView.attributedTextString
  }

  private func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(settleDelay))
  }

  /// Creates a test editor view hosted in a window (needed on macOS for text input/selection).
  private func makeHostedTestView(
    plugins: [Plugin] = []
  ) -> (testView: TestEditorView, tearDown: @MainActor () -> Void) {
    let testView = createTestEditorView(plugins: plugins)
    #if os(macOS) && !targetEnvironment(macCatalyst)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = testView.view
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(testView.view.textView)
    return (testView, { window.orderOut(nil) })
    #else
    return (testView, {})
    #endif
  }
}
