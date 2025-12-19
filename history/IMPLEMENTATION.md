# Implementation Log (Lexical iOS)

## 2025-12-19
- lexical-ios-0qp (done): Added off-main text-only planning snapshot + materialization path, wired into central aggregation with state-id validation and planning timing.
- lexical-ios-8qy (done): Reverted off-main planning snapshot path (sync overhead) to keep text-only planning on main.
- lexical-ios-i8b (done): Switched decorator cache repair/sync to single-pass attachment maps; reuse lookup in decorator reconciliation.
- lexical-ios-6fw (done): Track dirty decorator positions and reposition only visible/dirty keys in LayoutManager (UIKit + AppKit).
- lexical-ios-5mc (done): Gate block-attribute pass for text-only aggregation using block-attribute diff checks.
- Tests: `xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace -scheme Lexical-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' test` (passed); `xcodebuild -project Playground/LexicalPlayground.xcodeproj -scheme LexicalPlayground -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' build` (passed); `swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -Xswiftc "-target" -Xswiftc "x86_64-apple-ios16.0-simulator"` (passed); `swift build --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -Xswiftc "-target" -Xswiftc "arm64-apple-ios16.0-simulator"` (passed).
