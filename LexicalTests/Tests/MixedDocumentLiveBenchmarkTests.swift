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
final class MixedDocumentLiveBenchmarkTests: XCTestCase {
  private func attachAttributedTextMismatch(
    optimized: String,
    legacy: String,
    variation: String,
    position: String
  ) {
    guard optimized != legacy else { return }

    let a = optimized as NSString
    let b = legacy as NSString
    let minLen = min(a.length, b.length)
    var idx = 0
    while idx < minLen, a.character(at: idx) == b.character(at: idx) { idx += 1 }

    let window = 120
    let start = max(0, idx - window)
    let endA = min(a.length, idx + window)
    let endB = min(b.length, idx + window)

    let snippetA = a.substring(with: NSRange(location: start, length: max(0, endA - start)))
    let snippetB = b.substring(with: NSRange(location: start, length: max(0, endB - start)))

    let debug = """
    variation: \(variation)
    position: \(position)
    mismatchIndex(utf16): \(idx)
    optimizedLength(utf16): \(a.length)
    legacyLength(utf16): \(b.length)

    optimizedSnippet:\n\(snippetA)

    legacySnippet:\n\(snippetB)
    """
    let attachment = XCTAttachment(string: debug)
    attachment.name = "attributedText mismatch (\(variation), \(position))"
    add(attachment)
  }

  struct Variation {
    let name: String
    let flags: FeatureFlags
  }

  enum Position {
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
    .init(name: "optimized-minimal", flags: FeatureFlags()),
    .init(name: "optimized-balanced", flags: FeatureFlags()),
    .init(name: "optimized-aggressive", flags: FeatureFlags()),
  ]

  private var benchBlockCount: Int {
    perfEnvInt("LEXICAL_BENCH_BLOCKS", default: 50)
  }

