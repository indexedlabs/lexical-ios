## Lexical iOS: From UITextView input to EditorState updates (RangeCache + Reconciler)

This document explains how user input in `UITextView` flows through Lexical iOS to update `EditorState`, focusing on `RangeCache.swift` and `Reconciler.swift`. It also highlights where a `LoroDoc`-backed tree (with `LoroText` leaves) could replace reconciliation.

### High-level pipeline

- **UITextView event**: User types; `TextView.insertText(_:)` is called and dispatches a Lexical command.
- **Command handling**: `onInsertTextFromUITextView` runs inside an editor update, normalizing selection and invoking selection-driven mutations.
- **Editor update**: `Editor.beginUpdate` executes the mutation, then calls `Reconciler.updateEditorState` (unless headless), which diffs prev vs pending `EditorState` and applies minimal changes to `TextStorage`.
- **RangeCache**: Provides fast mapping between string indices and node positions, and enables precise range edits. It’s also used to map native selections to Lexical `Point`s.
- **Selection sync**: Native selection is kept in sync with Lexical selection; marked text (IME composition) is handled with a special flow.

### Key call sites (controlled mode)

1) UIText input enters Lexical via `TextView.insertText`, which dispatches `.insertText`:

```247:271:lexical-ios/Lexical/TextView/TextView.swift
override public func insertText(_ text: String) {
  ...
  editor.dispatchCommand(type: .insertText, payload: text)
  ...
}
```

2) Command handler routes to `onInsertTextFromUITextView`, which normalizes marked text and inserts via the selection:

```15:21:lexical-ios/Lexical/Core/Events.swift
@MainActor
internal func onInsertTextFromUITextView(
  text: String, editor: Editor,
  updateMode: UpdateBehaviourModificationMode = UpdateBehaviourModificationMode()
) throws {
  try editor.updateWithCustomBehaviour(mode: updateMode, reason: .update) {
```

```42:55:lexical-ios/Lexical/Core/Events.swift
    if text == "\n" || text == "\u{2029}" {
      try selection.insertParagraph()
      ...
    } else if text == "\u{2028}" {
      try selection.insertLineBreak(selectStart: false)
    } else {
      try selection.insertText(text)
    }
```

3) Selection-driven text insertion performs the model mutation on text nodes (split/splice/merge, etc.):

```281:306:lexical-ios/Lexical/Core/Selection/RangeSelection.swift
@MainActor
public func insertText(_ text: String) throws {
  ... // normalize start/end points; ensure insertable target
  guard var firstNode = selectedNodes.first as? TextNode else {
    throw LexicalError.invariantViolation("insertText: first node is not a text node")
  }
  ...
}
```

```439:447:lexical-ios/Lexical/Core/Selection/RangeSelection.swift
firstNode = try firstNode.spliceText(
  offset: startOffset, delCount: delCount, newText: text, moveSelection: true)
if firstNode.getTextPart().lengthAsNSString() == 0 {
  try firstNode.remove()
} else if self.anchor.type == .text {
  ...
}
```

4) After the mutation closure, `Editor.beginUpdate` calls the reconciler to apply minimal diffs to `TextStorage`:

```751:756:lexical-ios/Lexical/Core/Editor.swift
if !headless {
  try Reconciler.updateEditorState(
    currentEditorState: editorState, pendingEditorState: pendingEditorState, editor: self,
    shouldReconcileSelection: !mode.suppressReconcilingSelection,
    markedTextOperation: mode.markedTextOperation)
}
```

### Reconciler: how diffs are applied to TextStorage

The reconciler compares the previous vs pending `EditorState` and computes three segments for each node: preamble, children, and text, plus a postamble. It uses the previous `RangeCache` to locate existing content and schedules deletions/insertions accordingly.

5) Reconciler state setup and entry:

```111:122:lexical-ios/Lexical/Core/Reconciler.swift
let reconcilerState = ReconcilerState(
  currentEditorState: currentEditorState,
  pendingEditorState: pendingEditorState,
  rangeCache: editor.rangeCache,
  dirtyNodes: editor.dirtyNodes,
  treatAllNodesAsDirty: editor.dirtyType == .fullReconcile,
  markedTextOperation: markedTextOperation)

try reconcileNode(key: kRootNodeKey, reconcilerState: reconcilerState)
```

6) For each node, compute changes for preamble/text/postamble using the previous cache, scheduling deletions/additions, while updating the cursor and next cache:

```307:345:lexical-ios/Lexical/Core/Reconciler.swift
guard let prevRange = reconcilerState.prevRangeCache[key] else {
  throw LexicalError.invariantViolation("Node map entry for '\(key)' not found")
}
...
let nextPreambleLength = nextNode.getPreamble().lengthAsNSString()
createAddRemoveRanges(
  key: key,
  prevLocation: prevRange.location,
  prevLength: prevRange.preambleLength,
  nextLength: nextPreambleLength,
  reconcilerState: reconcilerState,
  part: .preamble)
```

