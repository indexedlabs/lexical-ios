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

  private func makeView(
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
    let flags = FeatureFlags()
    let view = try makeView(flags: flags, metrics: metrics)

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

  func testOptimizedInsertBlock_UsesInsertBlockFastPath_DoesNotGoSlow() throws {
    let metrics = ReconcilerMetricsCollector()
    let flags = FeatureFlags()
    let view = try makeView(flags: flags, metrics: metrics)

    _ = try buildSmallMixedDoc(editor: view.editor)

    metrics.resetMetrics()
    try view.editor.update {
      guard let root = getRoot(),
            let first = root.getFirstChild() else { return }

      let p = ParagraphNode()
      let t = TextNode(text: "Inserted")
      try p.append([t])
      try first.insertAfter(nodeToInsert: p)
    }

    let runs = metrics.reconcilerRuns
    XCTAssertFalse(runs.isEmpty, "Expected at least one reconciler run")

    let paths = runs.map { $0.pathLabel }
    XCTAssertTrue(paths.contains("insert-block"), "expected insert-block fast path, got: \(paths)")
    XCTAssertFalse(paths.contains("slow"), "unexpected slow path for insert: \(paths)")
    XCTAssertFalse(runs.contains(where: { $0.treatedAllNodesAsDirty }), "unexpected treatedAllNodesAsDirty for insert: \(paths)")
  }

  func testOptimizedInsertBlock_Aggressive_EndMatchesLegacy_AfterMultipleAppends() throws {
    let optMetrics = ReconcilerMetricsCollector()
    let optFlags = FeatureFlags()
    let optView = try makeView(flags: optFlags, metrics: optMetrics)

    let legMetrics = ReconcilerMetricsCollector()
    let legFlags = FeatureFlags()
    let legView = try makeView(flags: legFlags, metrics: legMetrics)

    _ = try buildSmallMixedDoc(editor: optView.editor)
    _ = try buildSmallMixedDoc(editor: legView.editor)

    func appendAtEnd(editor: Editor, iteration: Int) throws {
      try editor.update {
        guard let root = getRoot() else { return }

        let nodeToInsert: Node
        switch iteration % 3 {
        case 0:
          let p = ParagraphNode()
          let t = TextNode(text: "INS-P \(iteration)")
          try p.append([t])
          nodeToInsert = p
        case 1:
          nodeToInsert = TestDecoratorBlockNodeCrossplatform()
        default:
          let list = createListNode(listType: .bullet)
          for j in 0..<2 {
            let item = ListItemNode()
            let p = ParagraphNode()
            let t = TextNode(text: "INS-L \(iteration).\(j)")
            try p.append([t])
            try item.append([p])
            try list.append([item])
          }
          nodeToInsert = list
        }

        try root.append([nodeToInsert])
      }
    }

    for i in 0..<3 {
      try appendAtEnd(editor: optView.editor, iteration: i)
      try appendAtEnd(editor: legView.editor, iteration: i)
      XCTAssertEqual(
        optView.attributedTextString,
        legView.attributedTextString,
        "attributedText mismatch after end-append iteration \(i)"
      )
    }
  }

  func testOptimizedInsertBlock_Aggressive_EndMatchesLegacy_WhenLastBlockIsParagraphWithDecoratorPreamble() throws {
    let optMetrics = ReconcilerMetricsCollector()
    let optFlags = FeatureFlags()
    let optView = try makeView(flags: optFlags, metrics: optMetrics)

    let legMetrics = ReconcilerMetricsCollector()
    let legFlags = FeatureFlags()
    let legView = try makeView(flags: legFlags, metrics: legMetrics)

    func buildDoc(editor: Editor) throws {
      try editor.update {
        guard let root = getRoot() else { return }
        for child in root.getChildren() { try child.remove() }

        let p0 = ParagraphNode()
        try p0.append([TextNode(text: "p0")])

        let decoBlock = TestDecoratorBlockNodeCrossplatform()

        let pLast = ParagraphNode()
        try pLast.append([TextNode(text: "pLast")])

        try root.append([p0, decoBlock, pLast])
      }
    }

    try buildDoc(editor: optView.editor)
    try buildDoc(editor: legView.editor)

    func appendAtEnd(editor: Editor, iteration: Int) throws {
      try editor.update {
        guard let root = getRoot() else { return }

        let nodeToInsert: Node
        switch iteration % 3 {
        case 0:
          let p = ParagraphNode()
          try p.append([TextNode(text: "INS-P \(iteration)")])
          nodeToInsert = p
        case 1:
          nodeToInsert = TestDecoratorBlockNodeCrossplatform()
        default:
          let list = createListNode(listType: .bullet)
          for j in 0..<2 {
            let item = ListItemNode()
            let p = ParagraphNode()
            try p.append([TextNode(text: "INS-L \(iteration).\(j)")])
            try item.append([p])
            try list.append([item])
          }
          nodeToInsert = list
        }

        try root.append([nodeToInsert])
      }
    }

    for i in 0..<3 {
      try appendAtEnd(editor: optView.editor, iteration: i)
      try appendAtEnd(editor: legView.editor, iteration: i)
      XCTAssertEqual(
        optView.attributedTextString,
        legView.attributedTextString,
        "attributedText mismatch after end-append iteration \(i)"
      )
    }
  }
}
