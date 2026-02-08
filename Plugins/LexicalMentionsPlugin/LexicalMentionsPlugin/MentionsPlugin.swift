/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import Lexical
#if canImport(UIKit)
import UIKit
#endif

let mentionCaptureGroupName = "mention"

public struct MentionMatch {
  public var range: NSRange
  public var text: String
}

public enum MentionsMode {
  case users
  case bots
}

public typealias OnSearchForMentions = (_ match: MentionMatch) -> Void
public typealias OnSearchForMentionsWithCursorPosition = (
  _ match: MentionMatch, _ cursorPosition: CGRect?
) -> Void
public typealias OnClearMentionSearch = () -> Void

open class MentionsPlugin: Plugin {
  public var onSearchForMentions: OnSearchForMentions?
  public var onSearchForMentionsWithCursorPosition: OnSearchForMentionsWithCursorPosition?
  public var onClearMentionSearch: OnClearMentionSearch?

  var unregister: (() -> Void)?
  var deleteCharacterUnregister: (() -> Void)?

  // Update listener state
  var previousText: String?
  var matchRange: NSRange?
#if canImport(UIKit)
  private weak var textViewRef: UITextView?
  private var cursorPosition: CGRect?
#endif

  let modes: Set<MentionsMode>
  var regexByMode: [MentionsMode: String] = [:]

  public init(modes: Set<MentionsMode>) {
    self.modes = modes

    for mode in modes {
      regexByMode[mode] = regex(for: mode)
    }
  }

  public convenience init() {
    self.init(modes: [.users])
  }

  public func setUp(editor: Editor) {
    unregister = editor.registerUpdateListener(listener: updateListener)
    deleteCharacterUnregister = editor.registerCommand(
      type: .deleteCharacter,
      listener: { [weak self, weak editor] payload in
        guard let self, let editor else { return false }
        return self.handleDeleteCharacterPayload(payload, editor: editor)
      },
      priority: .Critical,
      shouldWrapInUpdateBlock: false
    )

    do {
      try editor.registerNode(nodeType: NodeType.mention, class: MentionNode.self)
    } catch {}
  }

  public func tearDown() {
    unregister?()
    deleteCharacterUnregister?()
    #if canImport(UIKit)
    textViewRef = nil
    #endif
  }

  #if canImport(UIKit)
  public func setTextView(_ textView: UITextView) {
    textViewRef = textView
  }

  public func setCursorPosition(_ position: CGRect?) {
    cursorPosition = position
  }

  public func getCursorPosition() -> CGRect? {
    cursorPosition
  }
  #endif

  func updateListener(activeEditorState: EditorState, _ previousEditorState: EditorState, _ dirtyNodes: DirtyNodeMap) {
    do {
      let text = try getMentionsTextToSearch(activeEditorState: activeEditorState)

      if text == previousText {
        return
      }

      previousText = text

      guard let text, let match = getPossibleMentionMatch(text: text) else {
        onClearMentionSearch?()

        return
      }

      onSearchForMentions?(match)
      onSearchForMentionsWithCursorPosition?(match, cursorPosition)
    } catch {}
  }

  func getMentionsTextToSearch(activeEditorState: EditorState) throws -> String? {
    var text: String?

    try activeEditorState.read {
      guard let selection = try getSelection() as? RangeSelection else {
        return
      }

      text = getTextUpToAnchor(selection: selection)
    }

    return text
  }

  func getTextUpToAnchor(selection: RangeSelection) -> String? {
    let anchor = selection.anchor

    if anchor.getType() != .text {
      return nil
    }

    do {
      let anchorNode = try anchor.getNode()

      // We should not be attempting to extract mentions out of nodes
      // that are already being used for other core things. This is
      // especially true for immutable nodes, which can't be mutated at all.
      if let textNode = anchorNode as? TextNode, !textNode.isSimpleText() {
        return nil
      }

      let anchorOffset = anchor.getOffset()

      return (anchorNode.getTextContent() as NSString).substring(to: anchorOffset)
    } catch {
      return nil
    }
  }

  func regex(for mode: MentionsMode) -> String {
    let prefixSymbol: String
    switch mode {
    case .users:
      prefixSymbol = "@"
    case .bots:
      prefixSymbol = "#"
    }
    return "(^|\\s|\\()(?<\(mentionCaptureGroupName)>"
      + prefixSymbol
      + "[a-zA-Z0-9_.\\s]{0,75})"
  }

