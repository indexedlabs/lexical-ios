## Objective
Marked-text (IME composition) updates should not force full Fenwick materialization / O(N) range-cache shifts on large documents. Composition should remain correct (selection + text content) and should not regress large-document responsiveness.

## Context (existing code pointers)
- Primary entry point(s): `Lexical/Core/RopeReconciler.swift` (`reconcileInternal`, `handleComposition`, `materializeFenwickLocations`)
- Related patterns to follow:
  - Text-only Fenwick-lazy path in `RopeReconciler.reconcileInternal` (text-only updates)
  - Selection ↔︎ string mapping that already accepts an optional Fenwick tree (`Lexical/TextKit/RangeCache.swift`, `Lexical/Core/Selection/SelectionUtils.swift`)
- Gotchas / constraints:
  - Marked text interacts with UIKit/TextKit editing state; must preserve correctness.
  - Current implementation materializes Fenwick deltas before marked text to keep absolute locations aligned.

## Scope

### In scope
- Add/extend regression coverage for marked text after large paste / large doc.
- Update RopeReconciler composition path to avoid full Fenwick materialization when safe.
- Ensure range cache + selection mapping remain correct under composition.

### Out of scope
- Removing marked text support or changing public marked-text APIs.
- Rewriting TextKit integration.

## Implementation notes
- Files to change (expected):
  - `Lexical/Core/RopeReconciler.swift`
  - `Lexical/Core/Editor.swift` (if additional helpers needed)
  - `Lexical/TextKit/RangeCache.swift` / selection utilities (only if needed)
  - `LexicalTests/Tests/MarkedTextEditorStateIntegrationTests.swift` (or a new targeted regression in LargePasteCursorMovementTests)
- Steps:
  1. Add a regression test that:
     - builds a large document (e.g. paste sample.md multiple times)
     - enters a marked-text operation and commits it
     - asserts textStorage/selection correctness (and optionally basic time bounds)
  2. Change RopeReconciler to compute the affected marked-text range using Fenwick-aware locations (or localized materialization), rather than materializing all pending Fenwick deltas.
  3. Verify that composition + commit keeps TextStorage and rangeCache consistent.

## Deliverables
- Code changes: Fenwick-friendly marked text path (or localized materialization) in RopeReconciler.
- Tests: new/updated marked-text regression covering large-doc scenario.

## Acceptance criteria
- No full-suite failures.
- New regression test passes reliably on iOS simulator.
- Marked-text path no longer requires full Fenwick materialization in the common case.

## Testing / verification
- Commands to run:
  - `xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace -scheme Lexical-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' -only-testing:LexicalTests/MarkedTextEditorStateIntegrationTests test`
  - `xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace -scheme Lexical-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' -skip-testing:LexicalTests/RopeChunkIterationTests -skip-testing:LexicalTests/RopeTextStoragePerformanceTests -skip-testing:LexicalTests/ReconcilerBenchmarkTests -skip-testing:LexicalTests/MixedDocumentLiveBenchmarkTests -skip-testing:LexicalTests/MixedDocumentBenchmarkTests -skip-testing:LexicalTests/InsertBenchmarkTests -skip-testing:LexicalTests/DFSOrderIndexingBenchmarkTests test`
  - Playground build: `xcodebuild -project Playground/LexicalPlayground.xcodeproj -scheme LexicalPlayground -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' build`