```363:373:lexical-ios/Lexical/Core/Reconciler.swift
let nextTextLength = nextNode.getTextPart().lengthAsNSString()
createAddRemoveRanges(
  key: key,
  prevLocation: prevRange.location + prevRange.preambleLength + prevRange.childrenLength,
  prevLength: prevRange.textLength,
  nextLength: nextTextLength,
  reconcilerState: reconcilerState,
  part: .text)
```

```389:408:lexical-ios/Lexical/Core/Reconciler.swift
private static func createAddRemoveRanges(...){
  if prevLength > 0 { rangesToDelete.append(NSRange(location: prevLocation, length: prevLength)) }
  if nextLength > 0 { rangesToAdd.append(ReconcilerInsertion(location: locationCursor, nodeKey: key, part: part)) }
  locationCursor += nextLength
}
```

7) Batched application to `TextStorage` is executed in one editing session, with attribute fixups and decorator updates:

```125:146:lexical-ios/Lexical/Core/Reconciler.swift
let previousMode = textStorage.mode
textStorage.mode = .controllerMode
textStorage.beginEditing()
...
for deletionRange in reconcilerState.rangesToDelete.reversed() { textStorage.deleteCharacters(in: deletionRange) }
...
for insertion in reconcilerState.rangesToAdd { textStorage.insert(attributedString, at: insertion.location) }
...
textStorage.endEditing()
textStorage.mode = previousMode
```

### RangeCache: purpose and core APIs

- **What it stores**: For each node key, the starting location and segment lengths. This enables mapping between the flattened `NSAttributedString` and the tree.

```16:30:lexical-ios/Lexical/TextKit/RangeCache.swift
struct RangeCacheItem {
  var location: Int = 0
  var preambleLength: Int = 0
  var preambleSpecialCharacterLength: Int = 0
  var childrenLength: Int = 0
  var textLength: Int = 0
  var postambleLength: Int = 0
  var range: NSRange { NSRange(location: location, length: preambleLength + childrenLength + textLength + postambleLength) }
}
```

- **Mapping positions**: `pointAtStringLocation` traverses nodes using the cache to resolve a native string index into a `Point` in the tree (used for selection sync and caret positioning):

```46:66:lexical-ios/Lexical/TextKit/RangeCache.swift
@MainActor
internal func pointAtStringLocation(
  _ location: Int, searchDirection: UITextStorageDirection, rangeCache: [NodeKey: RangeCacheItem]
) throws -> Point? { ... }
```

- **Non-controlled updates**: When native mutations occur directly, update text lengths and shift downstream locations incrementally:

```220:236:lexical-ios/Lexical/TextKit/RangeCache.swift
@MainActor
internal func updateRangeCacheForTextChange(nodeKey: NodeKey, delta: Int) {
  ...
  editor.rangeCache[nodeKey]?.textLength = node.getTextPart().lengthAsNSString()
  ...
  updateNodeLocationFor(nodeKey: kRootNodeKey, nodeIsAfterChangedNode: false, changedNodeKey: nodeKey, changedNodeParents: parentKeys, delta: delta)
}
```

### Non-controlled mode (UIKit mutates TextStorage first)

- `TextStorage.replaceCharacters` with `mode == .none` routes to `performControllerModeUpdate`, which replays the change into Lexical and positions the selection:

```53:71:lexical-ios/Lexical/TextKit/TextStorage.swift
override open func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
  if mode == .none {
    ...
    performControllerModeUpdate(attrString.string, range: range)
  }
  return
}
```

```96:137:lexical-ios/Lexical/TextKit/TextStorage.swift
private func performControllerModeUpdate(_ str: String, range: NSRange) {
  mode = .controllerMode
  defer { mode = .none }
  ...
  try editor.update {
    ...
    try selection.applyNativeSelection(nativeSelection)
    try selection.insertText(str)
  }
  ...
  frontend.interceptNextSelectionChangeAndReplaceWithRange = updatedNativeSelection.range
}
```

- For small direct mutations, `handleTextMutation` updates the `TextNode` text, bumps `RangeCache`, and reapplies styles:

```25:33:lexical-ios/Lexical/Core/Mutations.swift
@MainActor
internal func handleTextMutation(textStorage: TextStorage, rangeOfChange: NSRange, lengthDelta: Int) throws {
  ...
}
```

```71:81:lexical-ios/Lexical/Core/Mutations.swift
updateRangeCacheForTextChange(nodeKey: nodeKey, delta: lengthDelta)
...
textStorage.setAttributes(styles, range: newRange)
```

