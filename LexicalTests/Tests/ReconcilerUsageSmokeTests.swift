// Usage-oriented reconciler smoke tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical
import UniformTypeIdentifiers

@MainActor
final class ReconcilerUsageSmokeTests: XCTestCase {

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

  private func assertTextParity(_ editor: Editor, _ textView: UITextView, file: StaticString = #file, line: UInt = #line) throws {
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(lexical, textView.text ?? "", "Native text diverged from Lexical", file: file, line: line)

    let selected = textView.selectedRange
    let length = (textView.text ?? "").lengthAsNSString()
    XCTAssertGreaterThanOrEqual(selected.location, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(selected.length, 0, file: file, line: line)
    XCTAssertLessThanOrEqual(selected.location, length, file: file, line: line)
    XCTAssertLessThanOrEqual(selected.location + selected.length, length, file: file, line: line)
  }

  private func makeUniquePasteboard() -> (pasteboard: UIPasteboard, name: UIPasteboard.Name)? {
    let name = UIPasteboard.Name("lexical-tests-\(UUID().uuidString)")
    guard let pasteboard = UIPasteboard(name: name, create: true) else { return nil }
    pasteboard.items = []
    return (pasteboard, name)
  }

  func testDeterministicEditingScenario_MaintainsTextParityAndSelectionBounds() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("Hello")
    drainMainQueue()
    try assertTextParity(editor, textView)

    // Move caret into the middle and insert.
    textView.selectedRange = NSRange(location: 2, length: 0)
    syncSelection(textView)
    textView.insertText("X")
    drainMainQueue()
    XCTAssertEqual(textView.text, "HeXllo")
    try assertTextParity(editor, textView)

    // Insert paragraph break (Return) and keep typing.
    textView.insertText("\n")
    drainMainQueue()
    textView.insertText("Y")
    drainMainQueue()
    XCTAssertEqual(textView.text, "HeX\nYllo")
    try assertTextParity(editor, textView)

    // Select across the newline and delete (exercise range delete across paragraph boundary).
    let newlineLoc = (textView.text as NSString?)?.range(of: "\n").location ?? NSNotFound
    XCTAssertNotEqual(newlineLoc, NSNotFound)
    textView.selectedRange = NSRange(location: newlineLoc, length: 2) // "\nY"
    syncSelection(textView)
    textView.deleteBackward()
    drainMainQueue()
    XCTAssertEqual(textView.text, "HeXllo")
    try assertTextParity(editor, textView)

    // Move caret to end and backspace once.
    textView.selectedRange = NSRange(location: (textView.text as NSString?)?.length ?? 0, length: 0)
    syncSelection(textView)
    textView.deleteBackward()
    drainMainQueue()
    XCTAssertEqual(textView.text, "HeXll")
    try assertTextParity(editor, textView)
  }

  func testCopyPasteRoundTrip_PreservesTextAndFormattingAndDoesNotCrash() throws {
    // Source editor/view
    let source = createTestEditorView()
    let sourceEditor = source.editor
    let sourceTextView = source.view.textView
    setupWindowWithView(source)
    sourceTextView.becomeFirstResponder()

    guard let (pasteboard, pasteboardName) = makeUniquePasteboard() else {
      XCTFail("Could not create a unique pasteboard")
      return
    }
    defer { UIPasteboard.remove(withName: pasteboardName) }
    sourceTextView.pasteboard = pasteboard

    // Insert some content through the native input path.
    sourceTextView.insertText("Hello\nWorld")
    drainMainQueue()
    try assertTextParity(sourceEditor, sourceTextView)

    // Select "World" and toggle bold via the command path (exercises formatting + reconciliation).
    let native = (sourceTextView.text ?? "") as NSString
    let worldRange = native.range(of: "World")
    XCTAssertNotEqual(worldRange.location, NSNotFound)
    sourceTextView.selectedRange = worldRange
    syncSelection(sourceTextView)

    _ = sourceEditor.dispatchCommand(type: .formatText, payload: TextFormatType.bold)
    drainMainQueue()

    // Append a character to create a mixed-format run that must reconcile correctly.
    let endLoc = (sourceTextView.text as NSString?)?.length ?? 0
    sourceTextView.selectedRange = NSRange(location: endLoc, length: 0)
    syncSelection(sourceTextView)
    sourceTextView.insertText("!")
    drainMainQueue()

    try assertTextParity(sourceEditor, sourceTextView)
    let expectedText = sourceTextView.text ?? ""

    // Copy everything to the pasteboard (exercises Lexical node serialization path).
    sourceTextView.selectedRange = NSRange(location: 0, length: (expectedText as NSString).length)
    syncSelection(sourceTextView)
    sourceTextView.copy(nil)
    drainMainQueue()

    // Destination editor/view
    let dest = createTestEditorView()
    let destEditor = dest.editor
    let destTextView = dest.view.textView
    setupWindowWithView(dest)
    destTextView.becomeFirstResponder()
    destTextView.pasteboard = pasteboard

    // Ensure a deterministic initial selection for paste paths that require a RangeSelection.
    try destEditor.update {
      guard let root = getRoot() else { return }
      try root.clear()
      let paragraph = createParagraphNode()
      let textNode = createTextNode(text: "")
      try paragraph.append([textNode])
      try root.append([paragraph])
      _ = try textNode.select(anchorOffset: 0, focusOffset: 0)
    }
    drainMainQueue()

    destTextView.selectedRange = NSRange(location: 0, length: 0)
    syncSelection(destTextView)
    destTextView.paste(nil)
    drainMainQueue(timeout: 5)

    XCTAssertEqual(destTextView.text, expectedText)
    try assertTextParity(destEditor, destTextView)

    // Assert we preserved at least some bold formatting in the model.
    var hasBold = false
    try destEditor.read {
      for node in destEditor.getEditorState().nodeMap.values {
        if let textNode = node as? TextNode, textNode.format.bold {
          hasBold = true
          break
        }
      }
    }
    XCTAssertTrue(hasBold, "Expected at least one bold text node after copy/paste round-trip")
  }

  func testDecoratorInsertionThenDeletion_DoesNotCrashAndRemovesNode() throws {
    let testView = createTestEditorView()
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    var decoratorKey: NodeKey = ""
    try editor.update {
      try registerTestDecoratorNode(on: editor)
      guard let root = getRoot() else { return }
      try root.clear()

      let paragraph = createParagraphNode()
      let a = createTextNode(text: "A")
      let decorator = TestDecoratorNodeCrossplatform(numTimes: 0)
      decoratorKey = decorator.getKey()
      let b = createTextNode(text: "B")

      try paragraph.append([a, decorator, b])
      try root.append([paragraph])
    }
    drainMainQueue()

    // Select the decorator attachment range and delete it.
    var decoratorRange: NSRange?
    try editor.read {
      decoratorRange = editor.actualRange(for: decoratorKey)
    }
    guard let decoratorRange else {
      XCTFail("Missing decorator range")
      return
    }

    textView.selectedRange = decoratorRange
    syncSelection(textView)
    textView.deleteBackward()
    drainMainQueue(timeout: 5)

    try assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "AB")

    var decoratorStillExists = false
    try editor.read { decoratorStillExists = editor.getEditorState().nodeMap[decoratorKey] != nil }
    XCTAssertFalse(decoratorStillExists)
  }
}

#endif
