/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Foundation
import LexicalCore

#if canImport(UIKit)
// This function is analagous to the parts of onBeforeInput() where inputType == 'insertText'.
// However, on iOS, we are assuming that `shouldPreventDefaultAndInsertText()` has already been checked
// before calling onInsertTextFromUITextView().

@MainActor
internal func onInsertTextFromUITextView(
  text: String, editor: Editor,
  updateMode: UpdateBehaviourModificationMode = UpdateBehaviourModificationMode()
) throws {
  try editor.updateWithCustomBehaviour(mode: updateMode, reason: .update) {
    guard let selection = try getSelection() else {
      editor.log(.UITextView, .error, "Expected a selection here")
      return
    }

    if let markedTextOperation = updateMode.markedTextOperation,
      markedTextOperation.createMarkedText == true,
      let rangeSelection = selection as? RangeSelection
    {
      // Here we special case STARTING or UPDATING a marked text operation.
      try rangeSelection.applySelectionRange(
        markedTextOperation.selectionRangeToReplace, affinity: .forward)
    } else if let markedRange = editor.getNativeSelection().markedRange,
      let rangeSelection = selection as? RangeSelection
    {
      // Here we special case ENDING a marked text operation by replacing all the marked text with the incoming text.
      // This is usually used by hardware keyboards e.g. when typing e-acute. Software keyboards such as Japanese
      // do not seem to use this way of ending marked text.
      try rangeSelection.applySelectionRange(markedRange, affinity: .forward)
    }

    if text == "\n" || text == "\u{2029}" {
      try selection.insertParagraph()

      if let updatedSelection = try getSelection(),
        let selectedNode = try updatedSelection.getNodes().first
      {
        editor.frontend?.resetTypingAttributes(for: selectedNode)
      }
    } else if text == "\u{2028}" {
      try selection.insertLineBreak(selectStart: false)
    } else {
      try selection.insertText(text)
    }
  }
}

@MainActor
internal func onInsertLineBreakFromUITextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.insertLineBreak(selectStart: false)
}

@MainActor
internal func onInsertParagraphFromUITextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.insertParagraph()
}

@MainActor
internal func onRemoveTextFromUITextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.removeText()

  editor.frontend?.showPlaceholderText()
}

@MainActor
internal func onDeleteBackwardsFromUITextView(editor: Editor) throws {
  guard let editor = getActiveEditor(), let selection = try getSelection() else {
    throw LexicalError.invariantViolation("No editor or selection")
  }

  try selection.deleteCharacter(isBackwards: true)

  editor.frontend?.showPlaceholderText()
}

@MainActor
internal func onDeleteWordFromUITextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }

  try selection.deleteWord(isBackwards: true)

  editor.frontend?.showPlaceholderText()
}

@MainActor
internal func onDeleteLineFromUITextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }

  try selection.deleteLine(isBackwards: true)

  editor.frontend?.showPlaceholderText()
}

@MainActor
internal func onFormatTextFromUITextView(editor: Editor, type: TextFormatType) throws {
  try updateTextFormat(type: type, editor: editor)
}

@MainActor
internal func onCopyFromUITextView(editor: Editor, pasteboard: UIPasteboard) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try setPasteboard(selection: selection, pasteboard: pasteboard)
}

@MainActor
internal func onCutFromUITextView(editor: Editor, pasteboard: UIPasteboard) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try setPasteboard(selection: selection, pasteboard: pasteboard)
  try selection.removeText()

  editor.frontend?.showPlaceholderText()
}

@MainActor
internal func onPasteFromUITextView(editor: Editor, pasteboard: UIPasteboard) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }

  try insertDataTransferForRichText(selection: selection, pasteboard: pasteboard)

  editor.frontend?.showPlaceholderText()
}
#endif

@MainActor
public func shouldInsertTextAfterOrBeforeTextNode(selection: RangeSelection, node: TextNode) -> Bool
{
  var shouldInsertTextBefore = false
  var shouldInsertTextAfter = false

  if node.isSegmented() {
    return true
  }

  if !selection.isCollapsed() {
    return true
  }

  let offset = selection.anchor.offset

  shouldInsertTextBefore = offset == 0 && checkIfTokenOrCanTextBeInserted(node: node)

  shouldInsertTextAfter =
    node.getTextContentSize() == offset && checkIfTokenOrCanTextBeInserted(node: node)

  return shouldInsertTextBefore || shouldInsertTextAfter
}

