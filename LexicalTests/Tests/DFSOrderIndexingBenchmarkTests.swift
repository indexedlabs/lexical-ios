/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical

@MainActor
final class DFSOrderIndexingBenchmarkTests: XCTestCase {

  private func buildParagraphDocument(editor: Editor, blockCount: Int, paragraphWidth: Int) throws {
    func makeRepeatingText(seed: Int, width: Int) -> String {
      let base = "abcdefghijklmnopqrstuvwxyz "
      let repeated = String(repeating: base, count: max(1, (width / base.count) + 1))
      return "(\(seed)) " + repeated.prefix(width)
    }

    try editor.update {
      guard let root = getRoot() else { return }

      let existing = root.getChildren()
      for child in existing { try child.remove() }

      var blocks: [Node] = []
      blocks.reserveCapacity(blockCount)
      for i in 0..<blockCount {
        let p = ParagraphNode()
        let t = TextNode(text: "para \(i) " + makeRepeatingText(seed: i, width: paragraphWidth))
        try p.append([t])
        blocks.append(p)
      }
      try root.append(blocks)
    }
  }

  private func buildIndexMap(keys: [NodeKey]) -> [NodeKey: Int] {
    var index: [NodeKey: Int] = [:]
    index.reserveCapacity(keys.count)
    for (i, key) in keys.enumerated() { index[key] = i + 1 }
    return index
  }

  func testDFSOrderIndexingTreeVsSortBenchmark() throws {
    let blockCount = perfEnvInt("LEXICAL_BENCH_BLOCKS", default: 50)
    let loops = perfEnvInt("LEXICAL_BENCH_DFS_REBUILDS", default: 20)

    let view = createTestEditorView(featureFlags: FeatureFlags.optimizedProfile(.minimal))
    view.editor.resetEditor(pendingEditorState: nil)
    try buildParagraphDocument(editor: view.editor, blockCount: blockCount, paragraphWidth: 200)

    let state = view.editor.getEditorState()
    let cache = view.editor.rangeCache
    XCTAssertFalse(cache.isEmpty)

    let sortedWarm = sortedNodeKeysByLocation(rangeCache: cache)
    let treeWarm = nodeKeysByTreeDFSOrder(state: state, rangeCache: cache)
    if let treeWarm {
      XCTAssertEqual(treeWarm, sortedWarm)
    }

    func measureTree() throws -> TimeInterval {
      var sink = 0
      let dt = try measureWallTime {
        for _ in 0..<loops {
          let keys = nodeKeysByTreeDFSOrder(state: state, rangeCache: cache)
            ?? sortedNodeKeysByLocation(rangeCache: cache)
          sink ^= buildIndexMap(keys: keys).count
        }
      }
      XCTAssertNotEqual(sink, -1)
      return dt
    }

    func measureSort() throws -> TimeInterval {
      var sink = 0
      let dt = try measureWallTime {
        for _ in 0..<loops {
          let keys = sortedNodeKeysByLocation(rangeCache: cache)
          sink ^= buildIndexMap(keys: keys).count
        }
      }
      XCTAssertNotEqual(sink, -1)
      return dt
    }

    // Measure twice, alternating order to reduce bias from cache warming.
    let dtTree1 = try measureTree()
    let dtSort1 = try measureSort()
    let dtSort2 = try measureSort()
    let dtTree2 = try measureTree()

    let dtTree = (dtTree1 + dtTree2) / 2
    let dtSort = (dtSort1 + dtSort2) / 2

    let empty = ReconcilerMetricsSummary(label: "dfs-order-index", runs: [])
    emitPerfBenchmarkRecord(
      suite: String(describing: Self.self),
      test: #function,
      scenario: "dfs-order-index",
      variation: "blocks-\(blockCount)",
      position: "nodes-\(cache.count)",
      loops: loops,
      optimizedWallTimeSeconds: dtTree,
      optimizedMetrics: empty,
      legacyWallTimeSeconds: dtSort,
      legacyMetrics: empty
    )
  }
}
