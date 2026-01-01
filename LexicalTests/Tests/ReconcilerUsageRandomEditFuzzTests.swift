// Seeded edit-fuzz tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical

@MainActor
final class ReconcilerUsageRandomEditFuzzTests: XCTestCase {

  private enum ProgrammaticSelectionSyncMode {
    case always
    case never
    case random(numerator: Int, denominator: Int)

    func shouldSync(rng: inout PRNG) -> Bool {
      switch self {
      case .always:
        return true
      case .never:
        return false
      case let .random(numerator, denominator):
        return rng.chance(numerator, denominator)
      }
    }
  }

  private struct Model {
    var text: NSMutableString
    var selectedRange: NSRange

    init(text: String) {
      self.text = NSMutableString(string: text)
      self.selectedRange = NSRange(location: text.lengthAsNSString(), length: 0)
    }

    mutating func select(_ range: NSRange) {
      selectedRange = range
    }

    mutating func insert(_ string: String) {
      let replacementRange = selectedRange
      text.replaceCharacters(in: replacementRange, with: string)
      selectedRange = NSRange(location: replacementRange.location + string.lengthAsNSString(), length: 0)
    }

    mutating func backspace() {
      if selectedRange.length > 0 {
        text.deleteCharacters(in: selectedRange)
        selectedRange = NSRange(location: selectedRange.location, length: 0)
        return
      }

      let caret = selectedRange.location
      guard caret > 0 else { return }
      let ns = text as NSString
      let del = ns.rangeOfComposedCharacterSequence(at: caret - 1)
      if del.length > 0 {
        text.deleteCharacters(in: del)
        selectedRange = NSRange(location: del.location, length: 0)
      }
    }
  }

  private struct PRNG {
    private(set) var state: UInt64

    init(seed: UInt64) {
      self.state = seed != 0 ? seed : 0x9e3779b97f4a7c15
    }

    mutating func next() -> UInt64 {
      state = state &* 6364136223846793005 &+ 1
      return state
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
      precondition(upperBound > 0)
      return Int(next() % UInt64(upperBound))
    }

    mutating func chance(_ numerator: Int, _ denominator: Int) -> Bool {
      nextInt(denominator) < numerator
    }
  }

  private enum Op: CustomStringConvertible {
    case select(location: Int, length: Int)
    case insert(String)
    case backspace

    var description: String {
      switch self {
      case let .select(location, length):
        return "select(\(location),\(length))"
      case let .insert(text):
        return "insert(\(String(reflecting: text)))"
      case .backspace:
        return "backspace"
      }
    }
  }

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

  private static let debugFuzz = ProcessInfo.processInfo.environment["LEXICAL_FUZZ_DEBUG"] == "1"

