# Performance Next Steps (Large Paste + Large Documents)

This doc captures the next set of concrete performance improvements for Lexical iOS, focused on:

- Pasting 2k+ lines (currently can cause massive transient memory spikes).
- Cursor movement + edits on large documents (currently noticeably laggy).

It’s written against the current codebase (Dec 2025) and calls out the specific hotspots + strategies to address them.

## Current behavior (what the code does today)

### Paste pipeline (UIKit)

- `TextView.paste(_:)` dispatches `.paste` with a `UIPasteboard` (`Lexical/TextView/TextView.swift`).
- Paste handling prefers Lexical-serialized nodes if present; otherwise:
  - For “very large pastes”, it prefers **plain text** over RTF (`Lexical/Helper/CopyPasteHelpers.swift`).
  - Plain text paste is split by paragraphs and inserted as `[TextNode]` + `[ParagraphNode]` (`Lexical/Helper/CopyPasteHelpersCommon.swift`).
- The subsequent UI update happens via the optimized reconciler (`Lexical/Core/OptimizedReconciler.swift`).

### RangeCache + selection mapping

- Native selection changes call `onSelectionChange(editor:)`, which converts native offsets to Lexical points using:
  - `pointAtStringLocation` → `evaluateNode` (`Lexical/TextKit/RangeCache.swift`).
- `evaluateNode` currently scans element children **linearly** until it finds a child whose cached range contains the location.

### “Fenwick tree” today (what it is vs what it isn’t)

We currently use a Fenwick tree for *some* range-cache maintenance tasks, but we still store **absolute `RangeCacheItem.location`** and frequently “shift” locations.

Important consequence: many edits still trigger O(N) work across the range cache because “shifting absolute locations” implies touching a large suffix of nodes.

Examples to look at:

- Absolute-location shifting is currently implemented as a prefix-diff scan over the cached DFS order:
  - `applyIncrementalLocationShifts` (`Lexical/Helper/RangeCacheIncremental.swift`).
- `Editor.cachedDFSOrderAndIndex()` currently computes the DFS/location order by **sorting** the range cache:
  - `sortedNodeKeysByLocation` (`Lexical/Helper/RangeCacheIndexing.swift`)
  - used from `Lexical/Core/Editor.swift`.

## Working hypotheses (root causes)

### 1) Large paste memory spikes

The biggest risk factor is falling back to a *full rebuild* of the TextStorage when fast paths don’t match:

- `OptimizedReconciler.optimizedSlowPath` rebuilds the *entire* attributed string for the document and replaces `[0, length)` (`Lexical/Core/OptimizedReconciler.swift`).
- Large multi-paragraph inserts (pastes) frequently do not match “single-block insert” fast paths, so they are more likely to hit this fallback.

Full rebuild is expensive in both CPU and memory because it:

- Allocates a large `NSMutableAttributedString` for the entire document.
- Appends many small attributed fragments (potentially leading to repeated growth/copies).
- Runs `fixAttributes` across the full rebuilt range.
- Applies block-level attributes across many nodes (often “treat all dirty”).

### 2) Cursor movement + edits feel laggy on large docs

There are two likely algorithmic hot spots that remain large-document sensitive:

1) **Selection mapping is still O(#children scanned)**:
   - `pointAtStringLocation` → `evaluateNode` does a linear scan of children at each element level (`Lexical/TextKit/RangeCache.swift`).
   - For a root with thousands of block children, this can be expensive per selection change.

2) **Per-edit range-cache maintenance still tends to be O(N)**:
   - With absolute cached locations, a single-character insertion near the top of a large doc can shift the locations for “almost everything after it”.
   - Today that’s implemented as a full pass over the cached order (`Lexical/Helper/RangeCacheIncremental.swift`), plus potential re-sorting (`Lexical/Core/Editor.swift`).

## Goals (what “good” looks like)

These should be validated with the existing perf harness (`docs/PerformanceBenchmarks.md`) + targeted regression tests.

- Large paste (2k+ lines):
  - Peak memory delta should be bounded and proportional (avoid multi-GB blowups).
  - Wall time should scale roughly linearly with inserted content.
- Cursor moves (tap / arrow keys) on large docs:
  - Avoid O(N) editor reconciliation and avoid O(N) selection mapping.
  - Keep “caret move” under a perceptible threshold (target: <50ms; stricter if possible).
- Live edits (typing / backspace) on large docs:
  - Avoid per-keystroke full-range-cache scans and full TextStorage rebuilds.

## Proposed improvements (prioritized)

### A) Stop using full-rebuild slow path for large multi-block inserts (pastes)

Add a new optimized reconciler fast path for **multi-block insert** (K new direct children under the same parent, contiguous insertion):

