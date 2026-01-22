#if !os(macOS) || targetEnvironment(macCatalyst)

@testable import Lexical
import XCTest

final class TextViewAccessibilityActivateTests: XCTestCase {
  @MainActor
  func testAccessibilityActivateBecomesFirstResponder() throws {
    let lexicalView = LexicalView(
      editorConfig: EditorConfig(theme: Theme(), plugins: []),
      featureFlags: FeatureFlags()
    )
    let textView = lexicalView.textView

    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UIViewController()
    window.rootViewController?.view.addSubview(lexicalView)
    lexicalView.frame = window.bounds
    window.makeKeyAndVisible()

    if textView.isFirstResponder {
      _ = textView.resignFirstResponder()
    }
    XCTAssertFalse(textView.isFirstResponder)

    _ = textView.accessibilityActivate()

    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertTrue(textView.isFirstResponder)
  }
}

#endif

