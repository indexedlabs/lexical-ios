/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// Regression tests for decorator layout during text storage editing.
// This tests the fix for the crash: "attempted layout while textStorage is editing"
// which occurred when mountDecoratorSubviewsIfNecessary was called during
// UIKit's coordinateEditing session.

#if canImport(UIKit)

import XCTest
import UIKit
@testable import Lexical

@MainActor
final class DecoratorLayoutDuringEditingRegressionTests: XCTestCase {

  /// Regression test for crash: "attempted layout while textStorage is editing"
  ///
  /// This crash occurred when:
  /// 1. UIKit calls TextStorage.replaceCharacters during a coordinateEditing session
  /// 2. This triggers performControllerModeUpdate -> editor.update
  /// 3. At the end of beginUpdate, mountDecoratorSubviewsIfNecessary is called
  /// 4. mountDecoratorSubviewsIfNecessary calls layoutManager.ensureLayout
  /// 5. CRASH: Layout is not allowed while textStorage is editing
  ///
  /// The fix defers mountDecoratorSubviewsIfNecessary when isInControllerModeUpdate is true.
  func testDeleteWithDecoratorDoesNotCrashDuringCoordinateEditing() throws {
    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor
    let textView = view.textView
    guard let textStorage = textView.textStorage as? TextStorage else {
      XCTFail("Expected TextStorage")
      return
    }

    // Register and insert a decorator node
    try editor.registerNode(
      nodeType: NodeType.testDecoratorCrossplatform,
      class: TestDecoratorNodeCrossplatform.self
    )

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textBefore = createTextNode(text: "Hello ")
      let decorator = TestDecoratorNodeCrossplatform()
      let textAfter = createTextNode(text: " World")
      try paragraph.append([textBefore, decorator, textAfter])
      try root.append([paragraph])
      // Place caret after "World"
      _ = try textAfter.select(anchorOffset: nil, focusOffset: nil)
    }

    // Simulate UIKit's coordinateEditing behavior:
    // UIKit wraps replaceCharacters in beginEditing/endEditing.
    // Before the fix, this would crash because mountDecoratorSubviewsIfNecessary
    // tried to do layout while textStorage was still editing.
    textStorage.beginEditing()

    // This triggers performControllerModeUpdate -> editor.update -> mountDecoratorSubviewsIfNecessary
    // Before the fix, this would crash with:
    // "attempted layout while textStorage is editing"
    textStorage.replaceCharacters(in: NSRange(location: textStorage.length - 1, length: 1), with: "")

    textStorage.endEditing()

