/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)

import MobileCoreServices
import UIKit
import LexicalCore
import UniformTypeIdentifiers

@MainActor
protocol LexicalTextViewDelegate: NSObjectProtocol {
  func textViewDidBeginEditing(textView: TextView)
  func textViewDidEndEditing(textView: TextView)
  func textViewShouldChangeText(
    _ textView: UITextView, range: NSRange, replacementText text: String
  ) -> Bool
  func textView(
    _ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
    interaction: UITextItemInteraction
  ) -> Bool
}

/// Lexical's subclass of UITextView. Note that using this can be dangerous, if you make changes that Lexical does not expect.
@MainActor
@objc public class TextView: UITextView {
  let editor: Editor

  internal var pasteboard: UIPasteboard
  internal let pasteboardIdentifier = "x-lexical-nodes"
  internal var isUpdatingNativeSelection = false
  internal var layoutManagerDelegate: LayoutManagerDelegate

  // This is to work around a UIKit issue where, in situations like autocomplete, UIKit changes our selection via
  // private methods, and the first time we find out is when our delegate method is called. @amyworrall
  internal var interceptNextSelectionChangeAndReplaceWithRange: NSRange?
  weak var lexicalDelegate: LexicalTextViewDelegate?
  private var placeholderLabel: UILabel

  private var interceptNextTypingAttributes: [NSAttributedString.Key: Any]?

  private let useInputDelegateProxy: Bool
  private let inputDelegateProxy: InputDelegateProxy
  private let _keyCommands: [UIKeyCommand]?
  private var pendingScrollSelectionWorkItem: DispatchWorkItem?

  fileprivate var textViewDelegate: TextViewDelegate

  override public var keyCommands: [UIKeyCommand]? {
    return _keyCommands
  }

  override public func accessibilityActivate() -> Bool {
    if !isFirstResponder {
      _ = becomeFirstResponder()
    }
    return true
  }

  // MARK: - Init

