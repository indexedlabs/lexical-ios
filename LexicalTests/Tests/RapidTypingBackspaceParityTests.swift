/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import Lexical
import XCTest

#if os(macOS) && !targetEnvironment(macCatalyst)
@testable import LexicalAppKit
#endif

@MainActor
final class RapidTypingBackspaceParityTests: XCTestCase {

  private func makeViews() -> (opt: LexicalView, leg: LexicalView) {
    let cfg = EditorConfig(theme: Theme(), plugins: [])
    let opt = LexicalView(editorConfig: cfg, featureFlags: FeatureFlags.optimizedProfile(.aggressiveEditor))
    let leg = LexicalView(editorConfig: cfg, featureFlags: FeatureFlags())
    opt.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    leg.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
    return (opt, leg)
  }

  private func scenario_typeAndQuickBackspace(on v: LexicalView) throws -> String {
    let ed = v.editor
    print("🔥 RAPID TYPING: seed doc + insert paragraph + type 'word'")
    try ed.update {
      guard let root = getRoot() else { return }
      let p = createParagraphNode(); let t = createTextNode(text: "Hello.")
      try p.append([t]); try root.append([p])
      try t.select(anchorOffset: 6, focusOffset: 6)
      try (getSelection() as? RangeSelection)?.insertParagraph()
      try (getSelection() as? RangeSelection)?.insertText("word")
    }
    // Quick successive backspaces (simulate fast user input)
    print("🔥 RAPID TYPING: backspace 1/4")
    try ed.update { try (getSelection() as? RangeSelection)?.deleteCharacter(isBackwards: true) }
    print("🔥 RAPID TYPING: backspace 2/4")
    try ed.update { try (getSelection() as? RangeSelection)?.deleteCharacter(isBackwards: true) }
    print("🔥 RAPID TYPING: backspace 3/4")
    try ed.update { try (getSelection() as? RangeSelection)?.deleteCharacter(isBackwards: true) }
    print("🔥 RAPID TYPING: backspace 4/4")
    try ed.update { try (getSelection() as? RangeSelection)?.deleteCharacter(isBackwards: true) }
    return v.attributedText.string
  }

  func testParity_TypeThenQuickBackspaces_DeleteOneByOne() throws {
    let (opt, leg) = makeViews()
    XCTAssertEqual(try scenario_typeAndQuickBackspace(on: opt), try scenario_typeAndQuickBackspace(on: leg))
  }
}
