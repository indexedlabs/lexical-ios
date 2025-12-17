/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical
import LexicalListPlugin

#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import LexicalAppKit
#endif

@MainActor
final class MixedDocumentBenchmarkTests: XCTestCase {

  struct Variation {
    let name: String
    let flags: FeatureFlags
  }

  enum Position: String {
    case top
    case middle
    case end
  }

  struct DocumentAnchors {
    let topTextKey: NodeKey
    let middleTextKey: NodeKey
    let endTextKey: NodeKey
  }

  private let variations: [Variation] = [
    .init(name: "optimized-minimal", flags: FeatureFlags.optimizedProfile(.minimal)),
    .init(name: "optimized-balanced", flags: FeatureFlags.optimizedProfile(.balanced)),
    .init(name: "optimized-aggressive", flags: FeatureFlags.optimizedProfile(.aggressive)),
  ]

  private func makeEditors(
    flags: FeatureFlags
  ) throws -> (
    opt: (Editor, any ReadOnlyTextKitContextProtocol, ReconcilerMetricsCollector),
    leg: (Editor, any ReadOnlyTextKitContextProtocol, ReconcilerMetricsCollector)
  ) {
    let plugins: () -> [Plugin] = {
      [ListPlugin()]
    }

    let optMetrics = ReconcilerMetricsCollector()
    let optCtx = makeReadOnlyContext(
      editorConfig: EditorConfig(theme: Theme(), plugins: plugins(), metricsContainer: optMetrics),
      featureFlags: flags
    )
    try registerTestDecoratorNode(on: optCtx.editor)
    try registerTestDecoratorBlockNode(on: optCtx.editor)

    let legMetrics = ReconcilerMetricsCollector()
    let legCtx = makeReadOnlyContext(
      editorConfig: EditorConfig(theme: Theme(), plugins: plugins(), metricsContainer: legMetrics),
      featureFlags: FeatureFlags(useOptimizedReconciler: false)
    )
    try registerTestDecoratorNode(on: legCtx.editor)
    try registerTestDecoratorBlockNode(on: legCtx.editor)

    return ((optCtx.editor, optCtx, optMetrics), (legCtx.editor, legCtx, legMetrics))
  }

  private func makeRepeatingText(seed: Int, width: Int) -> String {
    let base = "abcdefghijklmnopqrstuvwxyz "
    let repeated = String(repeating: base, count: max(1, (width / base.count) + 1))
    return "(\(seed)) " + repeated.prefix(width)
  }

  private func buildMixedDocument(
    editor: Editor,
    blockCount: Int = 50,
    paragraphWidth: Int = 240
  ) throws -> DocumentAnchors {
    var textKeys: [NodeKey] = []

    try editor.update {
      guard let root = getRoot() else { return }

      let existing = root.getChildren()
      for child in existing {
        try child.remove()
      }

      var blocks: [Node] = []
      blocks.reserveCapacity(blockCount)

      for i in 0..<blockCount {
        switch i % 5 {
        case 0:
          let p = ParagraphNode()
          let t = TextNode(text: makeRepeatingText(seed: i, width: paragraphWidth) + " ¶\(i)")
          textKeys.append(t.getKey())
          try p.append([t])
          blocks.append(p)

        case 1:
          let p = ParagraphNode()
          let t1 = TextNode(text: "prefix \(i) ")
          let deco = TestDecoratorNodeCrossplatform(numTimes: 0)
          let t2 = TextNode(text: " suffix \(makeRepeatingText(seed: i, width: max(32, paragraphWidth / 3)))")
          textKeys.append(t1.getKey())
          textKeys.append(t2.getKey())
          try p.append([t1, deco, t2])
          blocks.append(p)

        case 2:
          let list = createListNode(listType: (i % 10 == 2) ? .check : .bullet)
          for j in 0..<3 {
            let item = ListItemNode()
            let p = ParagraphNode()
            let t = TextNode(text: "item \(i).\(j) " + makeRepeatingText(seed: (i * 10) + j, width: max(48, paragraphWidth / 2)))
            textKeys.append(t.getKey())
            try p.append([t])
            try item.append([p])
            try list.append([item])
          }
          blocks.append(list)

        case 3:
          blocks.append(TestDecoratorBlockNodeCrossplatform())

        default:
          let p = ParagraphNode()
          let t = TextNode(text: "para \(i) " + makeRepeatingText(seed: i, width: max(64, paragraphWidth / 2)))
          textKeys.append(t.getKey())
          try p.append([t])
          blocks.append(p)
        }
      }

      try root.append(blocks)
    }

    guard let top = textKeys.first, let end = textKeys.last else {
      throw XCTSkip("mixed document did not create any TextNodes")
    }

    let middle = textKeys[textKeys.count / 2]
    return DocumentAnchors(topTextKey: top, middleTextKey: middle, endTextKey: end)
  }