  private func assertTextParity(
    _ editor: Editor,
    _ textView: UITextView,
    step: Int = -1,
    ops: [Op] = [],
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> Bool {
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    let native = textView.text ?? ""
    if lexical != native {
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      let opsStr = ops.map(\.description).joined(separator: " -> ")
      XCTFail(
        """
        Native text diverged from Lexical at step \(step).
        lexicalLen=\(lexical.lengthAsNSString()) nativeLen=\(native.lengthAsNSString())
        lexical="\(lexicalEsc)"
        native="\(nativeEsc)"
        selection=\(textView.selectedRange)
        ops=\(opsStr)
        """,
        file: file,
        line: line
      )
      return false
    }

    let selected = textView.selectedRange
    let length = native.lengthAsNSString()
    if selected.location < 0 || selected.length < 0 || selected.location > length || selected.location + selected.length > length {
      XCTFail("Native selection out of bounds: selection=\(selected) length=\(length)", file: file, line: line)
      return false
    }
    return true
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

  private func assertModelMatchesTextView(
    _ model: Model,
    _ textView: UITextView,
    file: StaticString = #file,
    line: UInt = #line
  ) {
    XCTAssertEqual(model.text as String, textView.text ?? "", "Model text diverged", file: file, line: line)
    XCTAssertEqual(model.selectedRange, textView.selectedRange, "Model selection diverged", file: file, line: line)
  }

  private func runFuzz(
    seed: UInt64,
    steps: Int,
    initialText: String,
    programmaticSelectionSyncMode: ProgrammaticSelectionSyncMode = .always,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    var rng = PRNG(seed: seed)
    var ops: [Op] = []

    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    if Self.debugFuzz {
      print("[FUZZ] seed=\(String(format: "0x%llX", seed)) steps=\(steps) initialText=\(String(reflecting: initialText))")
    }

    var model = Model(text: textView.text ?? "")
    model.select(textView.selectedRange)
    assertModelMatchesTextView(model, textView, file: file, line: line)
    if !initialText.isEmpty {
      if Self.debugFuzz {
        print("[FUZZ] init: insertText(\(String(reflecting: initialText)))")
      }
      textView.insertText(initialText)
      drainMainQueue()
      guard try assertTextParity(editor, textView, step: -1, ops: ops, file: file, line: line) else { return }
      model.insert(initialText)
      assertModelMatchesTextView(model, textView, file: file, line: line)
    }

    for i in 0..<steps {
      let ns = (textView.text ?? "") as NSString
      let len = ns.length

      if rng.chance(1, 5) {
        let loc = rng.nextInt(max(1, len + 1))
        let maxLen = max(0, len - loc)
        let selLen = rng.chance(1, 4) ? rng.nextInt(max(1, min(6, maxLen + 1))) : 0
        let range = NSRange(location: loc, length: min(selLen, maxLen))
        if Self.debugFuzz {
          print("[FUZZ] step \(i): select(\(range.location),\(range.length)) textLen=\(len)")
        }
        textView.selectedRange = range
        if programmaticSelectionSyncMode.shouldSync(rng: &rng) {
          syncSelection(textView)
        }
        drainMainQueue()
        ops.append(.select(location: range.location, length: range.length))
        guard try assertTextParity(editor, textView, step: i, ops: ops, file: file, line: line) else { return }
        model.select(range)
        assertModelMatchesTextView(model, textView, file: file, line: line)
        continue
      }

      if rng.chance(1, 3) {
        if Self.debugFuzz {
          print("[FUZZ] step \(i): backspace sel=\(textView.selectedRange) textLen=\(len)")
        }
        textView.deleteBackward()
        drainMainQueue()
        ops.append(.backspace)
        guard try assertTextParity(editor, textView, step: i, ops: ops, file: file, line: line) else { return }
        model.backspace()
        assertModelMatchesTextView(model, textView, file: file, line: line)
        if i % 10 == 0 { try assertSelectionRoundTrips(editor, textView, file: file, line: line) }
        continue
      }

      let insert: String = {
        if rng.chance(1, 6) { return "\n" }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        if rng.chance(1, 10) { return " " }
        return String(alphabet[rng.nextInt(alphabet.count)])
      }()

      if Self.debugFuzz {
        print("[FUZZ] step \(i): insert(\(String(reflecting: insert))) sel=\(textView.selectedRange) textLen=\(len)")
      }
      textView.insertText(insert)
      drainMainQueue()
      ops.append(.insert(insert))
      model.insert(insert)

      do {
        guard try assertTextParity(editor, textView, step: i, ops: ops, file: file, line: line) else { return }
        assertModelMatchesTextView(model, textView, file: file, line: line)
        if i % 10 == 0 { try assertSelectionRoundTrips(editor, textView, file: file, line: line) }
      } catch {
        XCTFail(
          """
          Fuzz parity failed.
          seed=\(seed) step=\(i) lastOp=\(ops.last?.description ?? "<none>")
          ops=\(ops.map(\.description).joined(separator: " "))
          """,
          file: file,
          line: line
        )
        throw error
      }
    }
  }

  func testSeededEditFuzz_MaintainsTextParity() throws {
    // A few fixed seeds to keep this deterministic and stable in CI.
    let seeds: [UInt64] = [0x1, 0x2, 0xdeadbeef, 0x12345678]
    for seed in seeds {
      try runFuzz(seed: seed, steps: 150, initialText: "AAA\n\n\nBBB")
    }
  }

  func testSeededBoundaryChurn_MaintainsTrailingText() throws {
    // Bias toward newline/backspace around a trailing token to catch "swallow" regressions.
    try runFuzz(seed: 0xfeedface, steps: 200, initialText: "AAA\n\n\n\n\n\n\n\n\n\nBBB")
  }

  func testSeededEmojiEditFuzz_MaintainsTextParity() throws {
    // Include composed character sequences to ensure UTF-16 boundary handling stays correct.
    // "👩🏽‍💻" is multiple scalars; "e\u{301}" is a combining sequence.
    try runFuzz(seed: 0xC0FFEE, steps: 120, initialText: "A👩🏽‍💻B\ne\u{301}\n\nBBB")
  }

  func testSeededEditFuzz_WithoutProgrammaticSelectionSync_MaintainsTextParity() throws {
    // Regression: programmatic selection changes do not always fire `textViewDidChangeSelection`.
    // Editing operations should still keep Lexical/native parity by syncing on demand.
    try runFuzz(
      seed: 0xBADC0DE,
      steps: 200,
      initialText: "AAA\n\n\nBBB",
      programmaticSelectionSyncMode: .never
    )
  }

  /// Super minimal test: just check paragraph merge with trailing content
  func testParagraphMergeWithTrailingSpace() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Setup: two paragraphs, second one has trailing "m \n\n"
    textView.insertText("Line1\n\nLine2 m \n\n")
    drainMainQueue()

    func logState(_ label: String) {
      var lexical = ""
      try? editor.read { lexical = getRoot()?.getTextContent() ?? "" }
      let native = textView.text ?? ""
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      print("[\(label)] lexical=\"\(lexicalEsc)\" native=\"\(nativeEsc)\" sel=\(textView.selectedRange)")
    }

    logState("init")

    // Move cursor to start of "Line2" (position 7 = after "Line1\n\n")
    textView.selectedRange = NSRange(location: 7, length: 0)
    syncSelection(textView)
    drainMainQueue()
    logState("after select(7,0)")

    // Backspace to merge paragraphs (delete the \n at position 6)
    textView.deleteBackward()
    drainMainQueue()
    logState("after backspace")

    // Check parity
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    let native = textView.text ?? ""

    if lexical != native {
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      XCTFail("""
        Text diverged after paragraph merge
        lexical="\(lexicalEsc)"
        native="\(nativeEsc)"
        """)
    }
  }

  /// Build the problematic 5-paragraph structure programmatically
  func testProgrammaticMultiParagraphMerge() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Build the structure directly in Lexical:
    // Root
    //   Para0: "A👩🏽‍💻B\n"
    //   Para1: "é\n\nBBB z"
    //   Para2: "m "
    //   Para3: empty
    //   Para4: empty
    try editor.update {
      guard let root = getRoot() else { return }
      // Remove default paragraph
      for child in root.getChildren() {
        try child.remove()
      }

      let p0 = ParagraphNode()
      let t0 = TextNode(text: "A👩🏽‍💻B\n")
      try p0.append([t0])

      let p1 = ParagraphNode()
      let t1 = TextNode(text: "é\n\nBBB z")
      try p1.append([t1])

      let p2 = ParagraphNode()
      let t2 = TextNode(text: "m ")
      try p2.append([t2])

      let p3 = ParagraphNode()  // empty
      let p4 = ParagraphNode()  // empty

      try root.append([p0, p1, p2, p3, p4])

      // Set selection at start of p1 (position 11 - after "A👩🏽‍💻B\n" + postamble "\n")
      _ = try t1.select(anchorOffset: 0, focusOffset: 0)
    }
    drainMainQueue()

    func logState(_ label: String) {
      var lexical = ""
      try? editor.read { lexical = getRoot()?.getTextContent() ?? "" }
      let native = textView.text ?? ""
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      print("[\(label)] lexical=\"\(lexicalEsc)\" native=\"\(nativeEsc)\" sel=\(textView.selectedRange)")
    }

    logState("init")
    dumpNodeTree(editor, label: "init")
    print("textView.selectedRange = \(textView.selectedRange)")

    // Backspace to merge p0 and p1
    textView.deleteBackward()
    drainMainQueue()
    logState("after backspace")
    dumpNodeTree(editor, label: "after backspace")

    // Check parity
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    let native = textView.text ?? ""

    if lexical != native {
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      XCTFail("""
        DIVERGED after programmatic backspace
        lexical="\(lexicalEsc)" len=\(lexical.utf16.count)
        native="\(nativeEsc)" len=\(native.utf16.count)
        """)
    }
  }