@MainActor
func checkIfTokenOrCanTextBeInserted(node: TextNode) -> Bool {
  let isToken = node.isToken()
  let parent = node.getParent()

  if let parent {
    return !parent.canInsertTextBefore() || !node.canInsertTextBefore() || isToken
  }

  return !node.canInsertTextBefore() || isToken
}

/// Handle indent and outdent operations for list items and other elements.
/// This is cross-platform and used by both UIKit and AppKit.
@MainActor
internal func handleIndentAndOutdent(
  insertTab: (Node) -> Void, indentOrOutdent: (ElementNode) -> Void
) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  var alreadyHandled: Set<NodeKey> = Set()
  var nodes = try selection.getNodes()
  if nodes.isEmpty, let rangeSelection = selection as? RangeSelection {
    // Some element selections (e.g. caret at element boundary) can resolve to an empty nodes list.
    // For indent/outdent we still want to operate on the nearest block element for the caret.
    let anchorNode = try rangeSelection.anchor.getNode()
    let focusNode = try rangeSelection.focus.getNode()
    nodes = [anchorNode]
    if anchorNode.getKey() != focusNode.getKey() {
      nodes.append(focusNode)
    }
  }

  for node in nodes {
    let key = node.getKey()
    if alreadyHandled.contains(key) { continue }
    let parentBlock = try getNearestBlockElementAncestorOrThrow(startNode: node)
    let parentKey = parentBlock.getKey()
    if parentBlock.canInsertTab() {
      insertTab(parentBlock)
      alreadyHandled.insert(parentKey)
    } else if parentBlock.canIndent() && !alreadyHandled.contains(parentKey) {
      alreadyHandled.insert(parentKey)
      indentOrOutdent(parentBlock)
    }
  }
}

#if canImport(UIKit)
// triggered by selection change event from the UITextView
@MainActor
internal func onSelectionChange(editor: Editor) {
  // Note: we have to detect selection changes here even if an update is in progress, otherwise marked text breaks!
  do {
    try editor.updateWithCustomBehaviour(
      mode: UpdateBehaviourModificationMode(
        suppressReconcilingSelection: true, suppressSanityCheck: true), reason: .update
    ) {
      let debugSelection =
        ProcessInfo.processInfo.environment["LEXICAL_FORCE_DEBUG_SELECTION"] == "1"
      let nativeSelection = editor.getNativeSelection()
      if debugSelection {
        let storageLen = editor.frontend?.textStorage.length ?? -1
        let rootRange = editor.rangeCache[kRootNodeKey]?.range ?? NSRange(location: -1, length: 0)
        print(
          "🔥 SELECTION_CHANGE storageLen=\(storageLen) rootRange=\(rootRange) rangeCacheCount=\(editor.rangeCache.count)"
        )
        print(
          "🔥 SELECTION_CHANGE nativeRange=\(String(describing: nativeSelection.range)) affinity=\(nativeSelection.affinity)"
        )
      }
      guard let editorState = getActiveEditorState() else {
        return
      }
      if !(try getSelection() is RangeSelection) {
        guard let newSelection = RangeSelection(nativeSelection: nativeSelection) else {
          return
        }
        editorState.selection = newSelection
      }

      guard let lexicalSelection = try getSelection() as? RangeSelection else {
        return  // we should have a range selection by now, so this is unexpected
      }

      try lexicalSelection.applyNativeSelection(nativeSelection)
      if debugSelection, let aLoc = try? stringLocationForPoint(lexicalSelection.anchor, editor: editor),
        let fLoc = try? stringLocationForPoint(lexicalSelection.focus, editor: editor)
      {
        if let item = editor.rangeCache[lexicalSelection.anchor.key] {
          print(
            "🔥 SELECTION_CHANGE anchorRangeCache key=\(lexicalSelection.anchor.key) loc=\(item.location) pre=\(item.preambleLength) children=\(item.childrenLength) text=\(item.textLength) post=\(item.postambleLength)"
          )
        }
        print(
          "🔥 SELECTION_CHANGE lexicalRange=(\(min(aLoc, fLoc))+\(abs(aLoc - fLoc))) anchor=\(lexicalSelection.anchor.key):\(lexicalSelection.anchor.offset) focus=\(lexicalSelection.focus.key):\(lexicalSelection.focus.offset)"
        )
      }

      switch lexicalSelection.anchor.type {
      case .text:
        guard let anchorNode = try lexicalSelection.anchor.getNode() as? TextNode else { break }
        lexicalSelection.format = anchorNode.getFormat()
      case .element:
        lexicalSelection.format = TextFormat()
      default:
        break
      }
      editor.dispatchCommand(type: .selectionChange, payload: nil)
    }
  } catch {
    editor.log(.TextView, .error, "onSelectionChange failed; \(String(describing: error))")
  }
}