  private func insertMixedBlock(editor: Editor, position: Position, iteration: Int) throws {
    try editor.update {
      guard let root = getRoot() else { return }

      let nodeToInsert: Node
      switch iteration % 3 {
      case 0:
        let p = ParagraphNode()
        let t = TextNode(text: "INS-P \(iteration) " + makeRepeatingText(seed: iteration, width: 48))
        try p.append([t])
        nodeToInsert = p
      case 1:
        nodeToInsert = TestDecoratorBlockNodeCrossplatform()
      default:
        let list = createListNode(listType: .bullet)
        for j in 0..<2 {
          let item = ListItemNode()
          let p = ParagraphNode()
          let t = TextNode(text: "INS-L \(iteration).\(j) " + makeRepeatingText(seed: (iteration * 10) + j, width: 40))
          try p.append([t])
          try item.append([p])
          try list.append([item])
        }
        nodeToInsert = list
      }

      switch position {
      case .top:
        if let first = root.getFirstChild() {
          _ = try first.insertBefore(nodeToInsert: nodeToInsert)
        } else {
          try root.append([nodeToInsert])
        }
      case .end:
        try root.append([nodeToInsert])
      case .middle:
        let idx = max(0, root.getChildrenSize() / 2)
        if idx == root.getChildrenSize() {
          try root.append([nodeToInsert])
        } else if let anchor = root.getChildAtIndex(index: idx) {
          _ = try anchor.insertBefore(nodeToInsert: nodeToInsert)
        }
      }
    }
  }

  private func insertText(
    editor: Editor,
    textKey: NodeKey,
    insertAt: Position,
    iteration: Int
  ) throws {
    try editor.update {
      guard let t: TextNode = getNodeByKey(key: textKey) else { return }
      let current = t.getTextPart()
      let insertion = "[\(iteration % 10)]"

      let ns = current as NSString
      let mid = ns.length / 2
      let next: String

      switch insertAt {
      case .top:
        next = insertion + current
      case .middle:
        next = ns.substring(to: mid) + insertion + ns.substring(from: mid)
      case .end:
        next = current + insertion
      }

      try t.setText(next)
    }
  }

  func testMixedDocumentSeedBenchmarkQuick() throws {
    for v in variations {
      let (opt, leg) = try makeEditors(flags: v.flags)

      opt.2.resetMetrics()
      let dtOpt = try measureWallTime {
        _ = try buildMixedDocument(editor: opt.0, blockCount: 50, paragraphWidth: 240)
      }
      let optSummary = opt.2.summarize(label: "seed/\(v.name)")

      leg.2.resetMetrics()
      let dtLeg = try measureWallTime {
        _ = try buildMixedDocument(editor: leg.0, blockCount: 50, paragraphWidth: 240)
      }
      let legSummary = leg.2.summarize(label: "seed/legacy")

      XCTAssertEqual(opt.1.textStorage.string, leg.1.textStorage.string)

      print("🔥 MIXED-SEED variation=\(v.name) optimized=\(dtOpt)s legacy=\(dtLeg)s opt=\(optSummary.debugDescription) leg=\(legSummary.debugDescription)")
    }
  }

  func testMixedDocumentInsertBenchmarkTopMiddleEndQuick() throws {
    let positions: [(Position, String)] = [(.top, "TOP"), (.middle, "MIDDLE"), (.end, "END")]
    let loops = 6

    for v in variations {
      for (pos, label) in positions {
        let (opt, leg) = try makeEditors(flags: v.flags)

        _ = try buildMixedDocument(editor: opt.0, blockCount: 50, paragraphWidth: 200)
        _ = try buildMixedDocument(editor: leg.0, blockCount: 50, paragraphWidth: 200)

        leg.2.resetMetrics()
        let dtLeg = try measureWallTime {
          for i in 0..<loops { try insertMixedBlock(editor: leg.0, position: pos, iteration: i) }
        }
        let legSummary = leg.2.summarize(label: "insert/\(label)/legacy/\(v.name)")
        XCTAssertEqual(leg.2.reconcilerRuns.count, loops)

        opt.2.resetMetrics()
        let dtOpt = try measureWallTime {
          for i in 0..<loops { try insertMixedBlock(editor: opt.0, position: pos, iteration: i) }
        }
        let optSummary = opt.2.summarize(label: "insert/\(label)/opt/\(v.name)")
        XCTAssertEqual(opt.2.reconcilerRuns.count, loops)

        XCTAssertEqual(opt.1.textStorage.string, leg.1.textStorage.string)
        print("🔥 MIXED-INSERT [\(label)] variation=\(v.name) optimized=\(dtOpt)s legacy=\(dtLeg)s opt=\(optSummary.debugDescription) leg=\(legSummary.debugDescription)")
      }
    }
  }

