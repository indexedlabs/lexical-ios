/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)
import Foundation
import MobileCoreServices
import UIKit
import LexicalCore
import UniformTypeIdentifiers

@MainActor
internal func setPasteboard(selection: BaseSelection, pasteboard: UIPasteboard) throws {
  guard let editor = getActiveEditor() else {
    throw LexicalError.invariantViolation("Could not get editor")
  }
  let nodes = try generateArrayFromSelectedNodes(editor: editor, selection: selection).nodes
  let text = try selection.getTextContent()
  let encodedData = try JSONEncoder().encode(nodes)
  guard let jsonString = String(data: encodedData, encoding: .utf8) else { return }

  let itemProvider = NSItemProvider()
  itemProvider.registerItem(forTypeIdentifier: LexicalConstants.pasteboardIdentifier) {
    completionHandler, expectedValueClass, options in
    let data = NSData(data: jsonString.data(using: .utf8) ?? Data())
    completionHandler?(data, nil)
  }

  if #available(iOS 14.0, *) {
    pasteboard.items =
      [
        [
          (UTType.rtf.identifier): try getAttributedStringFromFrontend().data(
            from: NSRange(location: 0, length: getAttributedStringFromFrontend().length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        ],
        [LexicalConstants.pasteboardIdentifier: encodedData],
      ]
    if ProcessInfo.processInfo.isMacCatalystApp {
      // added this to enable copy/paste in the mac catalyst app
      // the problem is in the TextView.canPerformAction
      // after copy on iOS pasteboard.hasStrings returns true but on Mac it returns false for some reason
      // setting this string here will make it return true, pasting will take serialized nodes from the pasteboard
      // anyhow so this should not have any adverse effect
      pasteboard.string = text
    }
  } else {
    pasteboard.items =
      [
        [
          (kUTTypeRTF as String): try getAttributedStringFromFrontend().data(
            from: NSRange(location: 0, length: getAttributedStringFromFrontend().length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        ],
        [LexicalConstants.pasteboardIdentifier: encodedData],
      ]
  }
}

@MainActor
internal func insertDataTransferForRichText(selection: RangeSelection, pasteboard: UIPasteboard)
  throws
{
  let largePasteCharacterThreshold = 10_000

  let itemSet: IndexSet?
  if #available(iOS 14.0, *) {
    itemSet = pasteboard.itemSet(
      withPasteboardTypes: [
        (UTType.utf8PlainText.identifier),
        (UTType.url.identifier),
        LexicalConstants.pasteboardIdentifier,
      ]
    )
  } else {
    itemSet = pasteboard.itemSet(
      withPasteboardTypes: [
        (kUTTypeUTF8PlainText as String),
        (kUTTypeURL as String),
        LexicalConstants.pasteboardIdentifier,
      ]
    )
  }

  if let pasteboardData = pasteboard.data(
    forPasteboardType: LexicalConstants.pasteboardIdentifier,
    inItemSet: itemSet)?.last
  {
    let deserializedNodes = try JSONDecoder().decode(SerializedNodeArray.self, from: pasteboardData)

    guard let editor = getActiveEditor() else { return }

    _ = try insertGeneratedNodes(
      editor: editor, nodes: deserializedNodes.nodeArray, selection: selection)
    return
  }

  // For very large pastes, prefer plain text even if rich text (RTF) is present.
  // Parsing large RTF payloads can be extremely expensive and memory intensive, and most
  // large pastes are better treated as plain text (e.g., markdown/code).
  if #available(iOS 14.0, *) {
    if let pasteboardStringData = pasteboard.data(
      forPasteboardType: (UTType.utf8PlainText.identifier),
      inItemSet: itemSet)?.last
    {
      let plain = String(decoding: pasteboardStringData, as: UTF8.self)
      if plain.utf16.count >= largePasteCharacterThreshold {
        try insertPlainText(selection: selection, text: plain)
        return
      }
    }
  } else {
    if let pasteboardStringData = pasteboard.data(
      forPasteboardType: (kUTTypeUTF8PlainText as String),
      inItemSet: itemSet)?.last
    {
      let plain = String(decoding: pasteboardStringData, as: UTF8.self)
      if plain.utf16.count >= largePasteCharacterThreshold {
        try insertPlainText(selection: selection, text: plain)
        return
      }
    }
  }

  if let plain = pasteboard.string, plain.utf16.count >= largePasteCharacterThreshold {
    try insertPlainText(selection: selection, text: plain)
    return
  }

  if #available(iOS 14.0, *) {
    if let pasteboardRTFData = pasteboard.data(
      forPasteboardType: (UTType.rtf.identifier),
      inItemSet: itemSet)?.last
    {
      let attributedString = try NSAttributedString(
        data: pasteboardRTFData,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      )
      try insertRTF(selection: selection, attributedString: attributedString)
      return
    }
  } else {
    if let pasteboardRTFData = pasteboard.data(
      forPasteboardType: (kUTTypeRTF as String),
      inItemSet: itemSet)?.last
    {
      let attributedString = try NSAttributedString(
        data: pasteboardRTFData,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      )

      try insertRTF(selection: selection, attributedString: attributedString)
      return
    }
  }

  if #available(iOS 14.0, *) {
    if let pasteboardStringData = pasteboard.data(
      forPasteboardType: (UTType.utf8PlainText.identifier),
      inItemSet: itemSet)?.last
    {
      try insertPlainText(
        selection: selection, text: String(decoding: pasteboardStringData, as: UTF8.self))
      return
    }
  } else {
    if let pasteboardStringData = pasteboard.data(
      forPasteboardType: (kUTTypeUTF8PlainText as String),
      inItemSet: itemSet)?.last
    {
      try insertPlainText(
        selection: selection, text: String(decoding: pasteboardStringData, as: UTF8.self))
      return
    }
  }

  if let url = pasteboard.urls?.first as? URL {
    let string = url.absoluteString
    try insertPlainText(selection: selection, text: string)
    return
  }
}

@MainActor
internal func insertRTF(selection: RangeSelection, attributedString: NSAttributedString) throws {
  let paragraphs = attributedString.splitByNewlines()

  var nodes: [Node] = []
  var i = 0

  for paragraph in paragraphs {
    var extractedAttributes = [(attributes: [NSAttributedString.Key: Any], range: NSRange)]()
    paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) {
      (dict, range, stopEnumerating) in
      extractedAttributes.append((attributes: dict, range: range))
    }

    var nodeArray: [Node] = []
    for attribute in extractedAttributes {
      let text = paragraph.attributedSubstring(from: attribute.range).string
      let textNode = createTextNode(text: text)

      if (attribute.attributes.first(where: { $0.key == .font })?.value as? UIFont)?
        .fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
      {
        textNode.format.bold = true
      }

      if (attribute.attributes.first(where: { $0.key == .font })?.value as? UIFont)?
        .fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false
      {
        textNode.format.italic = true
      }

      if let underlineAttribute = attribute.attributes[.underlineStyle] {
        if underlineAttribute as? NSNumber != 0 {
          textNode.format.underline = true
        }
      }

      if let strikethroughAttribute = attribute.attributes[.strikethroughStyle] {
        if strikethroughAttribute as? NSNumber != 0 {
          textNode.format.strikethrough = true
        }
      }

      nodeArray.append(textNode)
    }

    if i != 0 {
      let paragraphNode = createParagraphNode()
      try paragraphNode.append(nodeArray)
      nodes.append(paragraphNode)
    } else {
      nodes.append(contentsOf: nodeArray)
    }
    i += 1
  }

  _ = try selection.insertNodes(nodes: nodes, selectStart: false)
}
#endif  // canImport(UIKit)
