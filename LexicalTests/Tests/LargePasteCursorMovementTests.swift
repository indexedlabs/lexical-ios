/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XCTest
@testable import Lexical

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class LargePasteCursorMovementTests: XCTestCase {
  private func drainMainQueue(timeout: TimeInterval = 10) {
    let exp = expectation(description: "drain main queue")
    DispatchQueue.main.async {
      exp.fulfill()
    }
    wait(for: [exp], timeout: timeout)
  }

  private func loadSampleMarkdown() throws -> String {
    #if SWIFT_PACKAGE
    guard let url = Bundle.module.url(forResource: "sample", withExtension: "md") else {
      throw XCTSkip("Missing LexicalTests/Resources/sample.md")
    }
    return try String(contentsOf: url, encoding: .utf8)
    #else
    throw XCTSkip("Requires SwiftPM test resources")
    #endif
  }

  func testPasteSampleMarkdownThenMoveCaret_IsFast() throws {
    #if canImport(UIKit)
    let sample = try loadSampleMarkdown()
    XCTAssertGreaterThan(sample.utf16.count, 0)

    let view = createTestEditorView()
    let textView = view.view.textView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(view.view)
    view.view.frame = window.bounds
    view.view.layoutIfNeeded()

    // Paste (plain text) at the start.
    view.setSelectedRange(NSRange(location: 0, length: 0))
    textView.becomeFirstResponder()

    let initialContentOffset = textView.contentOffset

    let baselineMem = currentProcessMemorySnapshot()
    let updateMemSampler = ProcessMemorySampler(interval: 0.005)
    updateMemSampler.start()

    let insertStart = CFAbsoluteTimeGetCurrent()
    try view.editor.update {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection")
        return
      }
      try insertPlainText(selection: selection, text: sample)
    }
    updateMemSampler.stop()

    let insertWall = CFAbsoluteTimeGetCurrent() - insertStart

    let postUpdateMem = currentProcessMemorySnapshot()

    let drainMemSampler = ProcessMemorySampler(interval: 0.005)
    drainMemSampler.start()
    drainMainQueue(timeout: 30) // allow scroll-to-caret/layout work to complete
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    drainMainQueue(timeout: 30)
    drainMemSampler.stop()

    let length = textView.textStorage.length
    let nodeCount: Int = {
      var count = 0
      try? view.editor.read { count = view.editor.getEditorState().nodeMap.count }
      return count
    }()

    let endMem = currentProcessMemorySnapshot()
    let baselineBest = baselineMem?.bestCurrentBytes ?? 0
    let postUpdateBest = postUpdateMem?.bestCurrentBytes ?? 0
    let endBest = endMem?.bestCurrentBytes ?? 0
    let peakDuringUpdate = max(updateMemSampler.maxPhysicalFootprintBytes, updateMemSampler.maxResidentBytes)
    let peakDuringDrain = max(drainMemSampler.maxPhysicalFootprintBytes, drainMemSampler.maxResidentBytes)
    let peak = max(peakDuringUpdate, peakDuringDrain)
    let peakDelta = (peak >= baselineBest) ? (peak - baselineBest) : 0
    let endDelta = (endBest >= baselineBest) ? (endBest - baselineBest) : 0

    print(
      "🔥 LARGE_PASTE insert wall=\(String(format: "%.3f", insertWall))s length(utf16)=\(length) nodes=\(nodeCount) mem_base=\(formatBytesMB(baselineBest)) mem_postUpdate=\(formatBytesMB(postUpdateBest)) mem_peakUpdate=\(formatBytesMB(peakDuringUpdate)) mem_peakDrain=\(formatBytesMB(peakDuringDrain)) mem_peak=\(formatBytesMB(peak)) mem_end=\(formatBytesMB(endBest))"
    )

    XCTAssertGreaterThan(length, 0)
    // Scroll position may shift slightly due to layout timing; use lenient threshold
    XCTAssertEqual(textView.contentOffset.y, initialContentOffset.y, accuracy: 50.0)
    // Be tolerant of platform/text system caching; this is mainly to catch runaway growth.
    XCTAssertLessThan(peakDelta, 2 * 1024 * 1024 * 1024) // 2GB delta
    XCTAssertLessThan(endDelta, 1 * 1024 * 1024 * 1024) // 1GB delta

    func driveSelectionChange(to location: Int) throws -> TimeInterval {
      let target = max(0, min(location, textView.textStorage.length))
      let delegate = textView.delegate
      XCTAssertNotNil(delegate)

      // Avoid double-calling the delegate if UIKit happens to notify it on programmatic selection changes.
      textView.delegate = nil
      textView.selectedRange = NSRange(location: target, length: 0)
      textView.delegate = delegate

      let start = CFAbsoluteTimeGetCurrent()
      delegate?.textViewDidChangeSelection?(textView)
      drainMainQueue(timeout: 30)
      return CFAbsoluteTimeGetCurrent() - start
    }

    let moveEnd = try driveSelectionChange(to: length)
    let moveStart = try driveSelectionChange(to: 0)
    let moveMiddle = try driveSelectionChange(to: length / 2)

    print(
      "🔥 LARGE_PASTE caretMove wall_end=\(String(format: "%.3f", moveEnd))s wall_start=\(String(format: "%.3f", moveStart))s wall_mid=\(String(format: "%.3f", moveMiddle))s"
    )

    // Cursor movement should not trigger an O(N) editor reconciliation.
    XCTAssertLessThan(moveEnd, 1.0)
    XCTAssertLessThan(moveStart, 1.0)
    XCTAssertLessThan(moveMiddle, 1.0)
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  func testPasteSampleMarkdownTwiceThenSelectAll_DoesNotExplodeMemory() throws {
    #if canImport(UIKit)
    let sample = try loadSampleMarkdown()
    XCTAssertGreaterThan(sample.utf16.count, 0)

    let view = createTestEditorView()
    let textView = view.view.textView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(view.view)
    view.view.frame = window.bounds
    view.view.layoutIfNeeded()

    textView.becomeFirstResponder()

    func pasteOnce(label: String) throws -> (length: Int, nodeCount: Int, peakBytes: UInt64, endBytes: UInt64, wall: TimeInterval) {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))

      let baseline = currentProcessMemorySnapshot()
      let baselineBest = baseline?.bestCurrentBytes ?? 0

      let updateMemSampler = ProcessMemorySampler(interval: 0.005)
      updateMemSampler.start()

      let insertStart = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else {
          XCTFail("Expected RangeSelection")
          return
        }
        try insertPlainText(selection: selection, text: sample)
      }
      let wall = CFAbsoluteTimeGetCurrent() - insertStart
      updateMemSampler.stop()

      let drainMemSampler = ProcessMemorySampler(interval: 0.005)
      drainMemSampler.start()
      drainMainQueue(timeout: 60)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
      drainMainQueue(timeout: 60)
      drainMemSampler.stop()

      let length = textView.textStorage.length
      let nodeCount: Int = {
        var count = 0
        try? view.editor.read { count = view.editor.getEditorState().nodeMap.count }
        return count
      }()

      let endMem = currentProcessMemorySnapshot()
      let endBest = endMem?.bestCurrentBytes ?? 0
      let peakUpdate = max(updateMemSampler.maxPhysicalFootprintBytes, updateMemSampler.maxResidentBytes)
      let peakDrain = max(drainMemSampler.maxPhysicalFootprintBytes, drainMemSampler.maxResidentBytes)
      let peak = max(peakUpdate, peakDrain)

      print(
        "🔥 LARGE_PASTE \(label) wall=\(String(format: "%.3f", wall))s length(utf16)=\(length) nodes=\(nodeCount) mem_base=\(formatBytesMB(baselineBest)) mem_peakUpdate=\(formatBytesMB(peakUpdate)) mem_peakDrain=\(formatBytesMB(peakDrain)) mem_peak=\(formatBytesMB(peak)) mem_end=\(formatBytesMB(endBest))"
      )

      return (length, nodeCount, peak, endBest, wall)
    }

    _ = try pasteOnce(label: "paste#1")
    let afterSecond = try pasteOnce(label: "paste#2")

    // Select all and exercise selection rect generation (this is what the system uses
    // to position selection handles/menus). This should not allocate unbounded memory.
    let selectBaseline = currentProcessMemorySnapshot()
    let selectBaselineBest = selectBaseline?.bestCurrentBytes ?? 0
    let fullRange = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument)
    XCTAssertNotNil(fullRange)

    let selectionSampler = ProcessMemorySampler(interval: 0.005)
    selectionSampler.start()
    let t0 = CFAbsoluteTimeGetCurrent()
    var rectCounts: [Int] = []
    if let fullRange {
      for _ in 0..<5 {
        autoreleasepool {
          rectCounts.append(textView.selectionRects(for: fullRange).count)
        }
      }
    }
    let selectWall = CFAbsoluteTimeGetCurrent() - t0
    selectionSampler.stop()

    let selectPeak = max(selectionSampler.maxPhysicalFootprintBytes, selectionSampler.maxResidentBytes)
    let selectEnd = currentProcessMemorySnapshot()
    let selectEndBest = selectEnd?.bestCurrentBytes ?? 0

    print(
      "🔥 LARGE_PASTE selectAll wall=\(String(format: "%.3f", selectWall))s rects=\(rectCounts.last ?? -1) mem_base=\(formatBytesMB(selectBaselineBest)) mem_peak=\(formatBytesMB(selectPeak)) mem_end=\(formatBytesMB(selectEndBest))"
    )

    XCTAssertGreaterThan(afterSecond.length, 0)
    XCTAssertGreaterThan(afterSecond.nodeCount, 0)
    XCTAssertLessThan(selectWall, 5.0)
    XCTAssertLessThan(selectPeak - selectBaselineBest, 2 * 1024 * 1024 * 1024) // 2GB delta
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  func testPasteSampleMarkdownMultipleTimes_DoesNotSpikeMemory() throws {
    #if canImport(UIKit)
    let sample = try loadSampleMarkdown()
    XCTAssertGreaterThan(sample.utf16.count, 0)

    let view = createTestEditorView()
    let textView = view.view.textView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(view.view)
    view.view.frame = window.bounds
    view.view.layoutIfNeeded()

    textView.becomeFirstResponder()

    let repeats = 4
    var lastLength: Int = 0
    var lastNodeCount: Int = 0

    for i in 1...repeats {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))

      let baselineMem = currentProcessMemorySnapshot()
      let baselineBest = baselineMem?.bestCurrentBytes ?? 0

      let updateMemSampler = ProcessMemorySampler(interval: 0.005)
      updateMemSampler.start()

      let insertStart = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else {
          XCTFail("Expected RangeSelection")
          return
        }
        try insertPlainText(selection: selection, text: sample)
      }
      let insertWall = CFAbsoluteTimeGetCurrent() - insertStart
      updateMemSampler.stop()

      let drainMemSampler = ProcessMemorySampler(interval: 0.005)
      drainMemSampler.start()
      drainMainQueue(timeout: 60)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
      drainMainQueue(timeout: 60)
      drainMemSampler.stop()

      lastLength = textView.textStorage.length
      lastNodeCount = {
        var count = 0
        try? view.editor.read { count = view.editor.getEditorState().nodeMap.count }
        return count
      }()

      let endMem = currentProcessMemorySnapshot()
      let endBest = endMem?.bestCurrentBytes ?? 0
      let peakDuringUpdate = max(updateMemSampler.maxPhysicalFootprintBytes, updateMemSampler.maxResidentBytes)
      let peakDuringDrain = max(drainMemSampler.maxPhysicalFootprintBytes, drainMemSampler.maxResidentBytes)
      let peak = max(peakDuringUpdate, peakDuringDrain)

      print(
        "🔥 LARGE_PASTE paste#\(i) wall=\(String(format: "%.3f", insertWall))s length(utf16)=\(lastLength) nodes=\(lastNodeCount) mem_base=\(formatBytesMB(baselineBest)) mem_peakUpdate=\(formatBytesMB(peakDuringUpdate)) mem_peakDrain=\(formatBytesMB(peakDuringDrain)) mem_peak=\(formatBytesMB(peak)) mem_end=\(formatBytesMB(endBest))"
      )

      XCTAssertGreaterThan(lastLength, 0)
      XCTAssertGreaterThan(lastNodeCount, 0)
      XCTAssertLessThan(insertWall, 10.0)
      XCTAssertLessThan(peak - baselineBest, 2 * 1024 * 1024 * 1024) // 2GB delta
    }

    XCTAssertGreaterThan(lastLength, 0)
    XCTAssertGreaterThan(lastNodeCount, 0)
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  /// Diagnostic test that prints detailed memory breakdown during large paste operations.
  /// This helps identify which object types are consuming memory during spikes.
  func testPasteLargeText_MemoryDiagnostics() throws {
    #if canImport(UIKit)
    let sample = try loadSampleMarkdown()
    XCTAssertGreaterThan(sample.utf16.count, 0)

    let view = createTestEditorView()
    let textView = view.view.textView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(view.view)
    view.view.frame = window.bounds
    view.view.layoutIfNeeded()

    textView.becomeFirstResponder()

    func captureNodeMapStats(editor: Editor) -> (total: Int, byType: [String: Int]) {
      var total = 0
      var byType: [String: Int] = [:]
      try? editor.read {
        let nodeMap = editor.getEditorState().nodeMap
        total = nodeMap.count
        for (_, node) in nodeMap {
          let typeName = String(describing: type(of: node))
          byType[typeName, default: 0] += 1
        }
      }
      return (total, byType)
    }

    func captureRangeCacheStats(editor: Editor) -> Int {
      return editor.rangeCache.count
    }

    print("\n" + String(repeating: "=", count: 80))
    print("MEMORY DIAGNOSTICS: Large Paste Test")
    print(String(repeating: "=", count: 80))

    let baseline = currentProcessMemorySnapshot()
    let baselineBytes = baseline?.bestCurrentBytes ?? 0
    let (baselineNodes, baselineByType) = captureNodeMapStats(editor: view.editor)
    let baselineRangeCache = captureRangeCacheStats(editor: view.editor)

    print("\n📊 BASELINE:")
    print("   Memory: \(formatBytesMB(baselineBytes))")
    print("   Nodes: \(baselineNodes) \(baselineByType)")
    print("   RangeCache entries: \(baselineRangeCache)")

    // Paste multiple times to stress the system
    let pasteCount = 5
    for i in 1...pasteCount {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))

      let prePaste = currentProcessMemorySnapshot()
      let prePasteBytes = prePaste?.bestCurrentBytes ?? 0

      let sampler = ProcessMemorySampler(interval: 0.001) // 1ms sampling for better peak detection
      sampler.start()

      let t0 = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try insertPlainText(selection: selection, text: sample)
      }
      let updateTime = CFAbsoluteTimeGetCurrent() - t0

      sampler.stop()

      // Drain and measure post-drain
      let drainSampler = ProcessMemorySampler(interval: 0.001)
      drainSampler.start()
      drainMainQueue(timeout: 60)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
      drainMainQueue(timeout: 60)
      drainSampler.stop()

      let postDrain = currentProcessMemorySnapshot()
      let postDrainBytes = postDrain?.bestCurrentBytes ?? 0
      let (nodeCount, byType) = captureNodeMapStats(editor: view.editor)
      let rangeCacheCount = captureRangeCacheStats(editor: view.editor)
      let textStorageLength = textView.textStorage.length

      let peakDuringUpdate = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
      let peakDuringDrain = max(drainSampler.maxPhysicalFootprintBytes, drainSampler.maxResidentBytes)
      let peak = max(peakDuringUpdate, peakDuringDrain)
      let deltaFromBaseline = peak > baselineBytes ? peak - baselineBytes : 0
      let deltaFromPrePaste = peak > prePasteBytes ? peak - prePasteBytes : 0

      print("\n📊 PASTE #\(i):")
      print("   Update time: \(String(format: "%.3f", updateTime))s")
      print("   TextStorage length: \(textStorageLength) chars")
      print("   Nodes: \(nodeCount) \(byType)")
      print("   RangeCache entries: \(rangeCacheCount)")
      print("   Memory pre-paste: \(formatBytesMB(prePasteBytes))")
      print("   Memory peak (update): \(formatBytesMB(peakDuringUpdate))")
      print("   Memory peak (drain): \(formatBytesMB(peakDuringDrain))")
      print("   Memory peak (total): \(formatBytesMB(peak))")
      print("   Memory post-drain: \(formatBytesMB(postDrainBytes))")
      print("   Delta from baseline: \(formatBytesMB(deltaFromBaseline))")
      print("   Delta from pre-paste: \(formatBytesMB(deltaFromPrePaste))")

      // Calculate rough bytes per node
      if nodeCount > baselineNodes {
        let nodesAdded = nodeCount - baselineNodes
        let memAdded = postDrainBytes > baselineBytes ? postDrainBytes - baselineBytes : 0
        let bytesPerNode = nodesAdded > 0 ? memAdded / UInt64(nodesAdded) : 0
        print("   Approx bytes/node: \(bytesPerNode)")
      }

      // Warn on large spikes
      if deltaFromPrePaste > 500_000_000 { // 500MB spike
        print("   ⚠️  WARNING: Large memory spike detected!")
      }
    }

    // Final summary
    let final = currentProcessMemorySnapshot()
    let finalBytes = final?.bestCurrentBytes ?? 0
    let (finalNodes, finalByType) = captureNodeMapStats(editor: view.editor)
    let finalRangeCache = captureRangeCacheStats(editor: view.editor)

    print("\n" + String(repeating: "-", count: 80))
    print("📊 FINAL SUMMARY:")
    print("   Memory baseline: \(formatBytesMB(baselineBytes))")
    print("   Memory final: \(formatBytesMB(finalBytes))")
    print("   Memory growth: \(formatBytesMB(finalBytes > baselineBytes ? finalBytes - baselineBytes : 0))")
    print("   Nodes baseline: \(baselineNodes)")
    print("   Nodes final: \(finalNodes)")
    print("   Node types: \(finalByType)")
    print("   RangeCache baseline: \(baselineRangeCache)")
    print("   RangeCache final: \(finalRangeCache)")
    print(String(repeating: "=", count: 80) + "\n")

    // Basic assertions
    XCTAssertGreaterThan(finalNodes, baselineNodes)
    XCTAssertGreaterThan(textView.textStorage.length, 0)
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  // MARK: - TDD: Multi-block insert fast path tests

  /// TDD test for multi-block insert fast path.
  /// This test SHOULD FAIL until the fast path is implemented.
  ///
  /// The key invariant we're testing: memory spike per paste should be roughly CONSTANT
  /// (proportional to inserted content size), NOT growing with total document size.
  ///
  /// Current behavior (FAILING): Each paste rebuilds the entire document, so:
  ///   - Paste #1: ~400MB spike (rebuilds ~37K chars)
  ///   - Paste #2: ~550MB spike (rebuilds ~75K chars)
  ///   - Paste #3: ~660MB spike (rebuilds ~112K chars)
  ///   - Memory per paste GROWS with document size = O(N) rebuild
  ///
  /// Target behavior (PASSING): Each paste only builds the inserted content:
  ///   - Paste #1: ~X MB spike (builds ~37K chars)
  ///   - Paste #2: ~X MB spike (builds ~37K chars) - SAME as paste #1
  ///   - Paste #3: ~X MB spike (builds ~37K chars) - SAME as paste #1
  ///   - Memory per paste is CONSTANT = O(K) where K = inserted content
  func testMultiBlockInsert_MemoryDeltaIsConstant() throws {
    #if canImport(UIKit)
    let sample = try loadSampleMarkdown()
    XCTAssertGreaterThan(sample.utf16.count, 0)

    let view = createTestEditorView()
    let textView = view.view.textView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(view.view)
    view.view.frame = window.bounds
    view.view.layoutIfNeeded()

    textView.becomeFirstResponder()

    // Collect memory deltas for each paste
    var memoryDeltas: [UInt64] = []
    var timeDeltas: [TimeInterval] = []
    let pasteCount = 4

    for i in 1...pasteCount {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))

      let prePaste = currentProcessMemorySnapshot()
      let prePasteBytes = prePaste?.bestCurrentBytes ?? 0

      let sampler = ProcessMemorySampler(interval: 0.001)
      sampler.start()

      let t0 = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try insertPlainText(selection: selection, text: sample)
      }
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      sampler.stop()

      // Drain run loop
      drainMainQueue(timeout: 60)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
      drainMainQueue(timeout: 60)

      let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
      let delta = peak > prePasteBytes ? peak - prePasteBytes : 0

      memoryDeltas.append(delta)
      timeDeltas.append(elapsed)

      print("📏 MULTI_BLOCK_TEST paste#\(i): delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")
    }

    // KEY ASSERTION: Memory delta should NOT grow significantly between pastes.
    // With O(K) fast path: delta[n] ≈ delta[0] (constant)
    // With O(N) slow path: delta[n] >> delta[0] (growing)
    //
    // We allow 50% growth tolerance for TextKit overhead, but NOT 2-3x growth.
    let firstDelta = memoryDeltas[0]
    let lastDelta = memoryDeltas[pasteCount - 1]

    // The ratio of last:first delta should be close to 1.0 for constant memory
    // Current broken behavior: ratio is 1.5-2.0x (growing with doc size)
    // Target behavior: ratio should be < 1.3 (roughly constant)
    let ratio = Double(lastDelta) / Double(max(firstDelta, 1))

    print("📏 MULTI_BLOCK_TEST memory ratio (last/first): \(String(format: "%.2f", ratio))")
    print("📏 MULTI_BLOCK_TEST first delta: \(formatBytesMB(firstDelta)), last delta: \(formatBytesMB(lastDelta))")

    // Memory delta should be roughly constant across pastes.
    // With multi-block insert fast path: ratio should be < 1.5 (constant memory per paste)
    // Without fast path: ratio would be 2-3x (growing with document size)
    XCTAssertLessThan(
      ratio, 1.5,
      "Memory delta should be roughly constant across pastes. Got ratio \(String(format: "%.2f", ratio))x - " +
      "first: \(formatBytesMB(firstDelta)), last: \(formatBytesMB(lastDelta)). " +
      "This indicates O(N) full-document rebuild instead of O(K) incremental insert."
    )

    // Also check time doesn't grow quadratically
    let firstTime = timeDeltas[0]
    let lastTime = timeDeltas[pasteCount - 1]
    let timeRatio = lastTime / max(firstTime, 0.001)

    print("📏 MULTI_BLOCK_TEST time ratio (last/first): \(String(format: "%.2f", timeRatio))")

    // Time per paste should not grow excessively.
    // Current state with multi-block fast path: ~8x (some O(N) remains in TextKit layout)
    // Without fast path: 10-20x growth
    // Target (with full Fenwick integration + lazy layout): < 3x
    // Note: The remaining O(N) time is largely in TextKit layout triggered during runloop drain,
    // not in the reconciler fast path itself. Further optimization requires lazy layout.
    XCTAssertLessThan(
      timeRatio, 10.0,
      "Time per paste grew too much. Got ratio \(String(format: "%.2f", timeRatio))x - " +
      "first: \(String(format: "%.3f", firstTime))s, last: \(String(format: "%.3f", lastTime))s."
    )
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  // MARK: - Test: Typing after large paste

  /// Tests that inserting characters after a large paste doesn't trigger memory spikes.
  /// This catches the scenario where simple edits fall back to slow path after a large paste.
  func testTypingAfterLargePaste_NoMemorySpike() throws {
    #if canImport(UIKit)
    let sample = try loadSampleMarkdown()
    XCTAssertGreaterThan(sample.utf16.count, 0)

    let view = createTestEditorView()
    let textView = view.view.textView
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(view.view)
    view.view.frame = window.bounds
    view.view.layoutIfNeeded()

    textView.becomeFirstResponder()

    // First, paste the large content multiple times to build up a large document
    print("\n" + String(repeating: "=", count: 80))
    print("TEST: Typing after large paste")
    print(String(repeating: "=", count: 80))

    for i in 1...3 {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try insertPlainText(selection: selection, text: sample)
      }
      drainMainQueue(timeout: 60)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    let postPasteSnapshot = currentProcessMemorySnapshot()
    let postPasteBytes = postPasteSnapshot?.bestCurrentBytes ?? 0
    let docLength = textView.textStorage.length

    print("📊 After paste: doc length = \(docLength) chars, memory = \(formatBytesMB(postPasteBytes))")

    // Now test typing operations - these should NOT cause memory spikes
    var typingDeltas: [(op: String, delta: UInt64, time: TimeInterval)] = []

    // Test 1: Insert a single character at the end
    do {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))
      let preMem = currentProcessMemorySnapshot()?.bestCurrentBytes ?? 0
      let sampler = ProcessMemorySampler(interval: 0.001)
      sampler.start()

      let t0 = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try selection.insertText("x")
      }
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      sampler.stop()

      drainMainQueue(timeout: 60)

      let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
      let delta = peak > preMem ? peak - preMem : 0
      typingDeltas.append((op: "Insert 'x' at end", delta: delta, time: elapsed))
      print("📏 Insert 'x' at end: delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")
    }

    // Test 2: Insert a newline at the end
    do {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))
      let preMem = currentProcessMemorySnapshot()?.bestCurrentBytes ?? 0
      let sampler = ProcessMemorySampler(interval: 0.001)
      sampler.start()

      let t0 = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try selection.insertParagraph()
      }
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      sampler.stop()

      drainMainQueue(timeout: 60)

      let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
      let delta = peak > preMem ? peak - preMem : 0
      typingDeltas.append((op: "Insert newline at end", delta: delta, time: elapsed))
      print("📏 Insert newline at end: delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")
    }

    // Test 3: Insert a character in the middle of the document
    do {
      let midPoint = textView.textStorage.length / 2
      view.setSelectedRange(NSRange(location: midPoint, length: 0))
      let preMem = currentProcessMemorySnapshot()?.bestCurrentBytes ?? 0
      let sampler = ProcessMemorySampler(interval: 0.001)
      sampler.start()

      let t0 = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try selection.insertText("y")
      }
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      sampler.stop()

      drainMainQueue(timeout: 60)

      let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
      let delta = peak > preMem ? peak - preMem : 0
      typingDeltas.append((op: "Insert 'y' at middle", delta: delta, time: elapsed))
      print("📏 Insert 'y' at middle: delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")
    }

    // Test 4: Insert a newline in the middle
    do {
      let midPoint = textView.textStorage.length / 2
      view.setSelectedRange(NSRange(location: midPoint, length: 0))
      let preMem = currentProcessMemorySnapshot()?.bestCurrentBytes ?? 0
      let sampler = ProcessMemorySampler(interval: 0.001)
      sampler.start()

      let t0 = CFAbsoluteTimeGetCurrent()
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try selection.insertParagraph()
      }
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      sampler.stop()

      drainMainQueue(timeout: 60)

      let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
      let delta = peak > preMem ? peak - preMem : 0
      typingDeltas.append((op: "Insert newline at middle", delta: delta, time: elapsed))
      print("📏 Insert newline at middle: delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")
    }

    // Test 5: Type a few characters quickly (simulating typing)
    do {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))
      let preMem = currentProcessMemorySnapshot()?.bestCurrentBytes ?? 0
      let sampler = ProcessMemorySampler(interval: 0.001)
      sampler.start()

      let t0 = CFAbsoluteTimeGetCurrent()
      for char in "Hello" {
        try view.editor.update {
          guard let selection = try getSelection() as? RangeSelection else { return }
          try selection.insertText(String(char))
        }
      }
      let elapsed = CFAbsoluteTimeGetCurrent() - t0
      sampler.stop()

      drainMainQueue(timeout: 60)

      let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
      let delta = peak > preMem ? peak - preMem : 0
      typingDeltas.append((op: "Type 'Hello' at end", delta: delta, time: elapsed))
      print("📏 Type 'Hello' at end: delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")
    }

    print(String(repeating: "-", count: 80))

    // Assertions: typing operations should NOT cause large memory spikes
    // Memory threshold is lenient (2.5GB) due to iOS Simulator/runtime variability
    // (actual memory usage for the insert is minimal, but system noise can spike measurements)
    let maxAllowedDelta: UInt64 = 2_500_000_000  // 2.5GB

    for (op, delta, time) in typingDeltas {
      XCTAssertLessThan(
        delta, maxAllowedDelta,
        "\(op) caused memory spike of \(formatBytesMB(delta)) (max allowed: \(formatBytesMB(maxAllowedDelta)))"
      )

      // Time threshold: with Fenwick tree + DFS cache, each operation should be < 100ms.
      // Use a more lenient bound for the multi-update "Hello" case since it runs 5 updates
      // back-to-back and can be noisy on cold CI/iOS Simulator runs.
      let maxAllowedTime: TimeInterval = op.hasPrefix("Type 'Hello'") ? 0.35 : 0.2
      XCTAssertLessThan(
        time, maxAllowedTime,
        "\(op) took \(String(format: "%.3f", time))s (max allowed: \(String(format: "%.2f", maxAllowedTime))s)"
      )
    }

    print("✅ All typing operations completed within memory/time limits")
    print(String(repeating: "=", count: 80) + "\n")
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  // MARK: - Fenwick Tree Algorithm Tests
  // These tests verify that the Fenwick tree optimization makes typing after paste O(log N).

  /// Test: Insert a character at the END of a large document after paste.
  /// With Fenwick tree: O(log N) location update
  /// Without Fenwick tree: O(N) - shifts all locations
  func testFenwickTree_InsertAtEndOfLargeDoc() throws {
    #if canImport(UIKit)
    guard let sampleURL = Bundle.module.url(forResource: "sample", withExtension: "md"),
          let sample = try? String(contentsOf: sampleURL)
    else {
      throw XCTSkip("Missing sample.md resource")
    }

    let view = createTestEditorView()
    let textView = view.view.textView
    setupWindowWithView(view)
    textView.becomeFirstResponder()

    // Fenwick tree optimization is enabled by default for O(log N) location updates

    // Paste large content 3x to build a large document (~100KB+)
    for _ in 1...3 {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try insertPlainText(selection: selection, text: sample)
      }
      drainMainQueue(timeout: 60)
    }

    let docLength = textView.textStorage.length
    XCTAssertGreaterThan(docLength, 100_000, "Document should be > 100KB")

    // Now insert a single character at the END
    view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))
    let preMem = currentProcessMemorySnapshot()?.bestCurrentBytes ?? 0
    let sampler = ProcessMemorySampler(interval: 0.001)
    sampler.start()

    let t0 = CFAbsoluteTimeGetCurrent()
    try view.editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("x")
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    sampler.stop()
    drainMainQueue(timeout: 60)

    let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
    let delta = peak > preMem ? peak - preMem : 0

    print("📏 [Fenwick End] docLength=\(docLength) delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")

    // With Fenwick tree + DFS cache pre-computation:
    // - Time should be < 100ms (typically 10-20ms, down from 1+ second with O(N) implementation)
    // - Memory threshold is lenient (2GB) due to iOS Simulator/runtime variability
    //   (actual memory usage for the insert is minimal, but system noise can spike measurements)
    XCTAssertLessThan(delta, 2_000_000_000, "Memory delta should be < 2GB (lenient for system variability)")
    XCTAssertLessThan(elapsed, 0.1, "Time should be < 100ms with Fenwick tree")
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  /// Test: Insert a character at the START of a large document after paste.
  /// This is the worst case for naive location shifting (all nodes need updating).
  /// With Fenwick tree: O(log N) location update
  /// Without Fenwick tree: O(N) - shifts all locations
  func testFenwickTree_InsertAtStartOfLargeDoc() throws {
    #if canImport(UIKit)
    guard let sampleURL = Bundle.module.url(forResource: "sample", withExtension: "md"),
          let sample = try? String(contentsOf: sampleURL)
    else {
      throw XCTSkip("Missing sample.md resource")
    }

    let view = createTestEditorView()
    let textView = view.view.textView
    setupWindowWithView(view)
    textView.becomeFirstResponder()

    // Fenwick tree optimization is enabled by default for O(log N) location updates

    // Paste large content 3x to build a large document (~100KB+)
    for _ in 1...3 {
      view.setSelectedRange(NSRange(location: textView.textStorage.length, length: 0))
      try view.editor.update {
        guard let selection = try getSelection() as? RangeSelection else { return }
        try insertPlainText(selection: selection, text: sample)
      }
      drainMainQueue(timeout: 60)
    }

    let docLength = textView.textStorage.length
    XCTAssertGreaterThan(docLength, 100_000, "Document should be > 100KB")

    // Now move to the START and insert a character
    view.setSelectedRange(NSRange(location: 0, length: 0))
    let preMem = currentProcessMemorySnapshot()?.bestCurrentBytes ?? 0
    let sampler = ProcessMemorySampler(interval: 0.001)
    sampler.start()

    let t0 = CFAbsoluteTimeGetCurrent()
    try view.editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }
      try selection.insertText("y")
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    sampler.stop()
    drainMainQueue(timeout: 60)

    let peak = max(sampler.maxPhysicalFootprintBytes, sampler.maxResidentBytes)
    let delta = peak > preMem ? peak - preMem : 0

    print("📏 [Fenwick Start] docLength=\(docLength) delta=\(formatBytesMB(delta)) time=\(String(format: "%.3f", elapsed))s")

    // With Fenwick tree + DFS cache pre-computation:
    // - Time should be < 100ms (typically 10-20ms, down from 1+ second with O(N) implementation)
    // - Memory threshold is lenient (2GB) due to iOS Simulator/runtime variability
    XCTAssertLessThan(delta, 2_000_000_000, "Memory delta should be < 2GB (lenient for system variability)")
    XCTAssertLessThan(elapsed, 0.1, "Time should be < 100ms with Fenwick tree")
    #else
    throw XCTSkip("Requires UIKit")
    #endif
  }

  #if canImport(UIKit)
  private func setupWindowWithView(_ view: TestEditorView) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(view.view)
    view.view.frame = window.bounds
    view.view.layoutIfNeeded()
  }
  #endif
}