  func getPossibleMentionMatch(text: String) -> MentionMatch? {
    do {
      for mode in modes {
        // Can't be nil as regexes for all modes are populated during init
        let regex = regexByMode[mode]! // swiftlint:disable:this force_unwrapping
        if let result = try checkForMentions(text: text, regex: regex, minMatchLength: 1) {
          return result
        }
      }
    } catch {
      return nil
    }

    return nil
  }

  func checkForMentions(
    text: String,
    regex: String,
    minMatchLength: Int
  ) throws -> MentionMatch? {
    let nameRegex = try NSRegularExpression(
      pattern: regex,
      options: .caseInsensitive
    )
    let searchRange = NSRange(location: 0, length: text.lengthAsNSString())

    let matches = nameRegex.matches(
      in: text,
      options: [],
      range: searchRange
    )

    guard let match = matches.first else {
      return nil
    }

    matchRange = match.range(withName: mentionCaptureGroupName)

    guard let matchRange else {
      return nil
    }

    if let substringRange = Range(matchRange, in: text) {
      let capture = String(text[substringRange])

      return MentionMatch(
        range: matchRange,
        text: capture
      )
    }

    return nil
  }

  public func onSelectMention(editor: Editor?, mentionName: String, mentionID: String) throws {
    guard let editor else {
      return
    }

    try editor.update {
      guard let selection = try getSelection() as? RangeSelection else { return }

      let anchor = selection.anchor

      guard let anchorNode = try anchor.getNode() as? TextNode, anchorNode.isSimpleText(), let matchRange else {
        return
      }

      let textNodesSplitByMention = try anchorNode.splitText(splitOffsets: [matchRange.lowerBound, matchRange.upperBound])
      var nodeToReplace: TextNode

      if matchRange.lowerBound == 0 {
        nodeToReplace = textNodesSplitByMention[0]
      } else {
        nodeToReplace = textNodesSplitByMention[1]
      }

      let mentionNode = createMentionNode(mention: mentionID, text: mentionName)
      try nodeToReplace.replace(replaceWith: mentionNode)
      try mentionNode.select(anchorOffset: nil, focusOffset: nil)
    }
  }

  private func handleDeleteCharacterPayload(_ payload: Any?, editor: Editor) -> Bool {
    guard let isBackwards = payload as? Bool, isBackwards else { return false }
    var handled = false
    let perform = {
      guard let selection = try getSelection() as? RangeSelection else { return }
      guard selection.isCollapsed() else { return }
      let anchor = selection.anchor
      let anchorNode = try anchor.getNode()
      if let textNode = anchorNode as? TextNode, !(textNode is MentionNode) {
        let text = textNode.getTextPart()
        if text.hasPrefix(" "), anchor.offset == 1,
          let mentionNode = textNode.getPreviousSibling() as? MentionNode
        {
          try mentionNode.remove()
          if text.count == 1 {
            try textNode.remove()
          } else {
            let updatedText = String(text.dropFirst())
            try textNode.setText(updatedText)
            try textNode.select(anchorOffset: 0, focusOffset: 0)
          }
          handled = true
          return
        }
        if anchor.offset == 0,
          let spaceNode = textNode.getPreviousSibling() as? TextNode,
          !(spaceNode is MentionNode),
          spaceNode.getTextPart() == " ",
          let mentionNode = spaceNode.getPreviousSibling() as? MentionNode
        {
          try spaceNode.remove()
          try mentionNode.remove()
          handled = true
          return
        }
        if text == " ", anchor.offset == text.lengthAsNSString(),
          let mentionNode = textNode.getPreviousSibling() as? MentionNode
        {
          try textNode.remove()
          try mentionNode.remove()
          handled = true
          return
        }
      }
      if let mentionNode = anchorNode as? MentionNode {
        try mentionNode.remove()
        handled = true
        return
      }
      if let mentionNode = try getAdjacentNode(focus: anchor, isBackward: true) as? MentionNode {
        try mentionNode.remove()
        handled = true
      }
    }
    do {
      if getActiveEditor() != nil {
        try perform()
      } else {
        try editor.update {
          try perform()
        }
      }
    } catch {
      return false
    }
    return handled
  }
}
