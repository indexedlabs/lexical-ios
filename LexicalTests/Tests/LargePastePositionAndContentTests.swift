/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XCTest
@testable import Lexical

/// Tests for verifying correctness of cursor position and content after pasting large ranges.
/// These tests focus on correctness rather than performance - ensuring the position moves
/// correctly after each paste and the resulting content matches expectations.
@MainActor
final class LargePastePositionAndContentTests: XCTestCase {

  // MARK: - Test Configuration

  /// Number of lines to generate for large paste tests.
  /// Using 2000+ lines to exercise large document handling.
  private let lineCount = 2000

  /// Generates deterministic test content with the specified number of lines.
  private func generateLargeContent(lines: Int) -> String {
    (0..<lines).map { "Line \($0): The quick brown fox jumps over the lazy dog." }.joined(separator: "\n")
  }

  // MARK: - Task lexical-ios-ejz: Paste 3x consecutively

  /// Tests that pasting large content (thousands of lines) 3 times consecutively:
  /// 1. Correctly moves cursor position after each paste (to end of pasted content)
  /// 2. Results in expected final content (3x the original content)
  func testPasteLargeContent3xConsecutively_PositionAndContentCorrect() throws {
    let testView = createTestEditorView()
    let largeContent = generateLargeContent(lines: lineCount)
    let contentLength = largeContent.utf16.count

    // Track positions and lengths after each paste
    var positionsAfterPaste: [Int] = []
    var lengthsAfterPaste: [Int] = []

    // Paste 3 times consecutively
    for pasteNum in 1...3 {
      // Set selection to end of document before each paste
      let currentLength = testView.textStorageLength
      testView.setSelectedRange(NSRange(location: currentLength, length: 0))

      // Perform the paste
      try testView.editor.update {
        guard let selection = try getSelection() as? RangeSelection else {
          XCTFail("Expected RangeSelection for paste #\(pasteNum)")
          return
        }
        try insertPlainText(selection: selection, text: largeContent)
      }

      // Record position and length after paste
      let positionAfter = testView.selectedRange.location
      let lengthAfter = testView.textStorageLength

      positionsAfterPaste.append(positionAfter)
      lengthsAfterPaste.append(lengthAfter)

      // Verify selection is collapsed (no range selected)
      XCTAssertEqual(
        testView.selectedRange.length, 0,
        "Paste #\(pasteNum): Selection should be collapsed after paste"
      )
    }

    // Verify positions after each paste
    // After paste 1: position should be near end (approximately contentLength)
    // After paste 2: position should be near end (approximately 2*contentLength)
    // After paste 3: position should be near end (approximately 3*contentLength)
    let expectedLengths = [contentLength, contentLength * 2, contentLength * 3]

    for (i, (position, length)) in zip(positionsAfterPaste, lengthsAfterPaste).enumerated() {
      let pasteNum = i + 1
      let expectedLength = expectedLengths[i]

      // Length should match expected (accounting for potential newline variations)
      // Allow small tolerance for paragraph boundary handling
      assertEqualWithTolerance(
        length, expectedLength,
        tolerance: 10,
        "Paste #\(pasteNum): Length should be ~\(expectedLength), got \(length)"
      )

      // Position should be at or near the end of the document
      // Allow tolerance for paragraph/newline handling at boundaries
      XCTAssertLessThanOrEqual(
        abs(position - length), 128,
        "Paste #\(pasteNum): Position (\(position)) should be near end of document (\(length))"
      )
    }

    // Verify final content
    var finalContent = ""
    try testView.editor.read {
      finalContent = getRoot()?.getTextContent() ?? ""
    }

    // Content should be the large content repeated 3 times
    // Each paste appends to the end, so we expect: content + content + content
    let expectedContent = largeContent + largeContent + largeContent

    XCTAssertEqual(
      finalContent, expectedContent,
      "Final content should be the large content pasted 3 times consecutively"
    )

    // Also verify we have the expected number of "Line 0:" occurrences (should be 3)
    let line0Count = finalContent.components(separatedBy: "Line 0:").count - 1
    XCTAssertEqual(line0Count, 3, "Should have 3 occurrences of 'Line 0:' (one per paste)")

    // And the expected number of last lines
    let lastLineMarker = "Line \(lineCount - 1):"
    let lastLineCount = finalContent.components(separatedBy: lastLineMarker).count - 1
    XCTAssertEqual(lastLineCount, 3, "Should have 3 occurrences of last line marker")
  }

