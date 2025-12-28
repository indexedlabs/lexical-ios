/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)

import UIKit
import LexicalCore

@MainActor
public class TextStorage: NSTextStorage, ReconcilerTextStorage {

  public typealias CharacterLocation = Int
  @objc public var decoratorPositionCache: [NodeKey: CharacterLocation] = [:]
  public var decoratorPositionCacheDirtyKeys: Set<NodeKey> = []
  private var pendingDecoratorCacheRepair = false

  private var backingAttributedString: NSMutableAttributedString

  /// Cached string to avoid repeated allocations when TextKit queries the string property.
  /// This is critical for performance: TextKit calls `string` thousands of times during
  /// selection/layout operations, and each call to backingAttributedString.string creates
  /// a new autoreleased copy. Caching reduces memory from ~700MB to ~17MB for large documents.
  private var cachedString: String?

  public var mode: TextStorageEditingMode
  private var editingDepth: Int = 0
  weak var editor: Editor?
  /// True while inside `performControllerModeUpdate`, indicating that UIKit's text storage editing
  /// session is still active. Layout operations must be deferred until this is false.
  internal var isInControllerModeUpdate = false

  override public init() {
    backingAttributedString = NSMutableAttributedString()
    mode = TextStorageEditingMode.none
    super.init()
  }

  convenience init(editor: Editor) {
    self.init()
    self.editor = editor
    self.backingAttributedString = NSMutableAttributedString()
    self.mode = TextStorageEditingMode.none
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("\(#function) has not been implemented")
  }

  override open var string: String {
    if let cached = cachedString {
      return cached
    }
    let str = backingAttributedString.string
    cachedString = str
    return str
  }

  override open func beginEditing() {
    editingDepth += 1
    super.beginEditing()
  }

  override open func endEditing() {
    super.endEditing()
    editingDepth = max(0, editingDepth - 1)
    if editingDepth == 0 {
      scheduleDecoratorPositionCacheRepairIfNeeded()
    }
  }