  func testMixedDocumentTextInsertBenchmarkTopMiddleEndQuick() throws {
    let loops = 10

    for v in variations {
      let (opt, leg) = try makeEditors(flags: v.flags)

      let optAnchors = try buildMixedDocument(editor: opt.0, blockCount: 50, paragraphWidth: 220)
      let legAnchors = try buildMixedDocument(editor: leg.0, blockCount: 50, paragraphWidth: 220)

      // TOP (insert at start of first text node)
      leg.2.resetMetrics()
      let dtLegTop = try measureWallTime {
        for i in 0..<loops {
          try insertText(editor: leg.0, textKey: legAnchors.topTextKey, insertAt: .top, iteration: i)
        }
      }
      let legTopSummary = leg.2.summarize(label: "text/top/legacy/\(v.name)")
      XCTAssertEqual(leg.2.reconcilerRuns.count, loops)

      opt.2.resetMetrics()
      let dtOptTop = try measureWallTime {
        for i in 0..<loops {
          try insertText(editor: opt.0, textKey: optAnchors.topTextKey, insertAt: .top, iteration: i)
        }
      }
      let optTopSummary = opt.2.summarize(label: "text/top/opt/\(v.name)")
      XCTAssertEqual(opt.2.reconcilerRuns.count, loops)
      XCTAssertEqual(opt.1.textStorage.string, leg.1.textStorage.string)
      print("🔥 MIXED-TEXT [TOP] variation=\(v.name) optimized=\(dtOptTop)s legacy=\(dtLegTop)s opt=\(optTopSummary.debugDescription) leg=\(legTopSummary.debugDescription)")

      // MIDDLE (insert into middle of representative text node)
      leg.2.resetMetrics()
      let dtLegMid = try measureWallTime {
        for i in 0..<loops {
          try insertText(editor: leg.0, textKey: legAnchors.middleTextKey, insertAt: .middle, iteration: i)
        }
      }
      let legMidSummary = leg.2.summarize(label: "text/middle/legacy/\(v.name)")
      XCTAssertEqual(leg.2.reconcilerRuns.count, loops)

      opt.2.resetMetrics()
      let dtOptMid = try measureWallTime {
        for i in 0..<loops {
          try insertText(editor: opt.0, textKey: optAnchors.middleTextKey, insertAt: .middle, iteration: i)
        }
      }
      let optMidSummary = opt.2.summarize(label: "text/middle/opt/\(v.name)")
      XCTAssertEqual(opt.2.reconcilerRuns.count, loops)
      XCTAssertEqual(opt.1.textStorage.string, leg.1.textStorage.string)
      print("🔥 MIXED-TEXT [MIDDLE] variation=\(v.name) optimized=\(dtOptMid)s legacy=\(dtLegMid)s opt=\(optMidSummary.debugDescription) leg=\(legMidSummary.debugDescription)")

      // END (append into last text node)
      leg.2.resetMetrics()
      let dtLegEnd = try measureWallTime {
        for i in 0..<loops {
          try insertText(editor: leg.0, textKey: legAnchors.endTextKey, insertAt: .end, iteration: i)
        }
      }
      let legEndSummary = leg.2.summarize(label: "text/end/legacy/\(v.name)")
      XCTAssertEqual(leg.2.reconcilerRuns.count, loops)

      opt.2.resetMetrics()
      let dtOptEnd = try measureWallTime {
        for i in 0..<loops {
          try insertText(editor: opt.0, textKey: optAnchors.endTextKey, insertAt: .end, iteration: i)
        }
      }
      let optEndSummary = opt.2.summarize(label: "text/end/opt/\(v.name)")
      XCTAssertEqual(opt.2.reconcilerRuns.count, loops)
      XCTAssertEqual(opt.1.textStorage.string, leg.1.textStorage.string)
      print("🔥 MIXED-TEXT [END] variation=\(v.name) optimized=\(dtOptEnd)s legacy=\(dtLegEnd)s opt=\(optEndSummary.debugDescription) leg=\(legEndSummary.debugDescription)")
    }
  }
}