  init(editorConfig: EditorConfig, featureFlags: FeatureFlags, pasteboard: UIPasteboard = .general) {
    self.pasteboard = pasteboard
    let textStorage = TextStorage()
    let layoutManager = LayoutManager()
    layoutManager.allowsNonContiguousLayout = true
    layoutManagerDelegate = LayoutManagerDelegate()
    layoutManager.delegate = layoutManagerDelegate

    let textContainer = TextContainer(
      size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true

    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    var reconcilerSanityCheck = featureFlags.reconcilerSanityCheck

    #if targetEnvironment(simulator)
      reconcilerSanityCheck = false
    #endif

    let adjustedFlags = FeatureFlags(
      reconcilerSanityCheck: reconcilerSanityCheck,
      proxyTextViewInputDelegate: featureFlags.proxyTextViewInputDelegate,
      reconcilerStrictMode: featureFlags.reconcilerStrictMode,
      verboseLogging: featureFlags.verboseLogging
    )

    editor = Editor(
      featureFlags: adjustedFlags,
      editorConfig: editorConfig)
    textStorage.editor = editor
    placeholderLabel = UILabel(frame: .zero)

    useInputDelegateProxy = featureFlags.proxyTextViewInputDelegate
    inputDelegateProxy = InputDelegateProxy()
    textViewDelegate = TextViewDelegate(editor: editor)
    _keyCommands = editorConfig.keyCommands

    super.init(frame: .zero, textContainer: textContainer)

    // TextKit 2 experimental A/B path removed.

    if useInputDelegateProxy {
      inputDelegateProxy.targetInputDelegate = self.inputDelegate
      super.inputDelegate = inputDelegateProxy
    }

    delegate = textViewDelegate
    textContainerInset = UIEdgeInsets(top: 8.0, left: 5.0, bottom: 8.0, right: 5.0)

    setUpPlaceholderLabel()
    registerRichText(editor: editor)

    // Opportunistically drive viewport-only layout on iOS 16+.
    if #available(iOS 16.0, *) {
      // Trigger an initial viewport layout; we’ll also refresh in layoutSubviews.
      self.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
  }

  /// This init method is used for unit tests
  convenience init() {
    self.init(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags(), pasteboard: .general)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("\(#function) has not been implemented")
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    placeholderLabel.frame.origin = CGPoint(
      x: textContainer.lineFragmentPadding * 1.5 + textContainerInset.left,
      y: textContainerInset.top)
    placeholderLabel.sizeToFit()

    // Keep viewport layout bounded to visible area (iOS 16+)
    if #available(iOS 16.0, *) {
      self.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
  }

  override public var inputDelegate: UITextInputDelegate? {
    get {
      if useInputDelegateProxy {
        return inputDelegateProxy.targetInputDelegate
      } else {
        return super.inputDelegate
      }
    }
    set {
      if useInputDelegateProxy {
        inputDelegateProxy.targetInputDelegate = newValue
      } else {
        super.inputDelegate = newValue
      }
    }
  }

  public override func caretRect(for position: UITextPosition) -> CGRect {
    if let interceptNextTypingAttributes {
      typingAttributes = interceptNextTypingAttributes
      self.interceptNextTypingAttributes = nil
    }

    let originalRect = super.caretRect(for: position)
    return CaretAndSelectionRectsAdjuster.adjustCaretRect(originalRect, for: position, in: self)
  }

  override public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
    let largeSelectionCharacterThreshold = 10_000

    let startOffset = offset(from: beginningOfDocument, to: range.start)
    let endOffset = offset(from: beginningOfDocument, to: range.end)
    let selectionLength = abs(endOffset - startOffset)

    // For very large selections (e.g. Select All on a large document), avoid asking TextKit to compute
    // geometry for the entire selection. That can force layout of the whole document and cause huge
    // transient memory spikes. Instead, return selection rects only for the currently visible viewport.
    if selectionLength >= largeSelectionCharacterThreshold {
      var visibleRectInTextContainerCoords = bounds
      visibleRectInTextContainerCoords.origin.x -= textContainerInset.left
      visibleRectInTextContainerCoords.origin.y -= textContainerInset.top

      let visibleGlyphRange = layoutManager.glyphRange(
        forBoundingRect: visibleRectInTextContainerCoords, in: textContainer)
      let visibleCharRange = layoutManager.characterRange(
        forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

      let selectionRange = NSRange(location: min(startOffset, endOffset), length: selectionLength)
      let clamped = NSIntersectionRange(selectionRange, visibleCharRange)
      guard clamped.length > 0 else {
        return []
      }

      guard
        let clampedStart = position(from: beginningOfDocument, offset: clamped.location),
        let clampedEnd = position(from: beginningOfDocument, offset: clamped.location + clamped.length),
        let clampedTextRange = textRange(from: clampedStart, to: clampedEnd)
      else {
        return []
      }

      let visibleRects = super.selectionRects(for: clampedTextRange)
      return CaretAndSelectionRectsAdjuster.adjustSelectionRects(
        visibleRects,
        for: clampedTextRange,
        in: self,
        originalSelectionStartOffset: startOffset,
        originalSelectionEndOffset: endOffset,
        clampedSelectionStartOffset: clamped.location,
        clampedSelectionEndOffset: clamped.location + clamped.length
      )
    }

    let originalRects = super.selectionRects(for: range)
    return CaretAndSelectionRectsAdjuster.adjustSelectionRects(originalRects, for: range, in: self)
  }

  // MARK: - Incoming events

  override public func deleteBackward() {
    editor.log(.UITextView, .verbose, "deleteBackward()")

    // Ensure Lexical selection is synced with the current native selection. In unit tests and
    // some programmatic selection changes, `textViewDidChangeSelection` may not fire reliably.
    onSelectionChange(editor: editor)

    let previousSelectedRange = selectedRange
    let previousText = text

    inputDelegateProxy.isSuspended = true  // do not send selection changes during deleteBackwards, to not confuse third party keyboards
    defer {
      inputDelegateProxy.isSuspended = false
    }

    // Deletions driven by Lexical should not be treated as "native" TextStorage edits.
    // When `TextStorage.mode` is `.none`, TextKit mutations can re-enter Lexical via
    // `performControllerModeUpdate`, causing double-applies and selection drift at boundaries.
    //
    // Keep parity with `insertText(_:)` by running Lexical-driven deletes in controller mode.
    if let textStorage = textStorage as? TextStorage {
      let previousMode = textStorage.mode
      if previousMode == .none {
        textStorage.mode = .controllerMode
      }
      editor.dispatchCommand(type: .deleteCharacter, payload: true)
      textStorage.mode = previousMode
    } else {
      editor.dispatchCommand(type: .deleteCharacter, payload: true)
    }

    var handledByNonRangeSelection = false
    do {
      try editor.read {
        if let selection = try? getSelection() {
          handledByNonRangeSelection = selection is NodeSelection || selection is GridSelection
        }
      }
    } catch {}

    // Fallback: if nothing changed (text and selection), delegate to UIKit's default handling
    if text == previousText && selectedRange == previousSelectedRange && !handledByNonRangeSelection {
      // If we fall back to UIKit, we must allow the input delegate callbacks through so that:
      // - `UITextView` can update selection normally
      // - Lexical can observe and reconcile the native edit via the TextStorage delegate path
      inputDelegateProxy.isSuspended = false
      super.deleteBackward()
      resetTypingAttributes(for: selectedRange)
      return
    }

    if previousSelectedRange.length > 0 {
      // Expect new selection to be on the start of selection
      if selectedRange.location != previousSelectedRange.location || selectedRange.length != 0 {
        inputDelegateProxy.sendSelectionChangedIgnoringSuspended(self)
      }
    } else {
      // Expect new selection to be somewhere before selection -- we could calculate this by considering
      // unicode characters, but it would be complex. Let's do a best effort, since this situation is rare anyway.
      if selectedRange.length != 0 || selectedRange.location >= previousSelectedRange.location {
        inputDelegateProxy.sendSelectionChangedIgnoringSuspended(self)
      }
    }

    resetTypingAttributes(for: selectedRange)
  }

  public func resetTypingAttributes(for selectedRange: NSRange) {
    do {
      try editor.read {
        guard let editor = getActiveEditor(),
          let point = try pointAtStringLocation(
            selectedRange.location,
            searchDirection: .forward,
            rangeCache: editor.rangeCache,
            fenwickTree: {
              guard editor.useFenwickLocations, editor.fenwickHasDeltas else { return nil }
              _ = editor.cachedDFSOrderAndIndex()
              return editor.locationFenwickTree
            }())
        else {
          return
        }

        let node = try point.getNode()
        resetTypingAttributes(for: node)
      }
    } catch {
      editor.log(.UITextView, .error, "Failed resetting typing attributes; \(String(describing: error))")
    }
  }

  public func resetTypingAttributes(for selectedNode: Node) {
    let attributes = AttributeUtils.attributedStringStyles(
      from: selectedNode,
      state: editor.getEditorState(),
      theme: editor.getTheme()
    )
    typingAttributes = attributes
    interceptNextTypingAttributes = attributes
  }

  override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)) {
      if pasteboard.hasStrings {
        return true
      } else if !(pasteboard.data(forPasteboardType: LexicalConstants.pasteboardIdentifier)?.isEmpty
        ?? true)
      {
        return true
      }

      if #available(iOS 14.0, *) {
        if !(pasteboard.data(forPasteboardType: UTType.rtf.identifier)?.isEmpty ?? true) {
          return true
        }
        if !(pasteboard.data(forPasteboardType: UTType.utf8PlainText.identifier)?.isEmpty ?? true) {
          return true
        }
      } else {
        if !(pasteboard.data(forPasteboardType: (kUTTypeRTF as String))?.isEmpty ?? true) {
          return true
        }
        if !(pasteboard.data(forPasteboardType: (kUTTypeUTF8PlainText as String))?.isEmpty ?? true) {
          return true
        }
      }
      return super.canPerformAction(action, withSender: sender)
    } else {
      return super.canPerformAction(action, withSender: sender)
    }
  }

  override public func copy(_ sender: Any?) {
    editor.dispatchCommand(type: .copy, payload: pasteboard)
  }

  override public func cut(_ sender: Any?) {
    editor.dispatchCommand(type: .cut, payload: pasteboard)
  }

  override public func paste(_ sender: Any?) {
    editor.dispatchCommand(type: .paste, payload: pasteboard)
  }

  override public func insertText(_ text: String) {
    editor.log(
      .UITextView, .verbose, "Text view selected range \(String(describing: self.selectedRange))")

    // Ensure Lexical selection is synced with the current native selection. In unit tests and
    // some programmatic selection changes, `textViewDidChangeSelection` may not fire reliably.
    onSelectionChange(editor: editor)

    let expectedSelectionLocation = selectedRange.location + text.lengthAsNSString()

    inputDelegateProxy.isSuspended = true  // do not send selection changes during insertText, to not confuse third party keyboards
    defer {
      inputDelegateProxy.isSuspended = false
    }

    guard let textStorage = textStorage as? TextStorage else {
      // This should never happen, we will always have a custom text storage.
      editor.log(.TextView, .error, "Missing custom text storage")
      return
    }

    textStorage.mode = TextStorageEditingMode.controllerMode
    editor.dispatchCommand(type: .insertText, payload: text)
    textStorage.mode = TextStorageEditingMode.none

    // When layout is allowed to be non-contiguous, TextKit may defer laying out newly-inserted
    // content. During rapid typing this can make the caret appear to lag behind the inserted text.
    // Ensure layout in a tiny range around the caret so the insertion point stays visually in sync.
    if layoutManager.hasNonContiguousLayout {
      let len = textStorage.length
      if len > 0 {
        let caret = min(max(0, selectedRange.location), len)
        let ensureLoc = min(max(0, (caret == len) ? (caret - 1) : caret), len - 1)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: ensureLoc, length: 1))
      }
    }

    // Ensure the insertion point remains visible when inserting newlines (e.g. pressing Return).
    // With Lexical's controller-driven text storage, UIKit doesn't always auto-scroll for us.
    if text.contains("\n") {
      requestScrollSelectionToVisible()
    }

    // check if we need to send a selectionChanged (i.e. something unexpected happened)
    if selectedRange.length != 0 || selectedRange.location != expectedSelectionLocation {
      inputDelegateProxy.sendSelectionChangedIgnoringSuspended(self)
    }
  }

  // MARK: Marked text

  override public func setAttributedMarkedText(
    _ markedText: NSAttributedString?, selectedRange: NSRange
  ) {
    editor.log(.UITextView, .verbose)
    if let markedText {
      setMarkedTextInternal(markedText.string, selectedRange: selectedRange)
    } else {
      unmarkText()
    }
  }

  override public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    editor.log(.UITextView, .verbose)
    if let markedText {
      setMarkedTextInternal(markedText, selectedRange: selectedRange)
    } else {
      unmarkText()
    }
  }

  private func setMarkedTextInternal(_ markedText: String, selectedRange: NSRange) {
    editor.log(.TextView, .verbose)

    // Ensure Lexical selection is synced with the current native selection. In unit tests and
    // some programmatic selection changes, `textViewDidChangeSelection` may not fire reliably.
    onSelectionChange(editor: editor)

    guard let textStorage = textStorage as? TextStorage else {
      // This should never happen, we will always have a custom text storage.
      editor.log(.TextView, .error, "Missing custom text storage")
      super.setMarkedText(markedText, selectedRange: selectedRange)
      return
    }

    if markedText.isEmpty, let markedRange = editor.getNativeSelection().markedRange {
      textStorage.replaceCharacters(in: markedRange, with: "")
      return
    }

    let markedTextOperation = MarkedTextOperation(
      createMarkedText: true,
      selectionRangeToReplace: editor.getNativeSelection().markedRange ?? self.selectedRange,
      markedTextString: markedText,
      markedTextInternalSelection: selectedRange)

    let behaviourModificationMode = UpdateBehaviourModificationMode(
      suppressReconcilingSelection: true, suppressSanityCheck: true,
      markedTextOperation: markedTextOperation)

    textStorage.mode = TextStorageEditingMode.controllerMode
    defer {
      textStorage.mode = TextStorageEditingMode.none
    }
    do {
      // set composition key
      try editor.read {
        guard let selection = try getSelection() as? RangeSelection else {
          editor.log(.TextView, .error, "Could not get selection in setMarkedTextInternal()")
          throw LexicalError.invariantViolation("should have selection when starting marked text")
        }

        editor.compositionKey = selection.anchor.key
      }

      // insert text
      try onInsertTextFromUITextView(
        text: markedText, editor: editor, updateMode: behaviourModificationMode)
    } catch {
      let language = textInputMode?.primaryLanguage
      editor.log(
        .TextView, .error,
        "exception thrown, lang \(String(describing: language)): \(String(describing: error))")
      unmarkTextWithoutUpdate()
      return
    }
  }

  internal func setMarkedTextFromReconciler(
    _ markedText: NSAttributedString, selectedRange: NSRange
  ) {
    editor.log(.TextView, .verbose)
    isUpdatingNativeSelection = true
    super.setAttributedMarkedText(markedText, selectedRange: selectedRange)
    interceptNextSelectionChangeAndReplaceWithRange = nil
    onSelectionChange(editor: editor)
    isUpdatingNativeSelection = false
    editor.compositionKey = nil
    showPlaceholderText()
  }

  override public func unmarkText() {
    editor.log(.UITextView, .verbose)
    let previousMarkedRange = editor.getNativeSelection().markedRange
    let oldIsUpdatingNative = isUpdatingNativeSelection
    isUpdatingNativeSelection = true
    super.unmarkText()
    isUpdatingNativeSelection = oldIsUpdatingNative
    if let previousMarkedRange {
      // find all nodes in selection. Mark dirty. Reconcile. This should correct all the attributes to be what we expect.
      do {
        try editor.update {
          let fenwickTree: FenwickTree? = {
            guard editor.useFenwickLocations, editor.fenwickHasDeltas else { return nil }
            _ = editor.cachedDFSOrderAndIndex()
            return editor.locationFenwickTree
          }()

          guard
            let anchor = try pointAtStringLocation(
              previousMarkedRange.location,
              searchDirection: .forward,
              rangeCache: editor.rangeCache,
              fenwickTree: fenwickTree
            ),
            let focus = try pointAtStringLocation(
              previousMarkedRange.location + previousMarkedRange.length,
              searchDirection: .forward,
              rangeCache: editor.rangeCache,
              fenwickTree: fenwickTree)
          else {
            return
          }

          let markedRangeSelection = RangeSelection(
            anchor: anchor, focus: focus, format: TextFormat())
          _ = try markedRangeSelection.getNodes().map { node in
            internallyMarkNodeAsDirty(node: node, cause: .userInitiated)
          }

          editor.compositionKey = nil
        }
      } catch {}
    }
  }

  internal func unmarkTextWithoutUpdate() {
    editor.log(.TextView, .verbose)
    super.unmarkText()
  }

  // MARK: - Lexical internal

  internal func presentDeveloperFacingError(message: String) {
    let alert = UIAlertController(title: "Lexical Error", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: UIAlertAction.Style.default, handler: nil))
    if let rootViewController = self.window?.rootViewController {
      rootViewController.present(alert, animated: true, completion: nil)
    }
  }

  internal func updateNativeSelection(from selection: RangeSelection) throws {
    isUpdatingNativeSelection = true
    defer { isUpdatingNativeSelection = false }
    let nativeSelection = try createNativeSelection(from: selection, editor: editor)
    let previousSelectedRange = selectedRange

    if let range = nativeSelection.range {
      selectedRange = range
      if range.location != previousSelectedRange.location || range.length != previousSelectedRange.length {
        let delta =
          abs(range.location - previousSelectedRange.location)
          + abs(range.length - previousSelectedRange.length)
        if delta <= 2048 {
          requestScrollSelectionToVisible()
        }
      }
    } else {
      // If we can't map the Lexical selection back to a native range (usually because the range cache
      // is temporarily out of sync after a structural edit), ensure we still set a valid caret.
      // Otherwise UIKit can end up with an invalid/hidden caret until the user taps to force a selection change.
      let len = textStorage.length
      let clampedLoc = min(max(0, selectedRange.location), len)
      let clampedRange = NSRange(location: clampedLoc, length: 0)
      selectedRange = clampedRange
      if clampedRange.location != previousSelectedRange.location || clampedRange.length != previousSelectedRange.length {
        let delta =
          abs(clampedRange.location - previousSelectedRange.location)
          + abs(clampedRange.length - previousSelectedRange.length)
        if delta <= 2048 {
          requestScrollSelectionToVisible()
        }
      }
    }
  }

  internal func resetSelectedRange() {
    selectedRange = NSRange(location: 0, length: 0)
  }

  fileprivate func requestScrollSelectionToVisible() {
    guard window != nil, isScrollEnabled else { return }
    pendingScrollSelectionWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.window != nil, self.isScrollEnabled else { return }
      let rangeToScroll = self.selectedRange
      let len = self.textStorage.length

      // Ensure the caret range is laid out (especially with non-contiguous layout) so that
      // caretRect/scrolling work reliably.
      if len > 0 {
        let caret = min(max(0, rangeToScroll.location), len)
        let ensureLoc = min(max(0, (caret == len) ? (caret - 1) : caret), len - 1)
        self.layoutManager.ensureLayout(forCharacterRange: NSRange(location: ensureLoc, length: 1))
      }

      self.layoutIfNeeded()
      if let end = self.selectedTextRange?.end {
        var caretRect = self.caretRect(for: end)
        caretRect = caretRect.insetBy(dx: 0, dy: -8)
        let padding: CGFloat = 8
        let minY = -self.adjustedContentInset.top

        let visibleTop = self.contentOffset.y
        let visibleBottom = visibleTop + self.bounds.height

        var targetY = self.contentOffset.y
        if caretRect.maxY > (visibleBottom - padding) {
          targetY = caretRect.maxY - self.bounds.height + padding
        } else if caretRect.minY < (visibleTop + padding) {
          targetY = caretRect.minY - padding
        }

        targetY = max(targetY, minY)
        // Avoid forcing full layout/contentSize calculation for very large documents.
        if len <= 20_000 {
          let maxY = max(
            minY,
            self.contentSize.height - self.bounds.height + self.adjustedContentInset.bottom)
          targetY = min(targetY, maxY)
        }

        self.setContentOffset(CGPoint(x: self.contentOffset.x, y: targetY), animated: false)
      } else {
        self.scrollRangeToVisible(rangeToScroll)
      }
    }
    pendingScrollSelectionWorkItem = work
    DispatchQueue.main.async(execute: work)
  }

  func defaultClearEditor() throws {
    editor.resetEditor(pendingEditorState: nil)
    editor.dispatchCommand(type: .clearEditor)
  }

  public func setPlaceholderText(_ text: String, textColor: UIColor, font: UIFont) {
    placeholderLabel.text = text
    placeholderLabel.textColor = textColor
    placeholderLabel.font = font
    self.font = font

    showPlaceholderText()
  }

  func showPlaceholderText() {
    var shouldShow = false
    do {
      try editor.read {
        guard let root = getRoot() else { return }
        shouldShow = root.getTextContentSize() == 0
      }
      if !shouldShow {
        hidePlaceholderLabel()
        return
      }
      try editor.read {
        if canShowPlaceholder(isComposing: editor.isComposing()) {
          placeholderLabel.isHidden = false
          layoutIfNeeded()
        }
      }
    } catch {}
  }

  // MARK: - Private

  private func setUpPlaceholderLabel() {
    placeholderLabel.backgroundColor = .clear
    placeholderLabel.isHidden = true
    placeholderLabel.isAccessibilityElement = false
    placeholderLabel.numberOfLines = 1
    addSubview(placeholderLabel)
  }

  fileprivate func hidePlaceholderLabel() {
    placeholderLabel.isHidden = true
  }

  override public func becomeFirstResponder() -> Bool {
    let r = super.becomeFirstResponder()
    if r == true {
      onSelectionChange(editor: editor)
    }
    return r
  }

  internal func validateNativeSelection(_ textView: UITextView) {
    guard let selectedRange = textView.selectedTextRange else { return }

    let start = validatePosition(
      textView: textView, position: selectedRange.start, direction: .forward)
    let end = validatePosition(textView: textView, position: selectedRange.end, direction: .forward)

    if start != selectedRange.start || end != selectedRange.end {
      isUpdatingNativeSelection = true
      selectedTextRange = textRange(from: start, to: end)
      isUpdatingNativeSelection = false
    }
  }
}

