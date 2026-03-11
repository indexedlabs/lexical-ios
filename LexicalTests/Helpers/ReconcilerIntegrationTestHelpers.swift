#if !os(macOS) || targetEnvironment(macCatalyst)

import UIKit
import XCTest
@testable import Lexical

enum ReconcilerIntegrationProfile: String, CaseIterable {
  case baseline = "baseline"
  case strict = "strict"
  case sanityCheck = "sanity-check"
  case proxyInputDelegate = "proxy-input-delegate"
  case strictSanityCheck = "strict-sanity-check"

  static let environmentKey = "LEXICAL_RECONCILER_INTEGRATION_PROFILE"

  var featureFlags: FeatureFlags {
    switch self {
    case .baseline:
      return FeatureFlags()
    case .strict:
      return FeatureFlags(reconcilerStrictMode: true)
    case .sanityCheck:
      return FeatureFlags(reconcilerSanityCheck: true)
    case .proxyInputDelegate:
      return FeatureFlags(proxyTextViewInputDelegate: true)
    case .strictSanityCheck:
      return FeatureFlags(reconcilerSanityCheck: true, reconcilerStrictMode: true)
    }
  }

  static var active: ReconcilerIntegrationProfile {
    guard let rawValue = ProcessInfo.processInfo.environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawValue.isEmpty else {
      return .baseline
    }

    guard let profile = allCases.first(where: { $0.rawValue == rawValue.lowercased() }) else {
      let supported = allCases.map(\.rawValue).joined(separator: ", ")
      fatalError("Unknown \(environmentKey)=\(rawValue). Supported values: \(supported)")
    }

    return profile
  }
}

@MainActor
func createIntegrationTestEditorView(
  theme: Theme = Theme(),
  plugins: [Plugin] = [],
  placeholderText: LexicalPlaceholderText? = nil
) -> TestEditorView {
  createTestEditorView(
    theme: theme,
    plugins: plugins,
    featureFlags: ReconcilerIntegrationProfile.active.featureFlags,
    placeholderText: placeholderText
  )
}

@MainActor
final class ReconcilerIntegrationHarness {
  private unowned let testCase: XCTestCase
  private var window: UIWindow?

  let profile: ReconcilerIntegrationProfile

  init(testCase: XCTestCase, profile: ReconcilerIntegrationProfile = .active) {
    self.testCase = testCase
    self.profile = profile
  }

  func tearDown() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
  }

  func createTestView(
    theme: Theme = Theme(),
    plugins: [Plugin] = [],
    placeholderText: LexicalPlaceholderText? = nil,
    becomeFirstResponder: Bool = true
  ) -> TestEditorView {
    let view = createTestEditorView(
      theme: theme,
      plugins: plugins,
      featureFlags: profile.featureFlags,
      placeholderText: placeholderText
    )
    mount(view)
    if becomeFirstResponder {
      _ = view.view.textView.becomeFirstResponder()
    }
    return view
  }

  func drainMainQueue(timeout: TimeInterval = 2) {
    let exp = testCase.expectation(description: "drain main queue")
    DispatchQueue.main.async { exp.fulfill() }
    testCase.wait(for: [exp], timeout: timeout)
  }

  func syncSelection(_ textView: UITextView) {
    textView.delegate?.textViewDidChangeSelection?(textView)
  }

  func assertTextParity(
    _ editor: Editor,
    _ textView: UITextView,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    var lexical = ""
    try editor.read { lexical = getRoot()?.getTextContent() ?? "" }
    XCTAssertEqual(
      lexical,
      textView.text ?? "",
      "[\(profile.rawValue)] Native text diverged from Lexical",
      file: file,
      line: line
    )

    let selected = textView.selectedRange
    let length = (textView.text ?? "").lengthAsNSString()
    XCTAssertGreaterThanOrEqual(selected.location, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(selected.length, 0, file: file, line: line)
    XCTAssertLessThanOrEqual(selected.location, length, file: file, line: line)
    XCTAssertLessThanOrEqual(selected.location + selected.length, length, file: file, line: line)
  }

  func assertSelectionRoundTrips(
    _ editor: Editor,
    _ textView: UITextView,
    file: StaticString = #file,
    line: UInt = #line
  ) throws {
    try editor.read {
      guard let selection = try getSelection() as? RangeSelection else {
        XCTFail("Expected RangeSelection", file: file, line: line)
        return
      }
      let native = try createNativeSelection(from: selection, editor: editor)
      XCTAssertEqual(
        native.range,
        textView.selectedRange,
        "[\(profile.rawValue)] Selection did not round-trip",
        file: file,
        line: line
      )
      if textView.selectedRange.length == 0 {
        XCTAssertTrue(
          selection.isCollapsed(),
          "[\(profile.rawValue)] Lexical selection should be collapsed when native range is collapsed",
          file: file,
          line: line
        )
      }
    }
  }

  func makeUniquePasteboard() -> (pasteboard: UIPasteboard, name: UIPasteboard.Name)? {
    let name = UIPasteboard.Name("lexical-tests-\(UUID().uuidString)")
    guard let pasteboard = UIPasteboard(name: name, create: true) else { return nil }
    pasteboard.items = []
    return (pasteboard, name)
  }

  private func mount(_ view: TestEditorView) {
    window?.isHidden = true
    window?.rootViewController = nil

    let newWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let root = UIViewController()
    newWindow.rootViewController = root
    newWindow.makeKeyAndVisible()

    root.view.addSubview(view.view)
    view.view.frame = newWindow.bounds
    view.view.layoutIfNeeded()

    window = newWindow
  }
}

#endif