@MainActor
public func registerRichText(editor: Editor) {

  _ = editor.registerCommand(
    type: .insertLineBreak,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onInsertLineBreakFromUITextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in insertLineBreak; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .deleteCharacter,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onDeleteBackwardsFromUITextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in deleteCharacter; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .deleteWord,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onDeleteWordFromUITextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in deleteWord; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .deleteLine,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onDeleteLineFromUITextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in deleteLine; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .insertText,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let text = payload as? String else {
          editor.log(.TextView, .warning, "insertText missing payload")
          return false
        }

        try onInsertTextFromUITextView(text: text, editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in insertText; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .insertParagraph,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onInsertParagraphFromUITextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in insertParagraph; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .removeText,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onRemoveTextFromUITextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in removeText; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .formatText,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let text = payload as? TextFormatType else { return false }

        try onFormatTextFromUITextView(editor: editor, type: text)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in formatText; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .copy,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let text = payload as? UIPasteboard else { return false }

        try onCopyFromUITextView(editor: editor, pasteboard: text)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in copy; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .cut,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let text = payload as? UIPasteboard else { return false }

        try onCutFromUITextView(editor: editor, pasteboard: text)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in cut; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .paste,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let text = payload as? UIPasteboard else { return false }

        try onPasteFromUITextView(editor: editor, pasteboard: text)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in paste; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .indentContent,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.environment["LEXICAL_ALWAYS_DEBUG_TAB_INDENT"] == "1" {
          let hasActiveEditor = (getActiveEditor() != nil)
          let selectionDesc = String(describing: try? getSelection())
          print("🔥 indentContent(before) activeEditor=\(hasActiveEditor) selection=\(selectionDesc)")
        }
        #endif
        try handleIndentAndOutdent(
          insertTab: { node in
            editor.dispatchCommand(type: .insertText, payload: "\t")
          },
          indentOrOutdent: { elementNode in
            let indent = elementNode.getIndent()
            if indent != 10 {
              _ = try? elementNode.setIndent(indent + 1)
            }
          })
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.environment["LEXICAL_ALWAYS_DEBUG_TAB_INDENT"] == "1" {
          var indentAfter = -1
          if let root = getRoot(), let p = root.getFirstChild() as? ParagraphNode {
            indentAfter = p.getIndent()
          }
          print("🔥 indentContent(after) indent=\(indentAfter)")
        }
        #endif
        return true
      } catch {
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.environment["LEXICAL_ALWAYS_DEBUG_TAB_INDENT"] == "1" {
          print("🔥 indentContent(error) \(String(describing: error))")
        }
        #endif
        editor.log(.TextView, .error, "Exception in indentContent; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .outdentContent,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.environment["LEXICAL_ALWAYS_DEBUG_TAB_INDENT"] == "1" {
          let hasActiveEditor = (getActiveEditor() != nil)
          let selectionDesc = String(describing: try? getSelection())
          print("🔥 outdentContent(before) activeEditor=\(hasActiveEditor) selection=\(selectionDesc)")
        }
        #endif
        try handleIndentAndOutdent(
          insertTab: { node in
            if let node = node as? TextNode {
              let textContent = node.getTextContent()
              if let character = textContent.last {
                if character == "\t" {
                  editor.dispatchCommand(type: .deleteCharacter)
                }
              }
            }

            editor.dispatchCommand(type: .insertText, payload: "\t")
          },
          indentOrOutdent: { elementNode in
            let indent = elementNode.getIndent()
            if indent != 0 {
              _ = try? elementNode.setIndent(indent - 1)
            }
          })
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.environment["LEXICAL_ALWAYS_DEBUG_TAB_INDENT"] == "1" {
          var indentAfter = -1
          if let root = getRoot(), let p = root.getFirstChild() as? ParagraphNode {
            indentAfter = p.getIndent()
          }
          print("🔥 outdentContent(after) indent=\(indentAfter)")
        }
        #endif
        return true
      } catch {
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.environment["LEXICAL_ALWAYS_DEBUG_TAB_INDENT"] == "1" {
          print("🔥 outdentContent(error) \(String(describing: error))")
        }
        #endif
        editor.log(.TextView, .error, "Exception in outdentContent; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(type: .updatePlaceholderVisibility) { [weak editor] payload in
    editor?.frontend?.showPlaceholderText()
    return true
  }
}
#endif

// MARK: - AppKit Event Handlers

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Insert text from the AppKit text view.
///
/// This handles:
/// - Normal text insertion
/// - Paragraph insertion (newline)
/// - Line break insertion (shift+return)
@MainActor
public func onInsertTextFromTextView(text: String, editor: Editor) throws {
  try editor.update {
    guard let selection = try getSelection() else {
      return
    }

    // Handle different types of text
    if text == "\n" || text == "\u{2029}" {
      try selection.insertParagraph()
    } else if text == "\u{2028}" {
      try selection.insertLineBreak(selectStart: false)
    } else {
      try selection.insertText(text)
    }
  }
}

/// Apply marked text from AppKit IME composition.
///
/// AppKit delivers multi-stage IME input via `setMarkedText(_:selectedRange:replacementRange:)`.
/// This helper mirrors UIKit's marked text flow by attaching a `MarkedTextOperation` to the update,
/// allowing the reconciler to set native marked text without creating a feedback loop.
@MainActor
public func onSetMarkedTextFromTextView(
  text: String,
  selectedRange: NSRange,
  replacementRange: NSRange,
  editor: Editor
) throws {
  let op = MarkedTextOperation(
    createMarkedText: true,
    selectionRangeToReplace: replacementRange,
    markedTextString: text,
    markedTextInternalSelection: selectedRange
  )

  let mode = UpdateBehaviourModificationMode(
    suppressReconcilingSelection: true,
    suppressSanityCheck: true,
    markedTextOperation: op
  )

  try editor.updateWithCustomBehaviour(mode: mode, reason: .update) {
    guard let selection = try getSelection() else { return }

    if let rangeSelection = selection as? RangeSelection {
      try rangeSelection.applySelectionRange(replacementRange, affinity: .forward)
    }

    if text == "\n" || text == "\u{2029}" {
      try selection.insertParagraph()
    } else if text == "\u{2028}" {
      try selection.insertLineBreak(selectStart: false)
    } else {
      try selection.insertText(text)
    }
  }
}

/// Insert a line break from AppKit.
@MainActor
public func onInsertLineBreakFromTextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.insertLineBreak(selectStart: false)
}

/// Insert a paragraph from AppKit.
@MainActor
public func onInsertParagraphFromTextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.insertParagraph()
}