@MainActor
private class TextViewDelegate: NSObject, UITextViewDelegate {
  private var editor: Editor

  init(editor: Editor) {
    self.editor = editor
  }

  public func textViewDidChangeSelection(_ textView: UITextView) {
    guard let textView = textView as? TextView else { return }
    let currentRange = textView.selectedRange

    if textView.isUpdatingNativeSelection {
      editor.log(.TextView, .verbose, "[textViewDidChangeSelection] IGNORED (isUpdatingNativeSelection): \(currentRange)")
      return
    }

    if let interception = textView.interceptNextSelectionChangeAndReplaceWithRange {
      editor.log(.TextView, .verbose, "[textViewDidChangeSelection] INTERCEPTED: native=\(currentRange) -> forced=\(interception)")
      textView.interceptNextSelectionChangeAndReplaceWithRange = nil
      textView.selectedRange = interception
      return
    }

    editor.log(.TextView, .verbose, "[textViewDidChangeSelection] PROCESSING: nativeRange=\(currentRange)")
    textView.validateNativeSelection(textView)
    onSelectionChange(editor: textView.editor)
  }

  public func textView(
    _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
  ) -> Bool {
    guard let textView = textView as? TextView else { return false }

    textView.hidePlaceholderLabel()
    if let lexicalDelegate = textView.lexicalDelegate {
      return lexicalDelegate.textViewShouldChangeText(textView, range: range, replacementText: text)
    }

    return true
  }