  // MARK: - Task lexical-ios-g6h: Paste with newline between each

  /// Tests that pasting large content with newlines inserted between pastes:
  /// 1. Correctly moves cursor position after each paste and newline
  /// 2. Results in expected final content (paste, newline, paste, newline, paste)
  func testPasteLargeContentWithNewlinesBetween_PositionAndContentCorrect() throws {
    let testView = createTestEditorView()
    let largeContent = generateLargeContent(lines: lineCount)

    // Track positions after each operation
    var positionsAfterPaste: [Int] = []
    var positionsAfterNewline: [Int] = []

    // Paste 3 times with newline after each (except the last)
    for pasteNum in 1...3 {
      // Set selection to end of document before each paste
      let currentLength = testView.textStorageLength
      testView.setSelectedRange(NSRange(location: currentLength, length: 0))

      // Perform the paste
      try testView.editor.update {
        guard let selection = try getSelection() as? RangeSelection else {
          XCTFail("Expected RangeSelection for paste #\(pasteNum)")
          return
        }
        try insertPlainText(selection: selection, text: largeContent)
      }

      // Record position after paste
      positionsAfterPaste.append(testView.selectedRange.location)

      // Verify selection is collapsed
      XCTAssertEqual(
        testView.selectedRange.length, 0,
        "Paste #\(pasteNum): Selection should be collapsed after paste"
      )

      // Insert newline after paste (except after the last paste)
      if pasteNum < 3 {
        try testView.editor.update {
          guard let selection = try getSelection() as? RangeSelection else {
            XCTFail("Expected RangeSelection for newline after paste #\(pasteNum)")
            return
          }
          try selection.insertParagraph()
        }

        // Record position after newline
        positionsAfterNewline.append(testView.selectedRange.location)

        // Verify selection is still collapsed
        XCTAssertEqual(
          testView.selectedRange.length, 0,
          "After newline #\(pasteNum): Selection should be collapsed"
        )
      }
    }

    // Verify paste positions are monotonically increasing
    // (Newline positions may not always increase due to how paragraph insertion works)
    for i in 1..<positionsAfterPaste.count {
      XCTAssertGreaterThan(
        positionsAfterPaste[i], positionsAfterPaste[i - 1],
        "Paste position should increase: paste#\(i)=\(positionsAfterPaste[i - 1]) → paste#\(i + 1)=\(positionsAfterPaste[i])"
      )
    }

    // Verify newline positions are after corresponding paste positions
    for i in 0..<positionsAfterNewline.count {
      XCTAssertGreaterThanOrEqual(
        positionsAfterNewline[i], positionsAfterPaste[i],
        "Newline position should be >= paste position: paste#\(i + 1)=\(positionsAfterPaste[i]) vs newline#\(i + 1)=\(positionsAfterNewline[i])"
      )
    }

    // Verify final position is at or near end
    let finalLength = testView.textStorageLength
    let finalPosition = testView.selectedRange.location
    XCTAssertLessThanOrEqual(
      abs(finalPosition - finalLength), 128,
      "Final position (\(finalPosition)) should be near end of document (\(finalLength))"
    )

    // Verify final content structure
    var finalContent = ""
    try testView.editor.read {
      finalContent = getRoot()?.getTextContent() ?? ""
    }

    // Content should be: largeContent + newline + largeContent + newline + largeContent
    // Note: insertParagraph creates a new paragraph, which may result in \n or platform-specific line ending

    // Split by the first line marker to count occurrences
    let line0Count = finalContent.components(separatedBy: "Line 0:").count - 1
    XCTAssertEqual(line0Count, 3, "Should have 3 occurrences of 'Line 0:' (one per paste)")

    // Verify the content contains all three paste blocks
    // Each paste block ends with the last line
    let lastLineMarker = "Line \(lineCount - 1):"
    let lastLineCount = finalContent.components(separatedBy: lastLineMarker).count - 1
    XCTAssertEqual(lastLineCount, 3, "Should have 3 occurrences of last line marker")

    // Verify there are paragraph breaks between the paste blocks
    // After inserting paragraphs, we should have more paragraph nodes
    var paragraphCount = 0
    try testView.editor.read {
      guard let root = getRoot() else { return }
      paragraphCount = root.getChildren().count
    }

    // With 2000 lines per paste × 3 pastes + 2 extra paragraph breaks = ~6002 paragraphs
    // (Each line becomes a paragraph, plus the inserted paragraph breaks)
    let expectedMinParagraphs = lineCount * 3
    XCTAssertGreaterThanOrEqual(
      paragraphCount, expectedMinParagraphs,
      "Should have at least \(expectedMinParagraphs) paragraphs"
    )

    // Verify the structure: after first paste block, there should be content from second paste
    // Find where first paste ends (Line 1999) and verify next content starts fresh
    if let firstLastLineRange = finalContent.range(of: lastLineMarker) {
      let afterFirstPaste = finalContent[firstLastLineRange.upperBound...]
      // After the first paste's last line, eventually we should see "Line 0:" again from second paste
      XCTAssertTrue(
        afterFirstPaste.contains("Line 0:"),
        "After first paste block, should find 'Line 0:' from second paste"
      )
    }
  }

