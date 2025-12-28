// Usage-oriented undo/redo tests (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical
import EditorHistoryPlugin

@MainActor
final class ReconcilerUsageUndoRedoTests: XCTestCase {

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

  func testUndoRedoAfterNativeTyping_KeepsParity() throws {
    let history = EditorHistoryPlugin()
    let testView = createTestEditorView(plugins: [history])
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("Hello")
    drainMainQueue()
    try assertTextParity(editor, textView)
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)

    textView.insertText("!")
    drainMainQueue()
    try assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "Hello!")
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)

    _ = editor.dispatchCommand(type: .undo)
    drainMainQueue()
    try assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "Hello")
    XCTAssertTrue(history.canUndo)
    XCTAssertTrue(history.canRedo)

    _ = editor.dispatchCommand(type: .redo)
    drainMainQueue()
    try assertTextParity(editor, textView)
    XCTAssertEqual(textView.text, "Hello!")
    XCTAssertTrue(history.canUndo)
    XCTAssertFalse(history.canRedo)

    // Ensure selection remains valid after history operations.
    textView.selectedRange = NSRange(location: (textView.text as NSString?)?.length ?? 0, length: 0)
    syncSelection(textView)
    drainMainQueue()
    try assertTextParity(editor, textView)
  }
}

#endif