  public func textViewDidBeginEditing(_ textView: UITextView) {
    guard let textView = textView as? TextView else { return }

    editor.dispatchCommand(type: .beginEditing)
    textView.lexicalDelegate?.textViewDidBeginEditing(textView: textView)
  }

  public func textViewDidEndEditing(_ textView: UITextView) {
    guard let textView = textView as? TextView else { return }

    editor.dispatchCommand(type: .endEditing)
    textView.lexicalDelegate?.textViewDidEndEditing(textView: textView)
  }

  public func textView(
    _ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
    interaction: UITextItemInteraction
  ) -> Bool {
    guard let textView = textView as? TextView else { return false }

    // TODO: consider updating `.linkTapped` payload to include this native selection if we want that behavior.
    //    let nativeSelection = NativeSelection(range: characterRange, affinity: .backward)
    //    try? textView.editor.update {
    //      guard let selection = try getSelection() as? RangeSelection else {
    //        // TODO: cope with non range selections. Should just make a range selection here
    //        return
    //      }
    //      try selection.applyNativeSelection(nativeSelection)
    //    }

    let handledByLexical = textView.editor.dispatchCommand(type: .linkTapped, payload: URL)

    if handledByLexical {
      return false
    }

    if !textView.isEditable {
      return true
    }

    return textView.lexicalDelegate?.textView(
      textView, shouldInteractWith: URL, in: characterRange, interaction: interaction) ?? false
  }
}