  // MARK: - Memory profiling: Paste + Select All

  /// Test for memory profiling: paste 2k lines then select all.
  /// Run with: swift test --filter testPaste2kLines_ThenSelectAll
  func testPaste2kLines_ThenSelectAll() throws {
    let testView = createTestEditorView()
    let largeContent = generateLargeContent(lines: lineCount)

    // Paste 2k lines
    try testView.editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try insertPlainText(selection: selection, text: largeContent)
    }

    // Now select all - this is where memory spikes
    let totalLength = testView.textStorageLength
    testView.setSelectedRange(NSRange(location: 0, length: totalLength))

    // Verify selection covers entire document
    let selectedRange = testView.selectedRange
    XCTAssertEqual(selectedRange.location, 0, "Selection should start at 0")
    XCTAssertEqual(selectedRange.length, totalLength, "Selection should cover entire document")
  }

  /// Test for memory profiling: paste 2k lines 3x then select all.
  /// This is the scenario that spikes memory to 50GB.
  /// Run with: swift test --filter testPaste2kLines3x_ThenSelectAll
  func testPaste2kLines3x_ThenSelectAll() throws {
    let testView = createTestEditorView()
    let largeContent = generateLargeContent(lines: lineCount)

    // Paste 2k lines 3 times
    for i in 1...3 {
      let currentLength = testView.textStorageLength
      testView.setSelectedRange(NSRange(location: currentLength, length: 0))

      try testView.editor.update {
        guard let selection = try getSelection() as? RangeSelection else {
          XCTFail("Expected RangeSelection")
          return
        }
        try insertPlainText(selection: selection, text: largeContent)
      }
      print("[Memory Test] After paste \(i): \(testView.textStorageLength) chars")
    }

    print("[Memory Test] Before select all: \(testView.textStorageLength) chars, ~\(testView.textStorageLength / 1000)k")

    // Now select all - this is where memory spikes
    let totalLength = testView.textStorageLength
    testView.setSelectedRange(NSRange(location: 0, length: totalLength))

    print("[Memory Test] After select all")

    // Verify selection covers entire document
    let selectedRange = testView.selectedRange
    XCTAssertEqual(selectedRange.location, 0, "Selection should start at 0")
    XCTAssertEqual(selectedRange.length, totalLength, "Selection should cover entire document")
  }

  /// Test to investigate getNodes() behavior with large selection.
  /// Run with: swift test --filter testSelectAllThenGetNodes
  func testSelectAllThenGetNodes() throws {
    let testView = createTestEditorView()
    let largeContent = generateLargeContent(lines: lineCount)

    // Paste once
    try testView.editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try insertPlainText(selection: selection, text: largeContent)
    }

    print("[Memory Test] After paste: \(testView.textStorageLength) chars")

    // Now select all via native range
    let totalLength = testView.textStorageLength
    testView.setSelectedRange(NSRange(location: 0, length: totalLength))

    print("[Memory Test] After select all via native")

    // Now call getNodes() on the selection - this might be the expensive operation
    var nodeCount = 0
    try testView.editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      let t0 = CFAbsoluteTimeGetCurrent()
      let nodes = try selection.getNodes()
      let t1 = CFAbsoluteTimeGetCurrent()
      nodeCount = nodes.count
      print("[Memory Test] getNodes() returned \(nodeCount) nodes in \(String(format: "%.3f", t1 - t0))s")
    }

    XCTAssertGreaterThan(nodeCount, 0, "Should have nodes in selection")
  }

  // MARK: - Helper for asserting Int equality with tolerance

  private func assertEqualWithTolerance(_ a: Int, _ b: Int, tolerance: Int, _ message: String, file: StaticString = #file, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), tolerance, message, file: file, line: line)
  }
}