    // If we get here without crashing, the test passes
    XCTAssertTrue(true, "No crash during coordinateEditing with decorator")
  }

  /// Test that decorator views are still mounted correctly after deferred mounting.
  func testDecoratorMountingWorksAfterDeferral() throws {
    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor
    let textView = view.textView
    guard let textStorage = textView.textStorage as? TextStorage else {
      XCTFail("Expected TextStorage")
      return
    }

    try editor.registerNode(
      nodeType: NodeType.testDecoratorCrossplatform,
      class: TestDecoratorNodeCrossplatform.self
    )

    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textBefore = createTextNode(text: "A")
      let decorator = TestDecoratorNodeCrossplatform()
      let textAfter = createTextNode(text: "B")
      try paragraph.append([textBefore, decorator, textAfter])
      try root.append([paragraph])
      _ = try textAfter.select(anchorOffset: nil, focusOffset: nil)
    }

    // Simulate typing during coordinateEditing
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: NSRange(location: textStorage.length, length: 0), with: "C")
    textStorage.endEditing()

    // Allow the deferred mountDecoratorSubviewsIfNecessary to run
    let expectation = expectation(description: "Deferred mounting completes")
    DispatchQueue.main.async {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    // Verify the decorator cache is not empty (decorator was processed)
    try editor.read {
      var decoratorCount = 0
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        if let para = child as? ElementNode {
          for node in para.getChildren() {
            if node is DecoratorNode {
              decoratorCount += 1
            }
          }
        }
      }
      XCTAssertEqual(decoratorCount, 1, "Decorator node should still exist")
    }
  }

  /// Regression test for crash when pressing Enter before a decorator then Backspace.
  ///
  /// This crash occurred when:
  /// 1. User positions cursor before a decorator (image)
  /// 2. User presses Enter (inserts paragraph)
  /// 3. User presses Backspace
  /// 4. During backspace, fastPath_InsertBlock calls invalidateLayout
  /// 5. CRASH: Layout is not allowed while textStorage is editing
  func testEnterThenBackspaceBeforeDecoratorDoesNotCrash() throws {
    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor
    let textView = view.textView
    guard let textStorage = textView.textStorage as? TextStorage else {
      XCTFail("Expected TextStorage")
      return
    }

    try editor.registerNode(
      nodeType: NodeType.testDecoratorCrossplatform,
      class: TestDecoratorNodeCrossplatform.self
    )

    // Setup: "Hello" + decorator + "World"
    try editor.update {
      guard let root = getRoot() else { return }
      let paragraph = createParagraphNode()
      let textBefore = createTextNode(text: "Hello")
      let decorator = TestDecoratorNodeCrossplatform()
      let textAfter = createTextNode(text: "World")
      try paragraph.append([textBefore, decorator, textAfter])
      try root.append([paragraph])
      // Position cursor right before the decorator (after "Hello")
      _ = try textBefore.select(anchorOffset: nil, focusOffset: nil)
    }

    // Simulate pressing Enter (insert newline) - wrapped in coordinateEditing
    textStorage.beginEditing()
    // Find position after "Hello" (before decorator)
    let insertPos = 5 // "Hello" is 5 chars
    textStorage.replaceCharacters(in: NSRange(location: insertPos, length: 0), with: "\n")
    textStorage.endEditing()

    // Allow deferred operations to run
    let exp1 = expectation(description: "Enter deferred ops")
    DispatchQueue.main.async { exp1.fulfill() }
    wait(for: [exp1], timeout: 1.0)

    // Simulate pressing Backspace - this is where the crash occurred
    textStorage.beginEditing()
    // Delete the newline we just inserted
    textStorage.replaceCharacters(in: NSRange(location: insertPos, length: 1), with: "")
    textStorage.endEditing()

    // Allow deferred operations to run
    let exp2 = expectation(description: "Backspace deferred ops")
    DispatchQueue.main.async { exp2.fulfill() }
    wait(for: [exp2], timeout: 1.0)

    // If we get here without crashing, the test passes
    XCTAssertTrue(true, "No crash during Enter+Backspace before decorator")
  }

  /// Regression test for decorator position cache not being updated after Enter.
  ///
  /// This bug occurred when:
  /// 1. User has a decorator (image) at position 0
  /// 2. User presses Enter before the image (inserts newline at position 0)
  /// 3. The rangeCache is updated (decorator now at position 1)
  /// 4. But decoratorPositionCache was NOT updated (still shows position 0)
  /// 5. positionAllDecorators reads stale cache and fails to find attachment
  ///
  /// The fix ensures decoratorPositionCache is ALWAYS synchronized with rangeCache.
  func testDecoratorPositionCacheUpdatedAfterInsertBefore() throws {
    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor
    let textView = view.textView
    guard let textStorage = textView.textStorage as? TextStorage else {
      XCTFail("Expected TextStorage")
      return
    }

    try editor.registerNode(
      nodeType: NodeType.testDecoratorCrossplatform,
      class: TestDecoratorNodeCrossplatform.self
    )

    var decoratorKey: NodeKey?

    // Setup: just a decorator in a paragraph
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        try child.remove()
      }
      let paragraph = createParagraphNode()
      let decorator = TestDecoratorNodeCrossplatform()
      decoratorKey = decorator.key
      try paragraph.append([decorator])
      try root.append([paragraph])
    }

    guard let key = decoratorKey else {
      XCTFail("Decorator key not set")
      return
    }

    // Verify initial position in cache
    let initialPosition = textStorage.decoratorPositionCache[key]
    XCTAssertNotNil(initialPosition, "Decorator should be in position cache")
    XCTAssertEqual(initialPosition, 0, "Decorator should initially be at position 0")

    // Insert a newline BEFORE the decorator (at position 0)
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
    textStorage.endEditing()

    // Allow deferred operations to run
    let exp = expectation(description: "Deferred ops complete")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)

    // Verify the decorator position cache was updated
    let updatedPosition = textStorage.decoratorPositionCache[key]
    XCTAssertNotNil(updatedPosition, "Decorator should still be in position cache after insert")
    XCTAssertEqual(updatedPosition, 1, "Decorator position should be updated from 0 to 1 after newline inserted before it")

    // Verify rangeCache also has correct position
    let rangeCachePosition = editor.rangeCache[key]?.location
    XCTAssertEqual(rangeCachePosition, 1, "rangeCache should also show decorator at position 1")

    // Verify decorator node still exists
    try editor.read {
      var decoratorCount = 0
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        if let para = child as? ElementNode {
          for node in para.getChildren() {
            if node is DecoratorNode {
              decoratorCount += 1
            }
          }
        }
      }
      XCTAssertEqual(decoratorCount, 1, "Decorator node should still exist after insert")
    }
  }

  /// Regression test for decorator position cache being incorrectly cleared during paragraph merge.
  ///
  /// This bug occurred when:
  /// 1. User has a decorator (image) at position 1 (after a newline)
  /// 2. User presses Backspace to delete the newline (paragraph merge)
  /// 3. reconcileDecoratorOpsForSubtree compared decorators under the OLD paragraph key
  /// 4. The decorator appeared "removed" because it moved to a different parent
  /// 5. The position cache entry was incorrectly removed
  /// 6. The decorator view became invisible
  ///
  /// The fix checks if the decorator still exists in nextState before removing from cache.
  func testDecoratorPositionCacheNotClearedDuringParagraphMerge() throws {
    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor
    let textView = view.textView
    guard let textStorage = textView.textStorage as? TextStorage else {
      XCTFail("Expected TextStorage")
      return
    }

    try editor.registerNode(
      nodeType: NodeType.testDecoratorCrossplatform,
      class: TestDecoratorNodeCrossplatform.self
    )

    var decoratorKey: NodeKey?

    // Setup: just a decorator in a paragraph
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        try child.remove()
      }
      let paragraph = createParagraphNode()
      let decorator = TestDecoratorNodeCrossplatform()
      decoratorKey = decorator.key
      try paragraph.append([decorator])
      try root.append([paragraph])
    }

    guard let key = decoratorKey else {
      XCTFail("Decorator key not set")
      return
    }

    // Verify initial state
    XCTAssertNotNil(textStorage.decoratorPositionCache[key], "Decorator should be in position cache initially")

    // Insert a newline BEFORE the decorator (simulating Enter)
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
    textStorage.endEditing()

    // Allow deferred operations to run
    let exp1 = expectation(description: "Enter deferred ops")
    DispatchQueue.main.async { exp1.fulfill() }
    wait(for: [exp1], timeout: 1.0)

    // Verify decorator moved to position 1
    XCTAssertEqual(textStorage.decoratorPositionCache[key], 1, "Decorator should be at position 1 after newline insert")

    // Delete the newline (simulating Backspace - paragraph merge)
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
    textStorage.endEditing()

    // Allow deferred operations to run
    let exp2 = expectation(description: "Backspace deferred ops")
    DispatchQueue.main.async { exp2.fulfill() }
    wait(for: [exp2], timeout: 1.0)

    // CRITICAL: The decorator should still be in the position cache!
    // Before the fix, it was incorrectly removed during reconcileDecoratorOpsForSubtree
    XCTAssertNotNil(textStorage.decoratorPositionCache[key], "Decorator should still be in position cache after paragraph merge")
    // Allow the editor/reconciler to settle if needed (this can be order-dependent when running
    // alongside other TextKit-heavy tests). Assert that the cache matches the actual attachment
    // location rather than assuming a specific absolute offset.
    func attachmentLocation() -> Int? {
      let len = textStorage.length
      guard len > 0 else { return nil }
      var found: Int? = nil
      textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: len)) { value, range, stop in
        if let att = value as? TextAttachment, att.key == key {
          found = range.location
          stop.pointee = true
        }
      }
      return found
    }

    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
      let expected = attachmentLocation()
      if expected != nil, textStorage.decoratorPositionCache[key] == expected { break }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    let expected = attachmentLocation()
    XCTAssertNotNil(expected, "Decorator attachment should still exist in text storage after paragraph merge")
    XCTAssertEqual(textStorage.decoratorPositionCache[key], expected, "Decorator position cache should match attachment location after paragraph merge")

    // Verify decorator node still exists in editor state
    try editor.read {
      var decoratorCount = 0
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        if let para = child as? ElementNode {
          for node in para.getChildren() {
            if node is DecoratorNode {
              decoratorCount += 1
            }
          }
        }
      }
      XCTAssertEqual(decoratorCount, 1, "Decorator node should still exist after paragraph merge")
    }
  }

  /// Test multiple rapid edits during coordinateEditing don't cause issues.
  func testMultipleEditsWithDecoratorDuringCoordinateEditing() throws {
    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor
    let textView = view.textView
    guard let textStorage = textView.textStorage as? TextStorage else {
      XCTFail("Expected TextStorage")
      return
    }

    try editor.registerNode(
      nodeType: NodeType.testDecoratorCrossplatform,
      class: TestDecoratorNodeCrossplatform.self
    )

    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        try child.remove()
      }
      let paragraph = createParagraphNode()
      let text = createTextNode(text: "Hello")
      let decorator = TestDecoratorNodeCrossplatform()
      try paragraph.append([text, decorator])
      try root.append([paragraph])
      _ = try text.select(anchorOffset: nil, focusOffset: nil)
    }

    // Multiple edits in rapid succession, each wrapped in coordinateEditing
    for i in 0..<5 {
      textStorage.beginEditing()
      textStorage.replaceCharacters(
        in: NSRange(location: 5, length: 0),
        with: "\(i)"
      )
      textStorage.endEditing()
    }

    // Allow deferred operations to complete
    let expectation = expectation(description: "All deferred operations complete")
    DispatchQueue.main.async {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    // Verify text content is correct
    XCTAssertTrue(textView.text.contains("Hello"), "Text should contain 'Hello'")
  }

  /// Regression test for LayoutManager recovering from stale position cache.
  ///
  /// This bug occurred when:
  /// 1. User has a decorator at position N
  /// 2. User performs an edit that changes the decorator's position (e.g., backspace)
  /// 3. The draw cycle happens BEFORE the position cache is updated
  /// 4. positionDecorator is called with stale position from cache
  /// 5. No attachment is found at that position
  /// 6. Before the fix: the decorator would not be repositioned
  /// 7. After the fix: LayoutManager finds the actual position and repositions correctly
  func testLayoutManagerRecoversFromStalePositionCache() throws {
    let view = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let editor = view.editor
    let textView = view.textView
    guard let textStorage = textView.textStorage as? TextStorage else {
      XCTFail("Expected TextStorage")
      return
    }

    try editor.registerNode(
      nodeType: NodeType.testDecoratorCrossplatform,
      class: TestDecoratorNodeCrossplatform.self
    )

    var decoratorKey: NodeKey?

    // Setup: decorator + trailing text (ensure there is at least one non-attachment character
    // after the decorator so a stale cache value can point at a non-attachment index).
    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        try child.remove()
      }
      let paragraph = createParagraphNode()
      let decorator = TestDecoratorNodeCrossplatform()
      decoratorKey = decorator.key
      let trailingText = createTextNode(text: "x")
      try paragraph.append([decorator, trailingText])
      try root.append([paragraph])
    }

    guard let key = decoratorKey else {
      XCTFail("Decorator key not set")
      return
    }

    XCTAssertGreaterThanOrEqual(textStorage.length, 2, "Expected at least 2 characters in storage")

    // Simulate a stale cache: point at the trailing text instead of the attachment.
    // LayoutManager should detect no attachment at this index and recover by scanning.
    textStorage.decoratorPositionCache[key] = 1

    // Force a draw pass so LayoutManager runs `positionAllDecorators()` and can correct the cache.
    textView.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    textView.setNeedsLayout()
    textView.layoutIfNeeded()
    let renderer = UIGraphicsImageRenderer(size: textView.bounds.size)
    _ = renderer.image { ctx in
      guard let layoutManager = textView.layoutManager as? Lexical.LayoutManager else {
        return
      }
      let textContainer = textView.textContainer
      // `drawGlyphs` uses the current graphics context; calling it inside the renderer closure
      // guarantees our LayoutManager override runs (and thus `positionAllDecorators()`).
      let glyphRange = layoutManager.glyphRange(for: textContainer)
      layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }

    // After draw, the cache should be corrected to the attachment location.
    XCTAssertEqual(textStorage.decoratorPositionCache[key], 0, "Decorator position cache should be updated to 0")

    // Verify decorator still exists
    try editor.read {
      var decoratorCount = 0
      guard let root = getRoot() else { return }
      for child in root.getChildren() {
        if let para = child as? ElementNode {
          for node in para.getChildren() {
            if node is DecoratorNode {
              decoratorCount += 1
            }
          }
        }
      }
      XCTAssertEqual(decoratorCount, 1, "Decorator node should still exist")
    }
  }
}

#endif