- Detect: one parent element where `nextChildren.count == prevChildren.count + K` (K ≥ 2), no removals, and inserted keys are new/attached.
- Apply: a single TextStorage `.insert` for the entire inserted subtree:
  - Build one attributed string for *just the inserted content* (not the whole document).
  - Insert at the computed insertion location (from the parent’s + sibling range cache).
- Update RangeCache:
  - Recompute cache entries for the inserted subtree at the insertion start.
  - Apply a single location-shift for subsequent nodes.
- Block attributes:
  - Apply block-level attributes only for inserted blocks + immediate neighbors (boundary postamble/preamble effects).
- Decorators:
  - Reconcile decorators only within the inserted subtree (and neighbors if needed).

Why this helps:

- Avoids building a full-document attributed string during paste.
- Keeps memory bounded to “inserted content + modest overhead”.

### B) Make selection mapping sub-linear (fix `pointAtStringLocation`)

Replace linear child scanning in `evaluateNode` with a **binary search** over child ranges:

- Children in an element are in document order; their cached ranges should be monotonic and non-overlapping.
- Use `rangeCache[childKey].location` and `entireRange()` to binary search for the containing child.
- Preserve existing tie-breaking via `searchDirection` for boundary locations.

Why this helps:

- Cursor movement cost goes from O(#siblings) to O(log #siblings) at each element level.
- Root-level lookups on 2k+ paragraphs become cheap.

### C) Remove O(N) “shift all absolute locations” work (finish Fenwick integration)

This is the bigger structural improvement that likely matters most for *live typing* in large docs.

Right now we still store absolute `RangeCacheItem.location` and frequently shift locations across a large suffix. The intended Fenwick-tree approach can eliminate this by making locations **lazy**:

- Store “base location” (or a stable location snapshot) in `RangeCacheItem`.
- Maintain an editor-level Fenwick tree of deltas that represent the cumulative shifts for nodes after edits.
- Compute `locationFromFenwick()` and `rangeFromFenwick()` on demand using prefix sums, instead of eagerly updating every node’s `location`.

Key design points:

- The Fenwick index must reflect stable document order (DFS order) and only be rebuilt on structural changes (insert/delete/reorder), not on every text edit.
- Most operations only need accurate locations for:
  - dirty nodes
  - their ancestors
  - selection anchor/focus paths
  - immediate neighbors for boundary fixes

Why this helps:

- Converts “type one character” from O(N) suffix shifting into:
  - O(log N) to update the Fenwick tree, plus
  - O(log N) queries only for nodes actually touched by the update.

### D) Speed up DFS order/index cache maintenance

Even without full Fenwick-lazy locations, we can reduce overhead:

- In `Editor.cachedDFSOrderAndIndex()` (`Lexical/Core/Editor.swift`), try `nodeKeysByTreeDFSOrder(state:rangeCache:)` (`Lexical/Helper/RangeCacheIndexing.swift`) first.
  - This gives O(N) ordering via tree traversal.
  - Fall back to sorting only when the validation fails.

Why this helps:

- Sorting the entire range cache for every invalidation becomes avoidable in the common case.

### E) Tighten “dirty surface area” on updates

Make sure we don’t accidentally do “treat all nodes as dirty” work when we only changed a small region:

- Prefer “affected keys” sets over `treatAllNodesAsDirty: true` wherever parity permits.
- Ensure block-attribute passes + decorator reconciliation are limited to the edited region and necessary neighbors.

This is most useful after A/B/C, but still worth auditing.

## Measurement plan

- Use `docs/PerformanceBenchmarks.md` + `scripts/benchmarks.py record` to capture baseline/after comparisons.
- Extend/adjust existing large-paste tests to cover:
  - 2k+ line paste (or a generated stress document) and assert peak deltas stay bounded.
  - caret move + selection mapping costs at start/middle/end on large docs.

Existing relevant tests:

- `LexicalTests/Tests/LargePasteCursorMovementTests.swift`
- `LexicalTests/Tests/*BenchmarkTests.swift` (see `docs/PerformanceBenchmarks.md`)

## Proposed tracking (bd)

bd epic:

- `lexical-ios-ihl` — Performance: large paste + large document responsiveness

Subtasks:

- `lexical-ios-ihl.2` — Optimized reconciler: multi-block insert fast path (paste)
- `lexical-ios-ihl.3` — RangeCache: binary-search selection mapping (pointAtStringLocation)
- `lexical-ios-ihl.4` — Editor: speed up dfsOrderCache (tree DFS order before sort)
- `lexical-ios-ihl.5` — RangeCache: Fenwick-backed lazy absolute locations
- `lexical-ios-ihl.6` — Perf: add 2k+ line paste benchmark/regression coverage

(This doc intentionally avoids checklists; bd should be the source of truth for task state.)
