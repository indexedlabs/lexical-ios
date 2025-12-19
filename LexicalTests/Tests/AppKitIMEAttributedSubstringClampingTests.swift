/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(macOS) && !targetEnvironment(macCatalyst)

import AppKit
@testable import Lexical
@testable import LexicalAppKit
import XCTest

@MainActor
final class AppKitIMEAttributedSubstringClampingTests: XCTestCase {

  func testAttributedSubstringForProposedRange_ClampsOutOfBounds() {
    let view = LexicalView(editorConfig: .init(theme: .init(), plugins: []), featureFlags: .init())
    let textView = view.textView

    textView.string = "Hello"

    var actual = NSRange(location: NSNotFound, length: 0)
    let result = textView.attributedSubstring(
      forProposedRange: NSRange(location: 10_000, length: 50),
      actualRange: &actual
    )

    XCTAssertNotNil(result)
    XCTAssertEqual(result?.string, "")
    XCTAssertEqual(actual.location, 5)
    XCTAssertEqual(actual.length, 0)
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
