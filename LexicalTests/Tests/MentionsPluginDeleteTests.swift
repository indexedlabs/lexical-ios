/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical
@testable import LexicalMentionsPlugin

#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import LexicalAppKit
#endif

@MainActor
final class MentionsPluginDeleteTests: XCTestCase {

  private func drainMainQueue(timeout: TimeInterval = 2) {
    let exp = expectation(description: "drain main queue")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: timeout)
  }

  func testBackspaceAfterMentionSpaceRemovesMentionAndSpace() throws {
    let mentionsPlugin = MentionsPlugin(modes: [.users])
    let testView = createTestEditorView(plugins: [mentionsPlugin])
    let editor = testView.editor

    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        try child.remove()
      }

      let paragraph = createParagraphNode()
      let mentionNode = createMentionNode(mention: "user-1", text: "@alex")
      let spaceNode = createTextNode(text: " ")
      let trailingTextNode = createTextNode(text: "after")
      try paragraph.append([mentionNode, spaceNode, trailingTextNode])
      try root.append([paragraph])
    }
    drainMainQueue()

    let cursorLocation = "@alex ".count
    testView.setSelectedRange(NSRange(location: cursorLocation, length: 0))
    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.applySelectionRange(
        NSRange(location: cursorLocation, length: 0),
        affinity: .backward
      )
    }
    drainMainQueue()

    _ = editor.dispatchCommand(type: .deleteCharacter, payload: true)
    drainMainQueue()

    XCTAssertEqual(testView.attributedTextString, "after")
  }
}
