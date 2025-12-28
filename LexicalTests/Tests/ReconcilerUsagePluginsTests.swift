// Usage-oriented plugin scenarios (UIKit only)
#if !os(macOS) || targetEnvironment(macCatalyst)

import XCTest
@testable import Lexical
import LexicalAutoLinkPlugin
import LexicalListPlugin

@MainActor
final class ReconcilerUsagePluginsTests: XCTestCase {

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

  func testAutoLinkPluginTyping_CreatesAutoLinkNode() throws {
    let auto = AutoLinkPlugin()
    let testView = createTestEditorView(plugins: [auto])
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("Visit example.com now")
    drainMainQueue()
    try assertTextParity(editor, textView)

    // Allow node transforms to run even if the last update was selection-only.
    try editor.update {}
    drainMainQueue()

    var autoLinkCount = 0
    try editor.read {
      for node in editor.getEditorState().nodeMap.values {
        if node is AutoLinkNode {
          autoLinkCount += 1
        }
      }
    }
    XCTAssertGreaterThan(autoLinkCount, 0)
  }

  func testListPluginInsertUnorderedListAndBackspaceJoin_DoesNotCrash() throws {
    let list = ListPlugin()
    let testView = createTestEditorView(plugins: [list])
    let editor = testView.editor
    let textView = testView.view.textView
    setupWindowWithView(testView)
    textView.becomeFirstResponder()

    textView.insertText("One")
    drainMainQueue()
    textView.insertText("\n")
    drainMainQueue()
    textView.insertText("Two")
    drainMainQueue()
    try assertTextParity(editor, textView)

    // Convert the current selection's blocks into a bullet list.
    textView.selectedRange = NSRange(location: 0, length: (textView.text as NSString?)?.length ?? 0)
    syncSelection(textView)
    _ = editor.dispatchCommand(type: .insertUnorderedList)
    drainMainQueue()
    try assertTextParity(editor, textView)

    // Backspace at the start of the second line to join items (or at least remove a boundary).
    let native = (textView.text ?? "") as NSString
    let newlineLoc = native.range(of: "\n").location
    XCTAssertNotEqual(newlineLoc, NSNotFound)
    textView.selectedRange = NSRange(location: newlineLoc + 1, length: 0)
    syncSelection(textView)
    textView.deleteBackward()
    drainMainQueue()
    try assertTextParity(editor, textView)
  }
}

#endif

