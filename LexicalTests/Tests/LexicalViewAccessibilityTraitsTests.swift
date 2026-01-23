#if canImport(UIKit)
import XCTest

@testable import Lexical

final class LexicalViewAccessibilityTraitsTests: XCTestCase {
  @MainActor
  func testLexicalViewDoesNotOverrideTextViewAccessibilityTraits() {
    let editorConfig = EditorConfig(theme: Theme(), plugins: [])
    let featureFlags = FeatureFlags()

    let baselineTextView = TextView(editorConfig: editorConfig, featureFlags: featureFlags)
    let lexicalView = LexicalView(editorConfig: editorConfig, featureFlags: featureFlags)

    XCTAssertEqual(lexicalView.textView.accessibilityTraits, baselineTextView.accessibilityTraits)
  }
}
#endif