/// Remove text from AppKit.
@MainActor
public func onRemoveTextFromTextView(editor: Editor) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.removeText()
}

/// Delete backwards (backspace) from AppKit.
@MainActor
public func onDeleteBackwardsFromTextView(editor: Editor) throws {
  try onDeleteCharacterFromTextView(editor: editor, isBackwards: true)
}

/// Delete a character from AppKit.
@MainActor
public func onDeleteCharacterFromTextView(editor: Editor, isBackwards: Bool) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.deleteCharacter(isBackwards: isBackwards)
}

/// Delete word from AppKit.
@MainActor
public func onDeleteWordFromTextView(editor: Editor) throws {
  try onDeleteWordFromTextView(editor: editor, isBackwards: true)
}

/// Delete a word from AppKit.
@MainActor
public func onDeleteWordFromTextView(editor: Editor, isBackwards: Bool) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.deleteWord(isBackwards: isBackwards)
}

/// Delete line from AppKit.
@MainActor
public func onDeleteLineFromTextView(editor: Editor) throws {
  try onDeleteLineFromTextView(editor: editor, isBackwards: true)
}

/// Delete a line from AppKit.
@MainActor
public func onDeleteLineFromTextView(editor: Editor, isBackwards: Bool) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try selection.deleteLine(isBackwards: isBackwards)
}

/// Format text from AppKit.
@MainActor
public func onFormatTextFromTextView(editor: Editor, type: TextFormatType) throws {
  try updateTextFormat(type: type, editor: editor)
}

/// Copy to pasteboard from AppKit.
@MainActor
public func onCopyFromTextView(editor: Editor, pasteboard: NSPasteboard) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try setPasteboardAppKit(selection: selection, pasteboard: pasteboard)
}

/// Cut to pasteboard from AppKit.
@MainActor
public func onCutFromTextView(editor: Editor, pasteboard: NSPasteboard) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try setPasteboardAppKit(selection: selection, pasteboard: pasteboard)
  try selection.removeText()
}

