import XCTest
@testable import Lexical

@MainActor
final class FenwickLocationDeltaTests: XCTestCase {

  private func drainMainQueue(timeout: TimeInterval = 2, cycles: Int = 3) {
    precondition(cycles > 0)
    for _ in 0..<cycles {
      let exp = expectation(description: "drain main queue")
      DispatchQueue.main.async { exp.fulfill() }
      wait(for: [exp], timeout: timeout)
    }
  }

  func testFenwickDeltaShiftsFirstAffectedNode() throws {
    let view = createTestEditorView()
    let editor = view.editor

    var t1Key: NodeKey = ""
    var p2Key: NodeKey = ""
    var t2Key: NodeKey = ""

    try editor.update {
      guard let root = getRoot() else { return }
      _ = try root.clear()

      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "A")
      t1Key = t1.getKey()
      try p1.append([t1])

      let p2 = createParagraphNode()
      p2Key = p2.getKey()
      let t2 = createTextNode(text: "B")
      t2Key = t2.getKey()
      try p2.append([t2])

      try root.append([p1, p2])
    }
    drainMainQueue()

    guard let baseP2 = editor.rangeCache[p2Key], let baseT2 = editor.rangeCache[t2Key] else {
      XCTFail("Missing range cache items for nodes under test")
      return
    }

    editor.invalidateDFSOrderCache()
    let (order, _) = editor.cachedDFSOrderAndIndex()
    editor.ensureFenwickCapacity(order.count)

    guard let t1Item = editor.rangeCache[t1Key], t1Item.dfsPosition > 0 else {
      XCTFail("Missing DFS position for afterKey")
      return
    }

    // Mimic `applyFenwickSuffixShift(afterKey:delta:)`: record the delta at the first node AFTER `t1`.
    let delta = 3
    editor.addFenwickDelta(atIndex: t1Item.dfsPosition + 1, delta: delta)
    XCTAssertTrue(editor.fenwickHasDeltas)

    XCTAssertEqual(editor.actualLocation(for: p2Key), baseP2.location + delta)
    XCTAssertEqual(editor.actualLocation(for: t2Key), baseT2.location + delta)
  }

  func testPointAtStringLocationUsesFenwickDelta() throws {
    let view = createTestEditorView()
    let editor = view.editor

    var t1Key: NodeKey = ""
    var t2Key: NodeKey = ""
    let delta = 5

    try editor.update {
      guard let root = getRoot() else { return }
      _ = try root.clear()

      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "A")
      t1Key = t1.getKey()
      try p1.append([t1])

      let p2 = createParagraphNode()
      let t2 = createTextNode(text: "B")
      t2Key = t2.getKey()
      try p2.append([t2])

      try root.append([p1, p2])
    }
    drainMainQueue()

    guard let baseT2 = editor.rangeCache[t2Key] else {
      XCTFail("Missing range cache item for t2")
      return
    }

    let baseTextStart = baseT2.location + baseT2.preambleLength + baseT2.childrenLength

    // Trigger a real text-only edit on t1. This causes `RopeReconciler` to use lazy locations,
    // updating only the dirty node's range cache entry and recording a Fenwick suffix shift for the rest.
    try editor.update {
      guard let t1 = getNodeByKey(key: t1Key) as? TextNode else {
        XCTFail("Missing t1 TextNode")
        return
      }
      try t1.setText(String(repeating: "A", count: 1 + delta))
    }
    drainMainQueue()

    // Skip this test if lazy Fenwick locations are disabled (useLazyLocations = false in RopeReconciler).
    // When disabled, no Fenwick deltas are created during text-only edits.
    guard editor.fenwickHasDeltas else {
      throw XCTSkip("Lazy Fenwick locations are disabled; skipping Fenwick delta test")
    }

    XCTAssertEqual(editor.rangeCache[t2Key]?.location, baseT2.location)
    XCTAssertEqual(editor.actualLocation(for: t2Key), baseT2.location + delta)

    let shiftedTextStart = baseTextStart + delta

    try editor.read {
      let point = try pointAtStringLocation(
        shiftedTextStart,
        searchDirection: .forward,
        rangeCache: editor.rangeCache,
        fenwickTree: editor.locationFenwickTree
      )
      XCTAssertEqual(point?.key, t2Key)
      XCTAssertEqual(point?.type, .text)
      XCTAssertEqual(point?.offset, 0)
    }
  }

  func testRebuildingDFSOrderWhileFenwickHasDeltas_MaterializesAndPreservesLocations() throws {
    let view = createTestEditorView()
    let editor = view.editor

    var t1Key: NodeKey = ""
    var t2Key: NodeKey = ""
    let delta = 4

    try editor.update {
      guard let root = getRoot() else { return }
      _ = try root.clear()

      let p1 = createParagraphNode()
      let t1 = createTextNode(text: "A")
      t1Key = t1.getKey()
      try p1.append([t1])

      let p2 = createParagraphNode()
      let t2 = createTextNode(text: "B")
      t2Key = t2.getKey()
      try p2.append([t2])

      try root.append([p1, p2])
    }
    drainMainQueue()

    guard let baseT2 = editor.rangeCache[t2Key] else {
      XCTFail("Missing range cache item for t2")
      return
    }

    // Trigger a text-only edit to create Fenwick deltas (lazy suffix shift).
    try editor.update {
      guard let t1 = getNodeByKey(key: t1Key) as? TextNode else {
        XCTFail("Missing t1 TextNode")
        return
      }
      try t1.setText(String(repeating: "A", count: 1 + delta))
    }
    drainMainQueue()

    // Skip this test if lazy Fenwick locations are disabled (useLazyLocations = false in RopeReconciler).
    // When disabled, no Fenwick deltas are created during text-only edits.
    guard editor.fenwickHasDeltas else {
      throw XCTSkip("Lazy Fenwick locations are disabled; skipping Fenwick delta test")
    }

    XCTAssertEqual(editor.rangeCache[t2Key]?.location, baseT2.location)
    XCTAssertEqual(editor.actualLocation(for: t2Key), baseT2.location + delta)

    // Simulate an external DFS cache invalidation while deltas are pending (this previously
    // could corrupt DFS positions by rebuilding order against stale base locations).
    editor.invalidateDFSOrderCache()
    _ = editor.cachedDFSOrderAndIndex()

    XCTAssertFalse(editor.fenwickHasDeltas, "Expected deltas to be materialized during DFS rebuild")
    XCTAssertEqual(editor.rangeCache[t2Key]?.location, baseT2.location + delta)
    XCTAssertEqual(editor.actualLocation(for: t2Key), baseT2.location + delta)
  }
}
