// Usage-oriented delete/backspace boundary tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical

@MainActor
final class ReconcilerUsageDeleteBoundaryTests: XCTestCase {

  private var window: UIWindow?

  override func tearDown() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
    super.tearDown()
  }

  private func drainMainQueue(timeout: TimeInterval = 2) {
    let exp = expectation(description: "drain main queue")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: timeout)
  }

  private func setupWindowWithView(_ view: TestEditorView) {
    window?.isHidden = true
    window?.rootViewController = nil

    let newWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    newWindow.rootViewController = root
    newWindow.makeKeyAndVisible()

    root.view.addSubview(view.view)
    view.view.frame = newWindow.bounds
    view.view.layoutIfNeeded()

    window = newWindow
  }

  private func syncSelection(_ textView: UITextView) {
    textView.delegate?.textViewDidChangeSelection?(textView)
  }

  private func firstDiffUTF16Index(_ a: String, _ b: String) -> Int? {
    let aNS = a as NSString
    let bNS = b as NSString
    let aLen = aNS.length
    let bLen = bNS.length
    let minLen = min(aLen, bLen)
    for i in 0..<minLen {
      if aNS.character(at: i) != bNS.character(at: i) {
        return i
      }
    }
    return aLen == bLen ? nil : minLen
  }

  private func escapeForDebug(_ s: String) -> String {
    // Make control characters visible (esp. newlines) so diffs are diagnosable.
    var out = ""
    out.reserveCapacity(s.count)
    for scalar in s.unicodeScalars {
      switch scalar.value {
      case 0x0A:
        out.append(contentsOf: "\\n")
      case 0x0D:
        out.append(contentsOf: "\\r")
      case 0x09:
        out.append(contentsOf: "\\t")
      case 0x2028:
        out.append(contentsOf: "\\u2028")
      case 0x2029:
        out.append(contentsOf: "\\u2029")
      default:
        out.append(Character(scalar))
      }
    }
    return out
  }

  private func debugContext(_ text: String, aroundUTF16Index idx: Int, radius: Int = 24) -> String {
    let ns = text as NSString
    let len = ns.length
    guard len > 0 else { return "" }
    let start = max(0, min(idx - radius, len))
    let end = max(0, min(idx + radius, len))
    let sub = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
    return escapeForDebug(sub)
  }

  private func textSnippet(_ text: String, around location: Int, radius: Int = 24) -> String {
    let ns = text as NSString
    let len = ns.length
    guard len > 0 else { return "" }
    let start = max(0, min(location - radius, len))
    let end = max(0, min(location + radius, len))
    return ns.substring(with: NSRange(location: start, length: max(0, end - start)))
  }

  private func assertTextParity(
    _ editor: Editor,
    _ textView: UITextView,
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> Bool {
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    let native = textView.text ?? ""
    if lexical != native {
      let diff = firstDiffUTF16Index(lexical, native) ?? -1
      XCTFail(
        """
        Native text diverged from Lexical.
        lexicalLen=\(lexical.lengthAsNSString()) nativeLen=\(native.lengthAsNSString())
        firstDiffUTF16Index=\(diff)
        lexicalCtx="\(debugContext(lexical, aroundUTF16Index: max(0, diff)))"
        nativeCtx="\(debugContext(native, aroundUTF16Index: max(0, diff)))"
        lexicalTail="\(textSnippet(lexical, around: max(0, lexical.lengthAsNSString() - 1)))"
        nativeTail="\(textSnippet(native, around: max(0, native.lengthAsNSString() - 1)))"
        """,
        file: file,
        line: line
      )
      return false
    }

    let selected = textView.selectedRange
    let length = native.lengthAsNSString()
    if selected.location < 0 || selected.length < 0 || selected.location > length || selected.location + selected.length > length {
      XCTFail(
        """
        Native selection out of bounds.
        selection=\(selected) length=\(length)
        """,
        file: file,
        line: line
      )
      return false
    }

    return true
  }

  private func assertEqualTextWithDiff(
    _ actual: String?,
    _ expected: String,
    message: String,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    guard let actual else {
      XCTFail("Actual text was nil. \(message)", file: file, line: line)
      return
    }

    if actual != expected {
      let diff = firstDiffUTF16Index(actual, expected) ?? -1
      XCTFail(
        """
        \(message)
        actualLen=\(actual.lengthAsNSString()) expectedLen=\(expected.lengthAsNSString())
        firstDiffUTF16Index=\(diff)
        actualCtx="\(debugContext(actual, aroundUTF16Index: max(0, diff)))"
        expectedCtx="\(debugContext(expected, aroundUTF16Index: max(0, diff)))"
        """,
        file: file,
        line: line
      )
    }
  }

  private func assertSelectionRoundTrips(
    _ editor: Editor,
    _ textView: UITextView,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection", file: file, line: line)
        return
      }
      let native = try createNativeSelection(from: selection, editor: editor)
      XCTAssertEqual(native.range, textView.selectedRange, "Selection did not round-trip", file: file, line: line)
      if textView.selectedRange.length == 0 {
        XCTAssertTrue(selection.isCollapsed(), "Lexical selection should be collapsed when native range is collapsed", file: file, line: line)
      }
    }
  }

  private func buildParagraphDocument(
    _ editor: Editor,
    paragraphs: [(String, isEmpty: Bool)],
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    try editor.update {
      guard let root = getRoot() else {
        XCTFail("Missing root", file: file, line: line)
        return
      }
      _ = try root.clear()
      for (text, isEmpty) in paragraphs {
        let p = createParagraphNode()
        if !isEmpty {
          let t = createTextNode(text: text)
          try p.append([t])
        }
        try root.append([p])
      }
    }
  }

  func testBackspaceAtStartOfParagraph_DoesNotDeleteForwardText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("AAA")
    textView.insertText("\n")
    for _ in 0..<10 { textView.insertText("\n") }
    textView.insertText("BBB")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    // Move caret to the start of "BBB".
    let before = (textView.text ?? "") as NSString
    let bbbRange = before.range(of: "BBB")
    XCTAssertNotEqual(bbbRange.location, NSNotFound)
    textView.selectedRange = NSRange(location: bbbRange.location, length: 0)
    syncSelection(textView)
    drainMainQueue()

    let caret = textView.selectedRange.location
    XCTAssertGreaterThan(caret, 0)

    // Backspace should delete the character *before* the caret (a newline), not "BBB".
    let expected = NSMutableString(string: textView.text ?? "")
    expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(
      textView.text,
      expected as String,
      """
      Unexpected deleteBackward() result.
      caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
      """
    )
    XCTAssertTrue((textView.text ?? "").contains("BBB"))
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  func testBackspaceAtStartOfDocument_DoesNotDeleteFirstCharacter() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("ABC")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    textView.selectedRange = NSRange(location: 0, length: 0)
    syncSelection(textView)
    drainMainQueue()

    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(textView.text, "ABC")
    XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  func testRepeatedBackspaceAtStartOfParagraph_DoesNotDeleteForwardText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("AAA")
    textView.insertText("\n")
    for _ in 0..<25 { textView.insertText("\n") }
    textView.insertText("BBB")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    for _ in 0..<15 {
      let current = (textView.text ?? "") as NSString
      let bbbRange = current.range(of: "BBB")
      XCTAssertNotEqual(bbbRange.location, NSNotFound)

      textView.selectedRange = NSRange(location: bbbRange.location, length: 0)
      syncSelection(textView)
      drainMainQueue()

      let caret = textView.selectedRange.location
      XCTAssertGreaterThan(caret, 0)

      let expected = NSMutableString(string: textView.text ?? "")
      expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

      textView.deleteBackward()
      drainMainQueue()

      assertEqualTextWithDiff(
        textView.text,
        expected as String,
        message: """
        Unexpected deleteBackward() result.
        caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
        """
      )
      XCTAssertTrue((textView.text ?? "").contains("BBB"))
      guard try assertTextParity(editor, textView) else { return }
      try assertSelectionRoundTrips(editor, textView)
    }
  }

  func testBackspaceInEmptyParagraph_DoesNotDeleteNextParagraphText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("AAA")
    textView.insertText("\n")
    textView.insertText("\n")
    textView.insertText("BBB")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    let text = (textView.text ?? "") as NSString
    let firstNewline = text.range(of: "\n")
    XCTAssertNotEqual(firstNewline.location, NSNotFound)

    let searchRange = NSRange(
      location: firstNewline.location + firstNewline.length,
      length: max(0, text.length - (firstNewline.location + firstNewline.length))
    )
    let secondNewline = text.range(of: "\n", options: [], range: searchRange)
    XCTAssertNotEqual(secondNewline.location, NSNotFound)

    // Place the caret at the start of the empty paragraph (just before the second newline).
    textView.selectedRange = NSRange(location: secondNewline.location, length: 0)
    syncSelection(textView)
    drainMainQueue()

    let caret = textView.selectedRange.location
    XCTAssertGreaterThan(caret, 0)

    // Backspace should delete the character before the caret (the first newline), not "BBB".
    let expected = NSMutableString(string: textView.text ?? "")
    expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(
      textView.text,
      expected as String,
      """
      Unexpected deleteBackward() result.
      caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
      """
    )
    XCTAssertTrue((textView.text ?? "").contains("BBB"))
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  func testBackspaceAtStartOfParagraph_AfterFenwickDeltas_DoesNotDeleteForwardText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Build a long-ish document with lots of empty paragraphs, plus a trailing token.
    var paragraphs: [(String, isEmpty: Bool)] = []
    paragraphs.append(("AAAA", isEmpty: false))
    for _ in 0..<60 { paragraphs.append(("", isEmpty: true)) }
    paragraphs.append(("BBB", isEmpty: false))

    try buildParagraphDocument(editor, paragraphs: paragraphs)
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    // Mutate early content in a way that should trigger Fenwick deltas (lazy locations for later nodes).
    try editor.update {
      guard let root = getRoot(),
            let firstParagraph = root.getFirstChild() as? ParagraphNode,
            let firstText = firstParagraph.getFirstChild() as? TextNode
      else {
        XCTFail("Missing first paragraph/text")
        return
      }
      try firstText.setText("AAAA" + String(repeating: "x", count: 20))
    }
    drainMainQueue()
    XCTAssertTrue(editor.fenwickHasDeltas, "Expected Fenwick deltas after early text-only edit")
    guard try assertTextParity(editor, textView) else { return }

    // Move caret to start of BBB and delete backward once.
    let before = (textView.text ?? "") as NSString
    let bbbRange = before.range(of: "BBB", options: .backwards)
    XCTAssertNotEqual(bbbRange.location, NSNotFound)
    textView.selectedRange = NSRange(location: bbbRange.location, length: 0)
    syncSelection(textView)
    drainMainQueue()
    try assertSelectionRoundTrips(editor, textView)

    let caret = textView.selectedRange.location
    XCTAssertGreaterThan(caret, 0)

    let expected = NSMutableString(string: textView.text ?? "")
    expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(
      textView.text,
      expected as String,
      """
      Unexpected deleteBackward() result after Fenwick deltas.
      caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
      """
    )
    XCTAssertTrue((textView.text ?? "").contains("BBB"))
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  func testBackspaceAtStartOfParagraph_AfterFenwickDeltasAndDFSRebuild_DoesNotDeleteForwardText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Build a long-ish document with lots of empty paragraphs, plus a trailing token.
    var paragraphs: [(String, isEmpty: Bool)] = []
    paragraphs.append(("AAAA", isEmpty: false))
    for _ in 0..<60 { paragraphs.append(("", isEmpty: true)) }
    paragraphs.append(("BBB", isEmpty: false))

    try buildParagraphDocument(editor, paragraphs: paragraphs)
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    // Trigger Fenwick deltas.
    try editor.update {
      guard let root = getRoot(),
            let firstParagraph = root.getFirstChild() as? ParagraphNode,
            let firstText = firstParagraph.getFirstChild() as? TextNode
      else {
        XCTFail("Missing first paragraph/text")
        return
      }
      try firstText.setText("AAAA" + String(repeating: "x", count: 20))
    }
    drainMainQueue()
    XCTAssertTrue(editor.fenwickHasDeltas, "Expected Fenwick deltas after early text-only edit")

    // Simulate an external DFS cache invalidation while deltas are pending.
    editor.invalidateDFSOrderCache()
    _ = editor.cachedDFSOrderAndIndex()

    // Move caret to start of BBB and delete backward once. This must not delete "BBB".
    let before = (textView.text ?? "") as NSString
    let bbbRange = before.range(of: "BBB", options: .backwards)
    XCTAssertNotEqual(bbbRange.location, NSNotFound)
    textView.selectedRange = NSRange(location: bbbRange.location, length: 0)
    syncSelection(textView)
    drainMainQueue()

    let caret = textView.selectedRange.location
    XCTAssertGreaterThan(caret, 0)

    let expected = NSMutableString(string: textView.text ?? "")
    expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(
      textView.text,
      expected as String,
      """
      Unexpected deleteBackward() result after Fenwick deltas + DFS rebuild.
      caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
      """
    )
    XCTAssertTrue((textView.text ?? "").contains("BBB"))
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  func testBackspaceAtStartOfParagraph_WithoutSelectionSync_DoesNotDeleteForwardText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("AAA")
    textView.insertText("\n")
    for _ in 0..<10 { textView.insertText("\n") }
    textView.insertText("BBB")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    // Put caret at the start of BBB WITHOUT calling selection sync.
    let before = (textView.text ?? "") as NSString
    let bbbRange = before.range(of: "BBB")
    XCTAssertNotEqual(bbbRange.location, NSNotFound)
    textView.selectedRange = NSRange(location: bbbRange.location, length: 0)

    let caret = textView.selectedRange.location
    XCTAssertGreaterThan(caret, 0)
    let expected = NSMutableString(string: textView.text ?? "")
    expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(
      textView.text,
      expected as String,
      """
      Unexpected deleteBackward() result without selection sync.
      caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
      """
    )
    XCTAssertTrue((textView.text ?? "").contains("BBB"))
    _ = try assertTextParity(editor, textView)
  }

  func testBackspaceAtStartOfParagraph_WithLexicalElementSelection_DoesNotDeleteForwardText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Build a doc with a trailing token.
    try buildParagraphDocument(
      editor,
      paragraphs: [
        ("AAA", isEmpty: false),
        ("", isEmpty: true),
        ("", isEmpty: true),
        ("BBB", isEmpty: false),
      ]
    )
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    // Select the BBB paragraph using an element-point selection at offset 0.
    var bbbElementKey: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      guard let bbbPara = root.getLastChild() as? ParagraphNode else {
        XCTFail("Missing BBB paragraph")
        return
      }
      bbbElementKey = bbbPara.getKey()
      let p = Point(key: bbbElementKey, offset: 0, type: .element)
      let sel = RangeSelection(anchor: p, focus: p, format: TextFormat())
      try setSelection(sel)
    }
    drainMainQueue()

    // Drive native selection from Lexical selection.
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      let native = try createNativeSelection(from: selection, editor: editor)
      XCTAssertNotNil(native.range)
      textView.selectedRange = native.range ?? .init(location: 0, length: 0)
    }
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    let caret = textView.selectedRange.location
    XCTAssertGreaterThan(caret, 0)
    let expected = NSMutableString(string: textView.text ?? "")
    expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(
      textView.text,
      expected as String,
      """
      Unexpected deleteBackward() result from element selection.
      caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
      """
    )
    XCTAssertTrue((textView.text ?? "").contains("BBB"))
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  func testEnterBackspaceChurnBeforeTrailingText_DoesNotLoseTrailingText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("AAA")
    textView.insertText("\n")
    for _ in 0..<8 { textView.insertText("\n") }
    textView.insertText("BBB")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    for _ in 0..<10 {
      // Put caret at the start of BBB and insert a newline (creating an empty paragraph in front).
      let current = (textView.text ?? "") as NSString
      let bbbRange = current.range(of: "BBB")
      XCTAssertNotEqual(bbbRange.location, NSNotFound)

      textView.selectedRange = NSRange(location: bbbRange.location, length: 0)
      syncSelection(textView)
      drainMainQueue()

      textView.insertText("\n")
      drainMainQueue()

      XCTAssertTrue((textView.text ?? "").contains("BBB"))
      guard try assertTextParity(editor, textView) else { return }

      // Backspace at the start of BBB should delete the newline we just added, not BBB itself.
      let afterInsert = (textView.text ?? "") as NSString
      let newBBBRange = afterInsert.range(of: "BBB")
      XCTAssertNotEqual(newBBBRange.location, NSNotFound)

      textView.selectedRange = NSRange(location: newBBBRange.location, length: 0)
      syncSelection(textView)
      drainMainQueue()
      try assertSelectionRoundTrips(editor, textView)

      let caret = textView.selectedRange.location
      XCTAssertGreaterThan(caret, 0)
      let expected = NSMutableString(string: textView.text ?? "")
      expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

      textView.deleteBackward()
      drainMainQueue()

      XCTAssertEqual(
        textView.text,
        expected as String,
        """
        Unexpected deleteBackward() result.
        caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
        """
      )
      XCTAssertTrue((textView.text ?? "").contains("BBB"))
      guard try assertTextParity(editor, textView) else { return }
      try assertSelectionRoundTrips(editor, textView)
    }
  }

  func testChurnInMiddle_DoesNotSwallowTrailingMarkerParagraph() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Large-ish document with a trailing marker we should never lose while editing earlier content.
    var paragraphs: [(String, isEmpty: Bool)] = []
    paragraphs.append(("HEAD", isEmpty: false))
    for _ in 0..<40 { paragraphs.append(("", isEmpty: true)) }
    paragraphs.append(("MIDDLE", isEmpty: false))
    for _ in 0..<40 { paragraphs.append(("", isEmpty: true)) }
    paragraphs.append(("TAIL_MARKER", isEmpty: false))

    try buildParagraphDocument(editor, paragraphs: paragraphs)
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }
    XCTAssertTrue((textView.text ?? "").contains("TAIL_MARKER"))

    for _ in 0..<30 {
      // Move caret to the start of "MIDDLE" and insert a newline (creating empty paragraphs in front).
      let current = (textView.text ?? "") as NSString
      let middleRange = current.range(of: "MIDDLE")
      XCTAssertNotEqual(middleRange.location, NSNotFound)
      textView.selectedRange = NSRange(location: middleRange.location, length: 0)
      syncSelection(textView)
      drainMainQueue()

      textView.insertText("\n")
      drainMainQueue()
      XCTAssertTrue((textView.text ?? "").contains("MIDDLE"))
      XCTAssertTrue((textView.text ?? "").contains("TAIL_MARKER"))
      guard try assertTextParity(editor, textView) else { return }
      try assertSelectionRoundTrips(editor, textView)

      // Backspace at the start of "MIDDLE" should delete one character before the caret (a newline),
      // and must not affect "TAIL_MARKER".
      let afterInsert = (textView.text ?? "") as NSString
      let newMiddleRange = afterInsert.range(of: "MIDDLE")
      XCTAssertNotEqual(newMiddleRange.location, NSNotFound)
      textView.selectedRange = NSRange(location: newMiddleRange.location, length: 0)
      syncSelection(textView)
      drainMainQueue()
      try assertSelectionRoundTrips(editor, textView)

      let caret = textView.selectedRange.location
      XCTAssertGreaterThan(caret, 0)
      let expected = NSMutableString(string: textView.text ?? "")
      expected.deleteCharacters(in: NSRange(location: caret - 1, length: 1))

      textView.deleteBackward()
      drainMainQueue()

      assertEqualTextWithDiff(
        textView.text,
        expected as String,
        message: """
        Unexpected deleteBackward() result.
        caret=\(caret) beforeSnippet="\(textSnippet(textView.text ?? "", around: caret))"
        """
      )
      XCTAssertTrue((textView.text ?? "").contains("MIDDLE"))
      XCTAssertTrue((textView.text ?? "").contains("TAIL_MARKER"))
      guard try assertTextParity(editor, textView) else { return }
      try assertSelectionRoundTrips(editor, textView)
    }
  }

  func testSelectionRoundTripAfterFenwickDeltasDuringRapidCaretMoves() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Build a document where early edits will shift later content via Fenwick deltas.
    var paragraphs: [(String, isEmpty: Bool)] = []
    paragraphs.append(("AAAA", isEmpty: false))
    for _ in 0..<120 { paragraphs.append(("", isEmpty: true)) }
    paragraphs.append(("TARGET", isEmpty: false))
    for _ in 0..<120 { paragraphs.append(("", isEmpty: true)) }
    paragraphs.append(("TAIL", isEmpty: false))

    try buildParagraphDocument(editor, paragraphs: paragraphs)
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    // Trigger Fenwick deltas by changing early text length.
    try editor.update {
      guard let root = getRoot(),
            let firstParagraph = root.getFirstChild() as? ParagraphNode,
            let firstText = firstParagraph.getFirstChild() as? TextNode
      else { return }
      try firstText.setText("AAAA" + String(repeating: "x", count: 64))
    }
    drainMainQueue()
    XCTAssertTrue(editor.fenwickHasDeltas, "Expected Fenwick deltas")
    XCTAssertTrue((textView.text ?? "").contains("TARGET"))
    XCTAssertTrue((textView.text ?? "").contains("TAIL"))
    guard try assertTextParity(editor, textView) else { return }

    let ns = (textView.text ?? "") as NSString
    let target = ns.range(of: "TARGET")
    let tail = ns.range(of: "TAIL")
    XCTAssertNotEqual(target.location, NSNotFound)
    XCTAssertNotEqual(tail.location, NSNotFound)

    // Rapidly move the caret around boundary-adjacent locations and ensure Lexical/native stay in sync.
    let probeLocations: [Int] = [
      max(0, target.location - 1),
      target.location,
      target.location + 1,
      target.location + target.length,
      max(0, tail.location - 1),
      tail.location,
    ]

    for _ in 0..<10 {
      for loc in probeLocations {
        let clamped = max(0, min(loc, (textView.text ?? "").lengthAsNSString()))
        textView.selectedRange = NSRange(location: clamped, length: 0)
        syncSelection(textView)
        drainMainQueue()

        guard try assertTextParity(editor, textView) else { return }
        try assertSelectionRoundTrips(editor, textView)
        XCTAssertTrue((textView.text ?? "").contains("TAIL"), "Tail marker must remain intact")
      }

      // Force a DFS cache invalidation while Fenwick deltas may still be pending.
      editor.invalidateDFSOrderCache()
      _ = editor.cachedDFSOrderAndIndex()
    }
  }

  func testBackspaceAtTextNodeBoundary_DoesNotDeleteNextTextNodeFirstCharacter() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    var t2Key: NodeKey = ""
    try editor.update {
      guard let root = getRoot() else { return }
      _ = try root.clear()

      let p = createParagraphNode()
      let t1 = createTextNode(text: "AAA")
      let t2 = createTextNode(text: "BBB")
      t2Key = t2.getKey()
      try p.append([t1, t2])
      try root.append([p])

      // Place selection at the start of the second TextNode.
      _ = try t2.select(anchorOffset: 0, focusOffset: 0)
    }
    drainMainQueue()

    // Drive native selection from Lexical selection (exactly between the two TextNodes).
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      let native = try createNativeSelection(from: selection, editor: editor)
      textView.selectedRange = native.range ?? NSRange(location: 0, length: 0)
    }
    syncSelection(textView)
    drainMainQueue()

    XCTAssertTrue((textView.text ?? "").contains("AAABBB"))
    XCTAssertEqual(textView.selectedRange.length, 0)
    XCTAssertEqual(textView.selectedRange.location, 3, "Expected caret between the two text nodes")
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)

    // Backspace should delete the character before the caret (in the first text node), not "BBB".
    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(textView.text, "AABBB")
    XCTAssertTrue(
      (textView.text ?? "").contains("BB"),
      "Expected second text node content to remain after backspace"
    )
    XCTAssertTrue(
      (textView.text ?? "").contains("BBB"),
      "Expected second text node content to remain unchanged after backspace"
    )

    // Caret should still be before the "BBB" text (now shifted left by 1).
    let after = (textView.text ?? "") as NSString
    let bbbRange = after.range(of: "BBB")
    XCTAssertNotEqual(bbbRange.location, NSNotFound)
    XCTAssertEqual(textView.selectedRange, NSRange(location: bbbRange.location, length: 0))
    guard try assertTextParity(editor, textView) else { return }

    // Selection at the boundary is ambiguous at the Lexical node level (end of t1 vs start of t2),
    // but must round-trip correctly to native and remain collapsed.
    try assertSelectionRoundTrips(editor, textView)
  }

  func testInsertCharacterThenEnterThenBackspace_DoesNotDeleteForwardText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("ABCDEF")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    // Place caret before "DEF" (between C and D).
    textView.selectedRange = NSRange(location: 3, length: 0)
    syncSelection(textView)
    drainMainQueue()
    XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))

    // Insert a character, then insert a paragraph break, then backspace to join.
    // Regression: this sequence could cause the following text ("DEF") to be deleted.
    textView.insertText("f")
    drainMainQueue()
    XCTAssertEqual(textView.text, "ABCfDEF")
    guard try assertTextParity(editor, textView) else { return }

    textView.insertText("\n")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }
    XCTAssertEqual(textView.text, "ABCf\nDEF")

    // Backspace should delete the newline and leave the inserted character and following text intact.
    textView.deleteBackward()
    drainMainQueue()

    XCTAssertEqual(textView.text, "ABCfDEF")
    XCTAssertEqual(textView.selectedRange.length, 0)
    XCTAssertEqual(textView.selectedRange.location, 4, "Expected caret immediately after inserted character")
    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  func testBackspaceAtStartOfParagraph_KeepsCaretBeforeSameText() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("AAA")
    textView.insertText("\n")
    for _ in 0..<25 { textView.insertText("\n") }
    textView.insertText("BBB")
    drainMainQueue()
    guard try assertTextParity(editor, textView) else { return }

    let before = (textView.text ?? "") as NSString
    let bbbRange = before.range(of: "BBB", options: .backwards)
    XCTAssertNotEqual(bbbRange.location, NSNotFound)

    textView.selectedRange = NSRange(location: bbbRange.location, length: 0)
    syncSelection(textView)
    drainMainQueue()

    let caret = textView.selectedRange.location
    XCTAssertEqual(caret, bbbRange.location)
    XCTAssertGreaterThan(caret, 0)

    textView.deleteBackward()
    drainMainQueue()

    // After backspacing the newline before BBB, BBB shifts left by 1 and the caret should stay
    // before BBB (not advance into it).
    let after = (textView.text ?? "") as NSString
    let newBBBRange = after.range(of: "BBB", options: .backwards)
    XCTAssertNotEqual(newBBBRange.location, NSNotFound)
    XCTAssertEqual(textView.selectedRange, NSRange(location: newBBBRange.location, length: 0))

    guard try assertTextParity(editor, textView) else { return }
    try assertSelectionRoundTrips(editor, textView)
  }

  // Note: UIKit's `selectionAffinity` is read-only (no public setter), so tests should not
  // attempt to force affinity directly. We cover affinity-driven behavior via fuzz/usage tests.
}

#endif
