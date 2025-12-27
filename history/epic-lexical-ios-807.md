## 0. Context snapshot
- Repo/branch: lexical-ios (mh/more-perf)
- Commit SHA: d1f5cc9
- Related issues:
  - lexical-ios-k5i (closed): get all tests passing post RopeReconciler migration
  - lexical-ios-ihl (in_progress): large paste + large doc responsiveness (docs/PerformanceNextSteps.md)
  - lexical-ios-47f (open): optimize text content listeners
  - lexical-ios-ihl.6 (open): add 2k+ line paste benchmark/regression coverage
- Key commands used to inspect/validate:
  - rg "RopeReconciler" Lexical/Core
  - xcodebuild -workspace Playground/LexicalPlayground.xcodeproj/project.xcworkspace -scheme Lexical-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' test

## 1. Summary
RopeReconciler is now the primary reconciler for iOS/macOS, but several update paths still have large-document sensitive work (O(N) text extraction for listeners, DFS ordering rebuilds on invalidation, and marked-text paths that materialize/shift absolute locations). This epic tracks the “phase 2” performance and robustness work to keep edits/pastes/selection changes bounded (O(log N) / O(K)) and to harden regression coverage so we can continue iterating safely.

## 2. Goals / Non-goals

### Goals
- Keep common edits (typing, enter/backspace, selection moves) sub-linear on large documents (avoid per-edit O(N) scans/rebuilds).
- Avoid full-document TextStorage rebuilds except for explicit full-reconcile paths (setEditorState, hydration).
- Make expensive operations measurable + regression-tested (large paste, repeated edits, selection mapping).

### Non-goals
- Delete large swaths of legacy reconciler code (file deletion requires explicit approval).
- Introduce platform-specific behavior changes that risk parity with the existing test suite.

## 3. Existing code analysis

### Current behavior (high level)
- `Editor.update` drives reconciliation via `RopeReconciler.updateEditorState(...)`.
- `RopeReconciler.reconcileInternal`:
  - Fast paths for: marked text (composition), fullReconcile, fresh hydration, selection-only.
  - Otherwise categorizes dirty nodes into insert/remove/update.
  - Uses Fenwick-backed “lazy” location shifts for text-only updates (no insert/remove, TextNode-only updates) and materializes Fenwick deltas before structural reconciles.
  - Applies TextStorage edits in a single beginEditing/endEditing batch.

### Key files / entry points
- `Lexical/Core/RopeReconciler.swift`: incremental reconcile, bulk insert runs, text-only Fenwick lazy locations, full/hydration rebuilds.
- `Lexical/Core/Editor.swift`: DFS order cache + Fenwick plumbing (`cachedDFSOrderAndIndex`, `ensureFenwickCapacity`, `actualRange` helpers).
- `Lexical/TextKit/RangeCache.swift`: selection mapping (`pointAtStringLocation`, `evaluateNode`) and fenwick-aware location helpers.
- `LexicalTests/Tests/LargePasteCursorMovementTests.swift`: large paste + large doc regressions (memory/time/caret behavior).

### Remaining hotspots / risks
- Text content listeners: `triggerTextContentListeners` still does O(N) text extraction when listeners are registered.
- Marked text (composition): marked text reconciliation currently uses legacy absolute locations and may force Fenwick materialization.
- DFS order invalidation/rebuild: structural changes invalidate DFS cache and can still incur full ordering work.

## 4. Technical design

### Design direction
- Prefer incremental, localized work:
  - Only compute expensive derived data when the feature is actually used (e.g. text content listeners).
  - Keep location maintenance lazy whenever possible, and avoid forced materialization on common paths.

### Key technical decisions
- Keep RopeReconciler as the single reconciler used by Editor; improvements should land there first.
- Treat perf work as “regression-driven”: add/extend tests before/alongside optimizations.

## 5. Implementation plan (sequenced, no timelines)

### Proposed subtasks (bd child issues)
1. Optimize text content listeners (type: task, P2)
   - Primary files: `Lexical/Core/Editor.swift` (listener dispatch), `Lexical/Core/EditorState.swift` (optional caching)
2. Reduce marked-text (composition) cost with Fenwick-lazy locations (type: task, P1)
   - Primary files: `Lexical/Core/RopeReconciler.swift`, selection mapping helpers
3. Add 2k+ line paste benchmark/regression coverage (type: task, P2)
   - Primary files: `LexicalTests/Tests/LargePasteCursorMovementTests.swift`, `scripts/benchmarks.py`

### Rollout & validation
- Validation gate for each subtask:
  - `xcodebuild` full iOS simulator tests (skip benchmarks) + Playground build.
- For perf-oriented changes, record baseline/after with the existing harness in `docs/PerformanceBenchmarks.md`.

### Testing plan
- Unit tests:
  - Extend large-paste and large-doc tests (memory/time bounds, caret mapping invariants).
- Manual verification:
  - Run Playground, paste large content, and verify caret/scroll responsiveness.

## 6. Open questions
- Can marked-text reconciliation be updated to use the same Fenwick-lazy strategy as text-only edits without compromising TextKit IME behavior?
- Do we want to keep OptimizedReconciler as a reference implementation long-term, or gate it behind build flags?

## 7. Links / references
- `docs/PerformanceNextSteps.md`
- `docs/PerformanceBenchmarks.md`