/// Paste from pasteboard in AppKit.
@MainActor
public func onPasteFromTextView(editor: Editor, pasteboard: NSPasteboard) throws {
  guard getActiveEditor() != nil, let selection = try getSelection() as? RangeSelection else {
    throw LexicalError.invariantViolation("No editor or selection")
  }
  try insertDataTransferForRichTextAppKit(selection: selection, pasteboard: pasteboard)
}

/// Register rich text commands for AppKit.
@MainActor
public func registerRichTextAppKit(editor: Editor) {
  _ = editor.registerCommand(
    type: .insertLineBreak,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onInsertLineBreakFromTextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in insertLineBreak; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .deleteCharacter,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        let isBackwards = (payload as? Bool) ?? true
        try onDeleteCharacterFromTextView(editor: editor, isBackwards: isBackwards)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in deleteCharacter; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .deleteWord,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        let isBackwards = (payload as? Bool) ?? true
        try onDeleteWordFromTextView(editor: editor, isBackwards: isBackwards)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in deleteWord; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .deleteLine,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        let isBackwards = (payload as? Bool) ?? true
        try onDeleteLineFromTextView(editor: editor, isBackwards: isBackwards)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in deleteLine; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .insertText,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let text = payload as? String else {
          return false
        }
        try onInsertTextFromTextView(text: text, editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in insertText; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .insertParagraph,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onInsertParagraphFromTextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in insertParagraph; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .removeText,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try onRemoveTextFromTextView(editor: editor)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in removeText; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .formatText,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let formatType = payload as? TextFormatType else { return false }
        try onFormatTextFromTextView(editor: editor, type: formatType)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in formatText; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .copy,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let pasteboard = payload as? NSPasteboard else { return false }
        try onCopyFromTextView(editor: editor, pasteboard: pasteboard)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in copy; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .cut,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let pasteboard = payload as? NSPasteboard else { return false }
        try onCutFromTextView(editor: editor, pasteboard: pasteboard)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in cut; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .paste,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        guard let pasteboard = payload as? NSPasteboard else { return false }
        try onPasteFromTextView(editor: editor, pasteboard: pasteboard)
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in paste; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .indentContent,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try handleIndentAndOutdent(
          insertTab: { node in
            editor.dispatchCommand(type: .insertText, payload: "\t")
          },
          indentOrOutdent: { elementNode in
            let indent = elementNode.getIndent()
            if indent != 10 {
              _ = try? elementNode.setIndent(indent + 1)
            }
          })
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in indentContent; \(String(describing: error))")
      }
      return true
    })

  _ = editor.registerCommand(
    type: .outdentContent,
    listener: { [weak editor] payload in
      guard let editor else { return false }
      do {
        try handleIndentAndOutdent(
          insertTab: { node in
            if let node = node as? TextNode {
              let textContent = node.getTextContent()
              if let character = textContent.last {
                if character == "\t" {
                  editor.dispatchCommand(type: .deleteCharacter)
                }
              }
            }
            editor.dispatchCommand(type: .insertText, payload: "\t")
          },
          indentOrOutdent: { elementNode in
            let indent = elementNode.getIndent()
            if indent != 0 {
              _ = try? elementNode.setIndent(indent - 1)
            }
          })
        return true
      } catch {
        editor.log(.TextView, .error, "Exception in outdentContent; \(String(describing: error))")
      }
      return true
    })
}

// MARK: - AppKit Pasteboard Helpers

private let lexicalNodesPasteboardTypesAppKit: [NSPasteboard.PasteboardType] = [
  NSPasteboard.PasteboardType(LexicalConstants.pasteboardIdentifier),
  NSPasteboard.PasteboardType("com.meta.lexical.nodes"),
]

private let legacyPlainTextPasteboardTypeAppKit = NSPasteboard.PasteboardType("NSStringPboardType")
private let legacyRTFPasteboardTypeAppKit = NSPasteboard.PasteboardType("NSRTFPboardType")
private let legacyRTFDPasteboardTypeAppKit = NSPasteboard.PasteboardType("NSRTFDPboardType")