  /// Test exact state from step 27-28 of emoji fuzz test
  func testExactStep28State() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // State right before step 28 was:
    // text="A👩🏽‍💻B\n\né\n\nBBB z\nm \n\n" sel={11,0}
    // Let's set that up exactly
    let state = "A👩🏽‍💻B\n\ne\u{301}\n\nBBB z\nm \n\n"
    textView.insertText(state)
    drainMainQueue()

    func logState(_ label: String) {
      var lexical = ""
      try? editor.read { lexical = getRoot()?.getTextContent() ?? "" }
      let native = textView.text ?? ""
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      print("[\(label)] lexical=\"\(lexicalEsc)\" native=\"\(nativeEsc)\" sel=\(textView.selectedRange) len=\(native.utf16.count)")
    }

    logState("init")
    print("UTF-16 length: \(state.utf16.count)")
    dumpNodeTree(editor, label: "init")

    // Move cursor to position 11
    textView.selectedRange = NSRange(location: 11, length: 0)
    syncSelection(textView)
    drainMainQueue()
    logState("after select(11,0)")
    dumpNodeTree(editor, label: "after select(11,0)")

    // Backspace - this should delete the \n at position 10
    textView.deleteBackward()
    drainMainQueue()
    logState("after backspace")
    dumpNodeTree(editor, label: "after backspace")

    // Check parity
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    let native = textView.text ?? ""