//  The problem we're trying to solve:
//    If we set a paragraphStyle attribute with a paragraphSpacing value to add some space after a heading for an example
//    the caret, when in the last line of such a paragraph, will have an abonormally large height and will be effectively
//    longer for the space added. This also happens if we apply setBlockLevelAttributes padding or margin since it also
//    uses paragraphStyle.paragraphSpacing under the hood. Also selection carets, or handles, will be affected.
//
//  If, at some point, we want to use paragraphStyle.beforeParagraphSpacing, to add some space on the top of the paragraph
//  we will have to adjust this adjuster. Since we don't have such plans atm I opted to skip it to save time and effort
//  and also not complicate this code unnecessarily.
@MainActor
private class CaretAndSelectionRectsAdjuster {

  static func adjustCaretRect(
    _ originalRect: CGRect, for position: UITextPosition, in textView: UITextView
  ) -> CGRect {
    var result = originalRect
    // Find the caret position as an index in the text
    let offset = textView.offset(from: textView.beginningOfDocument, to: position)
    // Retrieve attributes at the caret position
    let attributes = textView.textStorage.attributes(at: offset, effectiveRange: nil)
    if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle,
      paragraphStyle.paragraphSpacing > 0 || paragraphStyle.lineSpacing > 0
    {
      // there is paragraph spacing, in that case we opt for a fixed size caret
      guard let font = textView.font else { return result }

      // "descender" is expressed as a negative value,
      // so to add its height you must subtract its value
      result.size.height = font.pointSize - font.descender
    }

    return result
  }

