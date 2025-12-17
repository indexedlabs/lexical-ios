/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical
import LexicalListPlugin

@MainActor
final class OptimizedReconcilerTextFastPathTests: XCTestCase {

  private func makeOptimizedView(
    flags: FeatureFlags,
    metrics: ReconcilerMetricsCollector
  ) throws -> TestEditorView {
    let view = TestEditorView(
      editorConfig: EditorConfig(theme: Theme(), plugins: [ListPlugin()], metricsContainer: metrics),
      featureFlags: flags
    )
    try registerTestDecoratorNode(on: view.editor)
    try registerTestDecoratorBlockNode(on: view.editor)
    return view
  }

  private func buildSmallMixedDoc(editor: Editor) throws -> NodeKey {
    var firstTextKey: NodeKey?

    try editor.update {
      guard let root = getRoot() else { return }
      for child in root.getChildren() { try child.remove() }

      let p0 = ParagraphNode()
      let t0 = TextNode(text: "hello world")
      firstTextKey = t0.getKey()
      try p0.append([t0])

      let p1 = ParagraphNode()
      let t1a = TextNode(text: "prefix ")
      let deco = TestDecoratorNodeCrossplatform(numTimes: 0)
      let t1b = TextNode(text: " suffix")
      try p1.append([t1a, deco, t1b])

      let list = createListNode(listType: .bullet)
      let item = ListItemNode()
      let lp = ParagraphNode()
      let lt = TextNode(text: "item text")
      try lp.append([lt])
      try item.append([lp])
      try list.append([item])

      let blocks: [Node] = [p0, p1, list, TestDecoratorBlockNodeCrossplatform()]
      try root.append(blocks)
    }

    guard let key = firstTextKey else {
      throw XCTSkip("failed to create TextNode for mixed doc")
    }
    return key
  }

  func testOptimizedTextEdit_UsesTextOnlyFastPath() throws {
    let metrics = ReconcilerMetricsCollector()
    let flags = FeatureFlags.optimizedProfile(.minimal)
    let view = try makeOptimizedView(flags: flags, metrics: metrics)

    let key = try buildSmallMixedDoc(editor: view.editor)

    metrics.resetMetrics()
    try view.editor.update {
      guard let t: TextNode = getNodeByKey(key: key) else { return }
      try t.setText("hello world!!!")
    }

    let paths = metrics.reconcilerRuns.map { $0.pathLabel }
    XCTAssertTrue(paths.contains("text-only-min-replace"), "expected a text-only fast path, got: \(paths)")
    XCTAssertFalse(paths.contains("slow"), "unexpected slow path for simple text edit: \(paths)")
  }
}