  private func scheduleDecoratorPositionCacheRepairIfNeeded() {
    guard !pendingDecoratorCacheRepair, !decoratorPositionCache.isEmpty else { return }
    pendingDecoratorCacheRepair = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingDecoratorCacheRepair = false
      self.repairDecoratorPositionCacheIfNeeded()
    }
  }

  private func repairDecoratorPositionCacheIfNeeded() {
    let storageLen = backingAttributedString.length
    guard storageLen > 0 else { return }

    var attachmentLocations: [NodeKey: Int]? = nil

    for (key, cachedLoc) in decoratorPositionCache {
      if cachedLoc >= 0, cachedLoc < storageLen,
         let att = backingAttributedString.attribute(.attachment, at: cachedLoc, effectiveRange: nil) as? TextAttachment,
         att.key == key {
        continue
      }

      if attachmentLocations == nil {
        var locations: [NodeKey: Int] = [:]
        backingAttributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storageLen)) { value, range, _ in
          if let att = value as? TextAttachment, let attKey = att.key {
            locations[attKey] = range.location
          }
        }
        attachmentLocations = locations
      }

      if let foundAt = attachmentLocations?[key] {
        decoratorPositionCache[key] = foundAt
        decoratorPositionCacheDirtyKeys.insert(key)
      }
    }
  }

  override open func attributes(
    at location: Int,
    effectiveRange range: NSRangePointer?
  ) -> [NSAttributedString.Key: Any] {
    if backingAttributedString.length <= location {
      editor?.log(.NSTextStorage, .error, "Index out of range")
      return [:]
    }
    return backingAttributedString.attributes(at: location, effectiveRange: range)
  }

  override open func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
    if mode == .none {
      let newString = attrString.string
      let currentString = backingAttributedString.attributedSubstring(from: range).string
      // We are introducing this check to fix a bug where app is getting the same string over and over again in a loop
      // when run on Mac (in Designed for iPad mode)
      if currentString != newString {
        // If mode is none (i.e. an update that hasn't gone through either controller or non-controlled mode yet),
        // we discard attribute information here. This applies to e.g. autocomplete, but it lets us handle it
        // using Lexical's own attribute persistence logic rather than UIKit's. The reason for doing it this way
        // is to avoid UIKit stomping on our custom attributes.
        editor?.log(
          .NSTextStorage, .verboseIncludingUserContent,
          "Replace characters mode=none, string length \(self.backingAttributedString.length), range \(range), replacement \(attrString.string)"
        )
        performControllerModeUpdate(attrString.string, range: range)
      }
      return
    }

    // Since we're in either controller or non-controlled mode, call super -- this will in turn call
    // both replaceCharacters and replaceAttributes. Clamp to storage bounds to avoid crashes
    // if a caller provides an out-of-range NSRange (e.g., after concurrent length changes).
    // Clamp start to [0, length], and end to [start, length]. For pure insertions with an
    // out-of-bounds location, insert at the end rather than at 0.
    let length = backingAttributedString.length
    let start = max(0, min(range.location, length))
    let end = max(start, min(range.location + range.length, length))
    let safe = NSRange(location: start, length: end - start)
    super.replaceCharacters(in: safe, with: attrString)
  }

  override open func replaceCharacters(in range: NSRange, with str: String) {
    if mode == .none {
      let currentString = backingAttributedString.attributedSubstring(from: range).string
      if currentString != str {
        performControllerModeUpdate(str, range: range)
      }
      return
    }

    // Mode is not none, so this change has already passed through Lexical
    // Clamp range to storage bounds to avoid NSRangeException from UIKit internals when fast paths race with length changes.
    let length = backingAttributedString.length
    let wasEmpty = length == 0
    let start = max(0, min(range.location, length))
    let end = max(start, min(range.location + range.length, length))
    let safe = NSRange(location: start, length: end - start)

    cachedString = nil  // Invalidate cached string

    let shouldManageEditing = editingDepth == 0
    if shouldManageEditing {
      beginEditing()
    }

    backingAttributedString.replaceCharacters(in: safe, with: str)
    edited(.editedCharacters, range: safe, changeInLength: (str as NSString).length - safe.length)
    if shouldManageEditing {
      endEditing()
    }

    let isEmpty = backingAttributedString.length == 0
    if wasEmpty != isEmpty, let editor, let frontend = editor.frontend {
      frontend.showPlaceholderText()
    }
  }

  private func performControllerModeUpdate(_ str: String, range: NSRange) {
    mode = .controllerMode
    isInControllerModeUpdate = true
    defer {
      mode = .none
      isInControllerModeUpdate = false
    }

    do {
      guard let editor, let frontend = editor.frontend else { return }

      let nativeSelection = NativeSelection(range: range, affinity: .forward)
      try editor.update {
        guard let editorState = getActiveEditorState() else {
          return
        }
        if !(try getSelection() is RangeSelection) {
          guard let newSelection = RangeSelection(nativeSelection: nativeSelection) else {
            return
          }
          editorState.selection = newSelection
        }

        guard let selection = try getSelection() as? RangeSelection else {
          return  // we should have a range selection by now, so this is unexpected
        }
        try selection.applyNativeSelection(nativeSelection)
        try selection.insertText(str)
      }
      try editor.read {
        guard let updatedSelection = try getSelection() as? RangeSelection else {
          return
        }
        let updatedNativeSelection = try createNativeSelection(
          from: updatedSelection, editor: editor)
        frontend.interceptNextSelectionChangeAndReplaceWithRange = updatedNativeSelection.range
      }

      frontend.showPlaceholderText()
    } catch {
      editor?.log(.NSTextStorage, .error, "Controller mode update failed; \(String(describing: error))")
    }
    return
  }

  override open func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
    if mode != .controllerMode {
      return
    }
    // Clamp attributes range to safe bounds
    let length = backingAttributedString.length
    let start = max(0, min(range.location, length))
    let end = max(start, min(range.location + range.length, length))
    let safe = NSRange(location: start, length: end - start)

    let shouldManageEditing = editingDepth == 0
    if shouldManageEditing {
      beginEditing()
    }
    if safe.length > 0 {
      backingAttributedString.setAttributes(attrs, range: safe)
      edited(.editedAttributes, range: safe, changeInLength: 0)
    }
    if shouldManageEditing {
      endEditing()
    }
  }

  public var extraLineFragmentAttributes: [NSAttributedString.Key: Any]? {
    didSet {
      beginEditing()
      if backingAttributedString.length > 0 {
        edited(
          .editedAttributes,
          range: NSRange(location: backingAttributedString.length - 1, length: 1), changeInLength: 0
        )
      }
      endEditing()
    }
  }
}

extension TextStorage {
  @MainActor override public var debugDescription: String {
    let codes = string.utf16.enumerated().map {
      "(\($0)=U+\(String(format: "%04X", $1)))"
    }.joined()
    return "TextStorage[\(codes)]"
  }
}
#endif  // canImport(UIKit)