/// Set the pasteboard content for AppKit.
@MainActor
func setPasteboardAppKit(selection: BaseSelection, pasteboard: NSPasteboard) throws {
  guard let editor = getActiveEditor() else {
    throw LexicalError.invariantViolation("Could not get editor")
  }

  let nodes = try generateArrayFromSelectedNodes(editor: editor, selection: selection).nodes
  let text = try selection.getTextContent()
  let encodedData = try JSONEncoder().encode(nodes)

  var rtfData: Data?
  do {
    let attributedSelection = try getAttributedStringFromFrontend()
    rtfData = try attributedSelection.data(
      from: NSRange(location: 0, length: attributedSelection.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
  } catch {
    // Best-effort: plain text + Lexical nodes are still useful.
    rtfData = nil
  }

  pasteboard.clearContents()
  pasteboard.declareTypes(
    lexicalNodesPasteboardTypesAppKit + [.rtf, .string],
    owner: nil
  )

  // Always provide a plain-text fallback
  pasteboard.setString(text, forType: .string)

  // Provide RTF for rich-text pastes into non-Lexical targets (optional)
  if let rtfData {
    pasteboard.setData(rtfData, forType: .rtf)
  }

  // Provide Lexical node serialization for pasting within Lexical editors
  for type in lexicalNodesPasteboardTypesAppKit {
    pasteboard.setData(encodedData, forType: type)
  }
}

/// Insert data from pasteboard for rich text in AppKit.
@MainActor
func insertDataTransferForRichTextAppKit(selection: RangeSelection, pasteboard: NSPasteboard) throws
{
  // Prefer Lexical node data when available
  for type in lexicalNodesPasteboardTypesAppKit {
    if let pasteboardData = pasteboard.data(forType: type) {
      let deserializedNodes = try JSONDecoder().decode(SerializedNodeArray.self, from: pasteboardData)

      guard let editor = getActiveEditor() else { return }

      _ = try insertGeneratedNodes(
        editor: editor,
        nodes: deserializedNodes.nodeArray,
        selection: selection
      )
      return
    }
  }

  // Fall back to RTF (best-effort) for pastes from other apps
  if let pasteboardRTFData = pasteboard.data(forType: .rtf) ?? pasteboard.data(forType: legacyRTFPasteboardTypeAppKit) {
    let attributedString = try NSAttributedString(
      data: pasteboardRTFData,
      options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil
    )
    try insertRTFAppKit(selection: selection, attributedString: attributedString)
    return
  }
  if let pasteboardRTFDData = pasteboard.data(forType: .rtfd) ?? pasteboard.data(forType: legacyRTFDPasteboardTypeAppKit) {
    let attributedString = try NSAttributedString(
      data: pasteboardRTFDData,
      options: [.documentType: NSAttributedString.DocumentType.rtfd],
      documentAttributes: nil
    )
    try insertRTFAppKit(selection: selection, attributedString: attributedString)
    return
  }

  // Finally, plain text
  if let string = pasteboard.string(forType: .string) ?? pasteboard.string(forType: legacyPlainTextPasteboardTypeAppKit) {
    try insertPlainText(selection: selection, text: string)
  }
}

@MainActor
private func insertRTFAppKit(selection: RangeSelection, attributedString: NSAttributedString) throws {
  let paragraphs = attributedString.splitByNewlines()

  var nodes: [Node] = []
  for (index, paragraph) in paragraphs.enumerated() {
    var extractedAttributes = [(attributes: [NSAttributedString.Key: Any], range: NSRange)]()
    paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) {
      (dict, range, _) in
      extractedAttributes.append((attributes: dict, range: range))
    }

    var nodeArray: [Node] = []
    for attribute in extractedAttributes {
      let text = paragraph.attributedSubstring(from: attribute.range).string
      let textNode = createTextNode(text: text)

      if let font = attribute.attributes[.font] as? NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.bold) { textNode.format.bold = true }
        if traits.contains(.italic) { textNode.format.italic = true }
      }

      if let underlineAttribute = attribute.attributes[.underlineStyle] as? NSNumber,
         underlineAttribute.intValue != 0
      {
        textNode.format.underline = true
      }

      if let strikethroughAttribute = attribute.attributes[.strikethroughStyle] as? NSNumber,
         strikethroughAttribute.intValue != 0
      {
        textNode.format.strikethrough = true
      }

      nodeArray.append(textNode)
    }

    if index != 0 {
      let paragraphNode = createParagraphNode()
      try paragraphNode.append(nodeArray)
      nodes.append(paragraphNode)
    } else {
      nodes.append(contentsOf: nodeArray)
    }
  }

  _ = try selection.insertNodes(nodes: nodes, selectStart: false)
}
#endif