### Marked text (IME composition)

- Start/update composition in `TextView.setMarkedTextInternal`, passing a `MarkedTextOperation` that suppresses selection reconciliation during composition:

```310:338:lexical-ios/Lexical/TextView/TextView.swift
let markedTextOperation = MarkedTextOperation(
  createMarkedText: true,
  selectionRangeToReplace: editor.getNativeSelection().markedRange ?? self.selectedRange,
  markedTextString: markedText,
  markedTextInternalSelection: selectedRange)
...
try onInsertTextFromUITextView(text: markedText, editor: editor, updateMode: behaviourModificationMode)
```

- Reconciler then positions and replaces the composed range via native marked text APIs, ensuring the keyboard’s internal state remains consistent:

```261:283:lexical-ios/Lexical/Core/Reconciler.swift
if let markedTextOperation, markedTextOperation.createMarkedText, let markedTextAttributedString, let startPoint = markedTextPointForAddition, let frontend = editor.frontend {
  ...
  try frontend.updateNativeSelection(from: RangeSelection(anchor: startPoint, focus: endPoint, format: TextFormat()))
  ...
  editor.frontend?.setMarkedTextFromReconciler(attributedSubstring, selectedRange: markedTextOperation.markedTextInternalSelection)
  return
}
```

### Where a Loro-backed tree would integrate

- **EditorState ownership (decision)**: Keep the `EditorState` type and embed a `LoroDoc` inside `EditorState`, making the Loro document the single source of truth. The Lexical node map becomes a projection used for serialization, theming, and decorators. `EditorState.init` constructs the `LoroDoc` and wiring; `toJSON` and `fromJSON` operate on the `LoroDoc`.
- **Reconciler replacement**: Swap `Reconciler.updateEditorState` (call site in `Editor.beginUpdate`) with a bridge that materializes diffs from the Loro movable tree rooted at `root` (with `LoroText` leaves) directly into `TextStorage`.
- **Position mapping**: Replace or back the `RangeCache` with a Loro position index that maps between (nodeKey, offsets) and UTF-16 indices, providing equivalents of `pointAtStringLocation` and incremental updates (`updateRangeCacheForTextChange`).
- **Selection sync**: Update `RangeSelection.applyNativeSelection` and related selection logic to resolve `NSRange` ↔ Loro positions.
- **Non-controlled mode**: Ensure `performControllerModeUpdate` and `handleTextMutation` write through to Loro first (or keep Lexical nodes as a projection of the Loro doc) and maintain the position mapping coherently.

This preserves the external `TextView`/command/selection API while using Loro as the source of truth for the tree and text content.



### State ownership and threading model

- **Move `EditorState` off the main actor**: `EditorState` will no longer be `@MainActor`. Background threads can import remote updates, parse/serialize JSON, run migrations, and update the Loro document and position index.
- **Main-thread boundaries (UI sinks only)**:
  - `TextStorage` mutations (`beginEditing`/`endEditing`, `deleteCharacters`, `insert`) must occur on the main thread.
  - UIKit interactions (`UITextView`, selection updates via `FrontendProtocol`) remain on the main thread.
  - Decorator view layout/relayout stays on main.
- **Bridge responsibilities**:
  - `LoroBridge` accepts remote ops and JSON imports off-main and coalesces them.
  - A main-thread drain, e.g. `flushPendingOpsToTextStorage()`, applies a minimal diff to `TextStorage` in one `.controllerMode` edit block.
  - Provide APIs like `applyRemoteOps(_:)`, `importJSON(_:)`, and `exportJSON()` that are safe off-main; only the UI application step hops to main.
- **Ownership decision**:
  - We will keep `EditorState` and embed a `LoroDoc` inside it. `EditorState` becomes Sendable and not main-isolated.
  - Initialization: `EditorState.init` (and convenience inits) instantiate `LoroDoc`, subscribe to ops, and set up the position index.
  - Serialization: `EditorState.toJSON` exports from the `LoroDoc`; `EditorState.fromJSON` builds the `LoroDoc` from JSON off-main, then swaps in on main for UI application.
- **Compatibility**: Existing `Editor` APIs (`update`, commands, selection) remain, but their implementations will delegate to the bridge. Serialization/migration and reconciliation responsibilities move to the bridge and index.


### Loro-backed runtime: replace the reconciler with an op-based bridge

