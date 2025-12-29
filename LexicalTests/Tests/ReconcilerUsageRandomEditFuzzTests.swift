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
      XCTFail(
        """
        Native text diverged from Lexical.
        lexicalLen=\(lexical.lengthAsNSString()) nativeLen=\(native.lengthAsNSString())
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

    var model = Model(text: textView.text ?? "")
    model.select(textView.selectedRange)
    assertModelMatchesTextView(model, textView, file: file, line: line)
    if !initialText.isEmpty {
      textView.insertText(initialText)
      drainMainQueue()
      guard try assertTextParity(editor, textView, file: file, line: line) else { return }
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
        textView.selectedRange = range
        if programmaticSelectionSyncMode.shouldSync(rng: &rng) {
          syncSelection(textView)
        }
        drainMainQueue()
        ops.append(.select(location: range.location, length: range.length))
        guard try assertTextParity(editor, textView, file: file, line: line) else { return }
        model.select(range)
        assertModelMatchesTextView(model, textView, file: file, line: line)
        continue
      }

      if rng.chance(1, 3) {
        textView.deleteBackward()
        drainMainQueue()
        ops.append(.backspace)
        guard try assertTextParity(editor, textView, file: file, line: line) else { return }
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

      textView.insertText(insert)
      drainMainQueue()
      ops.append(.insert(insert))
      model.insert(insert)

      do {
        guard try assertTextParity(editor, textView, file: file, line: line) else { return }
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
}

#endif