    if lexical != native {
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      XCTFail("""
        DIVERGED after backspace at position 11
        lexical="\(lexicalEsc)" len=\(lexical.utf16.count)
        native="\(nativeEsc)" len=\(native.utf16.count)
        """)
    }
  }

  /// Dump Lexical node tree for debugging
  private func dumpNodeTree(_ editor: Editor, label: String) {
    do {
      try editor.read {
        guard let root = getRoot() else {
          print("[\(label)] No root node")
          return
        }
        print("[\(label)] Node tree:")
        dumpNode(root, indent: 0)
      }
    } catch {
      print("[\(label)] Error reading: \(error)")
    }
  }

  private func dumpNode(_ node: Node, indent: Int) {
    let prefix = String(repeating: "  ", count: indent)
    let typeName = String(describing: type(of: node))
    if let textNode = node as? TextNode {
      let text = textNode.getTextPart().replacingOccurrences(of: "\n", with: "\\n")
      print("\(prefix)\(typeName) key=\(node.key) text=\"\(text)\"")
    } else if let element = node as? ElementNode {
      print("\(prefix)\(typeName) key=\(node.key) children=\(element.getChildrenSize())")
      for child in element.getChildren() {
        dumpNode(child, indent: indent + 1)
      }
    } else {
      print("\(prefix)\(typeName) key=\(node.key)")
    }
  }

  /// Minimal reproduction of emoji fuzz failure - isolated operations
  func testMinimalEmojiDivergence() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    // Initial text from emoji fuzz test
    let initialText = "A👩🏽‍💻B\ne\u{301}\n\nBBB"
    textView.insertText(initialText)
    drainMainQueue()

    func logState(_ label: String) {
      var lexical = ""
      try? editor.read { lexical = getRoot()?.getTextContent() ?? "" }
      let native = textView.text ?? ""
      let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
      let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
      print("[\(label)] lexical=\"\(lexicalEsc)\" native=\"\(nativeEsc)\" sel=\(textView.selectedRange)")
    }

    logState("init")

    // Ops from failure: the sequence that leads to divergence
    let ops: [(String, () -> Void)] = [
      ("insert(' ')", { textView.insertText(" ") }),
      ("insert('z')", { textView.insertText("z") }),
      ("insert('q')", { textView.insertText("q") }),
      ("backspace", { textView.deleteBackward() }),
      ("insert('l')", { textView.insertText("l") }),
      ("insert('\\n')", { textView.insertText("\n") }),
      ("insert('h')", { textView.insertText("h") }),
      ("backspace", { textView.deleteBackward() }),
      ("insert('\\n')", { textView.insertText("\n") }),
      ("select(19,0)", { textView.selectedRange = NSRange(location: 19, length: 0); self.syncSelection(textView) }),
      ("insert('\\n')", { textView.insertText("\n") }),
      ("insert('t')", { textView.insertText("t") }),
      ("select(22,0)", { textView.selectedRange = NSRange(location: 22, length: 0); self.syncSelection(textView) }),
      ("backspace", { textView.deleteBackward() }),
      ("backspace", { textView.deleteBackward() }),
      ("select(20,0)", { textView.selectedRange = NSRange(location: 20, length: 0); self.syncSelection(textView) }),
      ("insert('m')", { textView.insertText("m") }),
      ("insert(' ')", { textView.insertText(" ") }),
      ("select(10,0)", { textView.selectedRange = NSRange(location: 10, length: 0); self.syncSelection(textView) }),
      ("insert('\\n')", { textView.insertText("\n") }),
      ("insert(' ')", { textView.insertText(" ") }),
      ("backspace", { textView.deleteBackward() }),
      ("insert('n')", { textView.insertText("n") }),
      ("insert('\\n')", { textView.insertText("\n") }),
      ("backspace", { textView.deleteBackward() }),
      ("backspace", { textView.deleteBackward() }),
      ("insert('x')", { textView.insertText("x") }),
      ("backspace", { textView.deleteBackward() }),
      ("backspace", { textView.deleteBackward() }),
    ]

    for (i, (name, op)) in ops.enumerated() {
      // Dump node tree before steps 27 and 28 for debugging
      if i == 27 || i == 28 {
        dumpNodeTree(editor, label: "BEFORE step \(i)")
      }

      op()
      drainMainQueue()
      logState("step \(i): \(name)")

      // Dump node tree after steps 27 and 28
      if i == 27 || i == 28 {
        dumpNodeTree(editor, label: "AFTER step \(i)")
      }

      var lexical = ""
      try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
      let native = textView.text ?? ""

      if lexical != native {
        let lexicalEsc = lexical.replacingOccurrences(of: "\n", with: "\\n")
        let nativeEsc = native.replacingOccurrences(of: "\n", with: "\\n")
        dumpNodeTree(editor, label: "DIVERGED at step \(i)")
        XCTFail("""
          DIVERGED at step \(i) (\(name))
          lexical="\(lexicalEsc)"
          native="\(nativeEsc)"
          """)
        return
      }
    }
  }
}

#endif