- **Goal**: Keep Lexical’s node DX (e.g., `ListNode`) but remove the slow `Reconciler` diff. Use a Loro movable tree with `LoroText` leaves as the single source of truth and apply minimal diffs directly to `TextStorage`.
- **Core pieces**:
  - **Loro tree**: Nodes mirror Lexical structure; leaves are `LoroText` for content.
  - **Position index (RangeCache replacement)**: Maps between UTF-16 indices and `(nodeKey, part, offset)` and maintains `location`, `preambleLength`, `childrenLength`, `textLength`, `postambleLength` per node. Updates incrementally from Loro ops.
  - **Op bridge**: Subscribes to Loro ops, coalesces them, and applies batched `deleteCharacters`/`insert` to `TextStorage` inside a single `.controllerMode` edit block, then fixes attributes.
  - **Selection mapping**: NSRange ↔ Loro positions using the position index, replacing `pointAtStringLocation`.
  - **Import/Export**: Parse Lexical JSON → Loro tree and Loro tree → Lexical JSON.

#### Mapping UITextView edits to Loro ops

When `UITextView` calls `replaceCharacters(in:with:)` with `mode == .none` (native-first):

- Resolve NSRange endpoints using the position index:
  - `start = index.resolve(location: range.location, direction: .forward)`
  - `end = index.resolve(location: range.location + range.length, direction: .backward)`
- Build Loro ops:
  - Same-node edit: delete `(end.offset - start.offset)` at `start.offset` in that leaf’s `LoroText`, then insert the replacement (if non-empty).
  - Cross-node edit: delete the tail of the start leaf, delete full covered leaves, delete the head of the end leaf, apply structural merges as per Lexical semantics, then insert the replacement at the resulting position.
- Apply ops off the main thread; the main-thread subscriber receives coalesced ops and applies a minimal diff to `TextStorage` in `.controllerMode` with one `beginEditing`/`endEditing`, then runs attribute fixups.
- Avoid loops by guarding the TextStorage sink with an “applyingFromLoro” flag.

IME composition: treat marked-text updates as flagged edits that replace a known range; suppress selection reconciliation while composing, mirroring current behavior.

#### Minimal APIs for the bridge and index

- Position index:
  - `resolve(location: Int, direction: UITextStorageDirection) -> (nodeKey, part, offset)`
  - `map(range: NSRange) -> [(nodeKey, part, localStart, localEnd)]`
  - `applyDelta(nodeKey: NodeKey, delta: Int, changedPart: .text)`
- Bridge:
  - `applyNativeReplace(range: NSRange, replacement: String)` → builds Loro ops from a native edit
  - `onLoroOps(ops) -> TextStorageDiff` → coalesce ops and apply to `TextStorage` in one edit block

#### Phased implementation plan

1) Scaffolding
   - Add `LoroBridge` (holds Loro doc, position index, subscriptions).
   - Embed `LoroDoc` into `EditorState`; make the Loro document the single source of truth. Initialize `LoroDoc` in `EditorState.init` and wire subscriptions.
   - Update `EditorState.toJSON`/`fromJSON` to export/import via `LoroDoc`.
   - Remove `@MainActor` from `EditorState` and define strict main-thread boundaries for UI sinks (`TextStorage`, `UITextView`, selection/Frontend).

2) Position index (read-only integration)
   - Implement index data model with `RangeCacheItem`-like fields per node.
   - Implement `resolve` and `map(range:)` using binary search or an interval structure.
   - Subscribe to Loro ops and update affected nodes’ lengths and downstream `location`s (akin to `updateNodeLocationFor`).

3) TextStorage sink (apply ops → attributed string)
   - Subscribe to Loro ops, coalesce, and apply `delete/insert` in `.controllerMode` within one `beginEditing`/`endEditing` block.
   - Reuse existing attribute generation and `fixAttributes(in:)` post-pass.

4) Native input source → Loro ops
   - Intercept `TextStorage.replaceCharacters` when `mode == .none` and call `LoroBridge.applyNativeReplace(range:replacement:)` instead of `performControllerModeUpdate`.
   - Ensure selection updates derive from the index, not the reconciler.

5) Selection mapping
   - Replace `RangeCache.pointAtStringLocation` usages with the index resolver.
   - Update `RangeSelection.applyNativeSelection` and related pathways to use index-based NSRange ↔ Loro position mapping.

6) Swap out the reconciler
   - In `Editor.beginUpdate`, skip `Reconciler.updateEditorState` and call `LoroBridge.flushPendingOpsToTextStorage()`.
   - Keep decorator re-layout signals by invalidating ranges where needed using the index.

7) Import/Export
   - Implement `fromLexicalJSON` → Loro tree and `toLexicalJSON` from Loro tree (off-main parsing; swap-in on main).

8) Edge cases & performance
   - Cross-node deletes/merges (lists, headings, tables).
   - Marked text and hardware keyboard composition.
   - Large document coalescing and throttled main-thread application.

This design keeps a single source of truth (the Loro tree), preserves Lexical’s developer experience, and replaces the reconciler with a fast, op-based text sink.
