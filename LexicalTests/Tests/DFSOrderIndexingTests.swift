/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
@testable import Lexical

@MainActor
final class DFSOrderIndexingTests: XCTestCase {

  func testCachedDFSOrderIsCanonicalLocationOrder() throws {
    let view = createTestEditorView(featureFlags: FeatureFlags.optimizedProfile(.minimal))

    try view.editor.update {
      guard let root = getRoot() else { return }
      let p1 = ParagraphNode()
      let t1 = TextNode(text: "Hello")
      try p1.append([t1])

      let p2 = ParagraphNode()
      let t2 = TextNode(text: "World")
      try p2.append([t2])

      try root.append([p1, p2])
    }

    view.editor.invalidateDFSOrderCache()
    let (order, indexOf) = view.editor.cachedDFSOrderAndIndex()

    XCTAssertEqual(order.first, kRootNodeKey)
    XCTAssertEqual(Set(order), Set(view.editor.rangeCache.keys))

    // Canonical ordering is by (location asc, range.length desc).
    var lastLoc: Int?
    var lastLen: Int?
    for key in order {
      guard let item = view.editor.rangeCache[key] else {
        XCTFail("Missing rangeCache item for key \(key)")
        return
      }
      let loc = item.location
      let len = item.range.length
      if let lastLoc {
        XCTAssertGreaterThanOrEqual(loc, lastLoc)
        if loc == lastLoc, let lastLen {
          XCTAssertLessThanOrEqual(len, lastLen)
        }
      }
      lastLoc = loc
      lastLen = len
    }

    for (i, key) in order.enumerated() {
      XCTAssertEqual(indexOf[key], i + 1)
    }
  }
}