  private func makeViews(
    flags: FeatureFlags
  ) throws -> (
    opt: (view: TestEditorView, metrics: ReconcilerMetricsCollector),
    leg: (view: TestEditorView, metrics: ReconcilerMetricsCollector)
  ) {
    let plugins: () -> [Plugin] = { [ListPlugin()] }

    let optMetrics = ReconcilerMetricsCollector()
    let optView = TestEditorView(
      editorConfig: EditorConfig(theme: Theme(), plugins: plugins(), metricsContainer: optMetrics),
      featureFlags: flags
    )
    try registerTestDecoratorNode(on: optView.editor)
    try registerTestDecoratorBlockNode(on: optView.editor)

    let legMetrics = ReconcilerMetricsCollector()
    let legView = TestEditorView(
      editorConfig: EditorConfig(theme: Theme(), plugins: plugins(), metricsContainer: legMetrics),
      featureFlags: FeatureFlags()
    )
    try registerTestDecoratorNode(on: legView.editor)
    try registerTestDecoratorBlockNode(on: legView.editor)

    return ((optView, optMetrics), (legView, legMetrics))
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

  private func deleteMixedBlock(editor: Editor, position: Position) throws {
    try editor.update {
      guard let root = getRoot() else { return }
      let count = root.getChildrenSize()
      guard count > 0 else { return }

      let idx: Int
      switch position {
      case .top:
        idx = 0
      case .end:
        idx = max(0, count - 1)
      case .middle:
        idx = max(0, count / 2)
      }

      if let node = root.getChildAtIndex(index: idx) {
        try node.remove()
      }
    }
  }

  private func insertText(
    editor: Editor,
    textKey: NodeKey,
    position: Position,
    iteration: Int
  ) throws {
    try editor.update {
      guard let t: TextNode = getNodeByKey(key: textKey) else { return }
      let current = t.getTextPart()
      let insertion = "[\(iteration % 10)]"

      let ns = current as NSString
      let mid = ns.length / 2
      let next: String

      switch position {
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

  private func typingInsertionLocation(
    editor: Editor,
    textKey: NodeKey,
    position: Position
  ) throws -> Int {
    var loc: Int?
    try editor.read {
      guard let range = editor.rangeCache[textKey]?.range else { return }
      switch position {
      case .top:
        loc = range.location
      case .middle:
        loc = range.location + (range.length / 2)
      case .end:
        loc = range.location + range.length
      }
    }
    return loc ?? 0
  }

  func testMixedDocumentLiveInsertBenchmarkTopMiddleEndQuick() throws {
    let isLargeDoc = benchBlockCount >= 200
    let loops = isLargeDoc ? 1 : 3
    let variationsToRun: [Variation] = isLargeDoc ? [variations[1]] : variations
    let positions: [(Position, String)] = {
      let all: [(Position, String)] = [(.top, "TOP"), (.middle, "MIDDLE"), (.end, "END")]
      guard isLargeDoc else { return all }

      let requested = ProcessInfo.processInfo.environment["LEXICAL_BENCH_POSITION"]?.uppercased()
      switch requested {
      case "TOP":
        return [(.top, "TOP")]
      case "MIDDLE":
        return [(.middle, "MIDDLE")]
      case "END", nil:
        return [(.end, "END")]
      default:
        return [(.end, "END")]
      }
    }()

    for v in variationsToRun {
      try autoreleasepool {
        let (opt, leg) = try makeViews(flags: v.flags)

        _ = try buildMixedDocument(editor: opt.view.editor, blockCount: benchBlockCount, paragraphWidth: 200)
        _ = try buildMixedDocument(editor: leg.view.editor, blockCount: benchBlockCount, paragraphWidth: 200)

        let optBaseline = EditorState(opt.view.editor.getEditorState())
        let legBaseline = EditorState(leg.view.editor.getEditorState())

        for (idx, (pos, label)) in positions.enumerated() {
          if idx > 0 {
            try opt.view.editor.setEditorState(EditorState(optBaseline))
            try leg.view.editor.setEditorState(EditorState(legBaseline))
          }

          leg.metrics.resetMetrics()
          let dtLeg = try measureWallTime {
            for i in 0..<loops { try insertMixedBlock(editor: leg.view.editor, position: pos, iteration: i) }
          }
          let legSummary = leg.metrics.summarize(label: "live/insert/\(label)/legacy/\(v.name)")
          XCTAssertGreaterThanOrEqual(leg.metrics.reconcilerRuns.count, loops)

          opt.metrics.resetMetrics()
          let dtOpt = try measureWallTime {
            for i in 0..<loops { try insertMixedBlock(editor: opt.view.editor, position: pos, iteration: i) }
          }
          let optSummary = opt.metrics.summarize(label: "live/insert/\(label)/opt/\(v.name)")
          XCTAssertGreaterThanOrEqual(opt.metrics.reconcilerRuns.count, loops)

          let optStr = opt.view.attributedTextString
          let legStr = leg.view.attributedTextString
          attachAttributedTextMismatch(optimized: optStr, legacy: legStr, variation: v.name, position: label)
          XCTAssertEqual(optStr, legStr, "attributedText mismatch (variation=\(v.name), position=\(label))")
          emitPerfBenchmarkRecord(
            suite: String(describing: Self.self),
            test: #function,
            scenario: "live-insert",
            variation: v.name,
            position: label,
            loops: loops,
            optimizedWallTimeSeconds: dtOpt,
            optimizedMetrics: optSummary,
            legacyWallTimeSeconds: dtLeg,
            legacyMetrics: legSummary
          )
        }
      }
    }
  }

  func testMixedDocumentLiveTextInsertBenchmarkTopMiddleEndQuick() throws {
    let loops = 10

    for v in variations {
      try autoreleasepool {
        let (opt, leg) = try makeViews(flags: v.flags)

        let optAnchors = try buildMixedDocument(editor: opt.view.editor, blockCount: benchBlockCount, paragraphWidth: 220)
        let legAnchors = try buildMixedDocument(editor: leg.view.editor, blockCount: benchBlockCount, paragraphWidth: 220)

        for (pos, label, optKey, legKey) in [
          (Position.top, "TOP", optAnchors.topTextKey, legAnchors.topTextKey),
          (Position.middle, "MIDDLE", optAnchors.middleTextKey, legAnchors.middleTextKey),
          (Position.end, "END", optAnchors.endTextKey, legAnchors.endTextKey),
        ] {
          leg.metrics.resetMetrics()
          let dtLeg = try measureWallTime {
            for i in 0..<loops {
              try insertText(editor: leg.view.editor, textKey: legKey, position: pos, iteration: i)
            }
          }
          let legSummary = leg.metrics.summarize(label: "live/text/\(label)/legacy/\(v.name)")
          XCTAssertGreaterThanOrEqual(leg.metrics.reconcilerRuns.count, loops)

          opt.metrics.resetMetrics()
          let dtOpt = try measureWallTime {
            for i in 0..<loops {
              try insertText(editor: opt.view.editor, textKey: optKey, position: pos, iteration: i)
            }
          }
          let optSummary = opt.metrics.summarize(label: "live/text/\(label)/opt/\(v.name)")
          XCTAssertGreaterThanOrEqual(opt.metrics.reconcilerRuns.count, loops)

          let optStr = opt.view.attributedTextString
          let legStr = leg.view.attributedTextString
          attachAttributedTextMismatch(optimized: optStr, legacy: legStr, variation: v.name, position: label)
          XCTAssertEqual(optStr, legStr, "attributedText mismatch (variation=\(v.name), position=\(label))")
          emitPerfBenchmarkRecord(
            suite: String(describing: Self.self),
            test: #function,
            scenario: "live-text",
            variation: v.name,
            position: label,
            loops: loops,
            optimizedWallTimeSeconds: dtOpt,
            optimizedMetrics: optSummary,
            legacyWallTimeSeconds: dtLeg,
            legacyMetrics: legSummary
          )
        }
      }
    }
  }

  func testMixedDocumentLiveTypingInsertBenchmarkTopMiddleEndQuick() throws {
    let loops = 50

    for v in variations {
      try autoreleasepool {
        let (opt, leg) = try makeViews(flags: v.flags)

        let optAnchors = try buildMixedDocument(editor: opt.view.editor, blockCount: benchBlockCount, paragraphWidth: 220)
        let legAnchors = try buildMixedDocument(editor: leg.view.editor, blockCount: benchBlockCount, paragraphWidth: 220)

        for (pos, label, optKey, legKey) in [
          (Position.top, "TOP", optAnchors.topTextKey, legAnchors.topTextKey),
          (Position.middle, "MIDDLE", optAnchors.middleTextKey, legAnchors.middleTextKey),
          (Position.end, "END", optAnchors.endTextKey, legAnchors.endTextKey),
        ] {
          let optLoc = try typingInsertionLocation(editor: opt.view.editor, textKey: optKey, position: pos)
          let legLoc = try typingInsertionLocation(editor: leg.view.editor, textKey: legKey, position: pos)

          opt.view.setSelectedRange(NSRange(location: min(max(0, optLoc), opt.view.textStorageLength), length: 0))
          leg.view.setSelectedRange(NSRange(location: min(max(0, legLoc), leg.view.textStorageLength), length: 0))

          leg.metrics.resetMetrics()
          let dtLeg = try measureWallTime {
            for i in 0..<loops {
              leg.view.insertText(String(i % 10))
            }
          }
          let legSummary = leg.metrics.summarize(label: "live/typing/\(label)/legacy/\(v.name)")
          XCTAssertGreaterThanOrEqual(leg.metrics.reconcilerRuns.count, loops)

          opt.metrics.resetMetrics()
          let dtOpt = try measureWallTime {
            for i in 0..<loops {
              opt.view.insertText(String(i % 10))
            }
          }
          let optSummary = opt.metrics.summarize(label: "live/typing/\(label)/opt/\(v.name)")
          XCTAssertGreaterThanOrEqual(opt.metrics.reconcilerRuns.count, loops)

          let optStr = opt.view.attributedTextString
          let legStr = leg.view.attributedTextString
          attachAttributedTextMismatch(optimized: optStr, legacy: legStr, variation: v.name, position: label)
          XCTAssertEqual(optStr, legStr, "attributedText mismatch (variation=\(v.name), position=\(label))")
          XCTAssertEqual(opt.view.selectedRange, leg.view.selectedRange)
          emitPerfBenchmarkRecord(
            suite: String(describing: Self.self),
            test: #function,
            scenario: "live-typing",
            variation: v.name,
            position: label,
            loops: loops,
            optimizedWallTimeSeconds: dtOpt,
            optimizedMetrics: optSummary,
            legacyWallTimeSeconds: dtLeg,
            legacyMetrics: legSummary
          )
        }
      }
    }
  }

  func testMixedDocumentLiveDeleteBlockBenchmarkTopMiddleEndQuick() throws {
    let positions: [(Position, String)] = [(.top, "TOP"), (.middle, "MIDDLE"), (.end, "END")]
    let loops = 5

    for v in variations {
      for (pos, label) in positions {
        try autoreleasepool {
          let (opt, leg) = try makeViews(flags: v.flags)

          _ = try buildMixedDocument(editor: opt.view.editor, blockCount: benchBlockCount, paragraphWidth: 200)
          _ = try buildMixedDocument(editor: leg.view.editor, blockCount: benchBlockCount, paragraphWidth: 200)

          leg.metrics.resetMetrics()
          let dtLeg = try measureWallTime {
            for _ in 0..<loops { try deleteMixedBlock(editor: leg.view.editor, position: pos) }
          }
          let legSummary = leg.metrics.summarize(label: "live/delete/\(label)/legacy/\(v.name)")
          XCTAssertGreaterThanOrEqual(leg.metrics.reconcilerRuns.count, loops)

          opt.metrics.resetMetrics()
          let dtOpt = try measureWallTime {
            for _ in 0..<loops { try deleteMixedBlock(editor: opt.view.editor, position: pos) }
          }
          let optSummary = opt.metrics.summarize(label: "live/delete/\(label)/opt/\(v.name)")
          XCTAssertGreaterThanOrEqual(opt.metrics.reconcilerRuns.count, loops)

          let optStr = opt.view.attributedTextString
          let legStr = leg.view.attributedTextString
          attachAttributedTextMismatch(optimized: optStr, legacy: legStr, variation: v.name, position: label)
          XCTAssertEqual(optStr, legStr, "attributedText mismatch (variation=\(v.name), position=\(label))")
          emitPerfBenchmarkRecord(
            suite: String(describing: Self.self),
            test: #function,
            scenario: "live-delete",
            variation: v.name,
            position: label,
            loops: loops,
            optimizedWallTimeSeconds: dtOpt,
            optimizedMetrics: optSummary,
            legacyWallTimeSeconds: dtLeg,
            legacyMetrics: legSummary
          )
        }
      }
    }
  }
}