  static func adjustSelectionRects(
    _ originalRects: [UITextSelectionRect],
    for range: UITextRange,
    in textView: UITextView,
    originalSelectionStartOffset: Int? = nil,
    originalSelectionEndOffset: Int? = nil,
    clampedSelectionStartOffset: Int? = nil,
    clampedSelectionEndOffset: Int? = nil
  ) -> [UITextSelectionRect] {
    // Avoid wrapping every rect: for large selections UIKit can return many selection rects and
    // this method may be called frequently. We only need to adjust the start/end handles.
    var didAdjust = false
    var out: [UITextSelectionRect] = []
    out.reserveCapacity(originalRects.count)

    for rect in originalRects {
      let isClampedSelection = originalSelectionStartOffset != nil
        && originalSelectionEndOffset != nil
        && clampedSelectionStartOffset != nil
        && clampedSelectionEndOffset != nil

      let shouldMarkContainsStart: Bool = {
        guard isClampedSelection else { return rect.containsStart }
        // Only mark the start handle if the start of the *original* selection is visible in this clamped range.
        return rect.containsStart && clampedSelectionStartOffset == originalSelectionStartOffset
      }()

      let shouldMarkContainsEnd: Bool = {
        guard isClampedSelection else { return rect.containsEnd }
        // Only mark the end handle if the end of the *original* selection is visible in this clamped range.
        return rect.containsEnd && clampedSelectionEndOffset == originalSelectionEndOffset
      }()

      if shouldMarkContainsStart && shouldMarkContainsEnd {
        let adjusted = adjustCaretRect(rect.rect, for: range.start, in: textView)
        out.append(
          CustomSelectionRect(
            baseRect: rect,
            adjustedRect: adjusted,
            containsStartOverride: true,
            containsEndOverride: true
          )
        )
        didAdjust = true
      } else if shouldMarkContainsStart {
        let adjusted = adjustCaretRect(rect.rect, for: range.start, in: textView)
        out.append(
          CustomSelectionRect(
            baseRect: rect,
            adjustedRect: adjusted,
            containsStartOverride: true,
            containsEndOverride: false
          )
        )
        didAdjust = true
      } else if shouldMarkContainsEnd {
        let adjusted = adjustCaretRect(rect.rect, for: range.end, in: textView)
        out.append(
          CustomSelectionRect(
            baseRect: rect,
            adjustedRect: adjusted,
            containsStartOverride: false,
            containsEndOverride: true
          )
        )
        didAdjust = true
      } else if isClampedSelection {
        // For clamped (viewport-only) selection rects, never mark containsStart/End unless the
        // actual selection boundary is within the viewport.
        out.append(
          CustomSelectionRect(
            baseRect: rect,
            adjustedRect: rect.rect,
            containsStartOverride: false,
            containsEndOverride: false
          )
        )
        didAdjust = true
      } else {
        out.append(rect)
      }
    }

    return didAdjust ? out : originalRects
  }

}

// Custom UITextSelectionRect subclass for modified rects
private class CustomSelectionRect: UITextSelectionRect {
  private let baseRect: UITextSelectionRect
  private let customRect: CGRect
  private let containsStartOverride: Bool?
  private let containsEndOverride: Bool?

  init(
    baseRect: UITextSelectionRect,
    adjustedRect: CGRect,
    containsStartOverride: Bool? = nil,
    containsEndOverride: Bool? = nil
  ) {
    self.baseRect = baseRect
    self.customRect = adjustedRect
    self.containsStartOverride = containsStartOverride
    self.containsEndOverride = containsEndOverride
    super.init()
  }

  override var rect: CGRect {
    return customRect
  }

  override var containsStart: Bool {
    return containsStartOverride ?? baseRect.containsStart
  }

  override var containsEnd: Bool {
    return containsEndOverride ?? baseRect.containsEnd
  }

  override var isVertical: Bool {
    return baseRect.isVertical
  }

  override var writingDirection: UITextWritingDirection {
    return baseRect.writingDirection
  }
}
#endif  // canImport(UIKit)
