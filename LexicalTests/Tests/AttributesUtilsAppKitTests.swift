#if os(macOS) && !targetEnvironment(macCatalyst)
/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
@testable import Lexical
@testable import LexicalAppKit
import XCTest

@MainActor
final class AttributesUtilsAppKitTests: XCTestCase {
  func testGetLexicalAttributes_AppKit() throws {
    let view = LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor

    try editor.update {
      let textNode = TextNode()
      try textNode.setText("hello world")

      let paragraphNode = ParagraphNode()
      try paragraphNode.append([textNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])

      let attributes = AttributeUtils.getLexicalAttributes(
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )

      for attributeDict in attributes {
        if let font = attributeDict[.font] as? NSFont {
          XCTAssertEqual(font.familyName, "Helvetica", "Node font attribute is incorrect")
        }
      }
    }
  }

  private func firstFontInAttributedString(attrStr: NSAttributedString) -> NSFont {
    let font = attrStr.attribute(.font, at: 0, effectiveRange: nil)
    return font as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
  }

  func testAttributedStringByAddingStyles_AppKit() throws {
    let view = LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor

    try editor.update {
      let textNode = TextNode()
      try textNode.setText("hello world")

      let paragraphNode = ParagraphNode()
      try paragraphNode.append([textNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])

      let attributedString = NSMutableAttributedString(string: textNode.getTextPart())

      let styledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let font = firstFontInAttributedString(attrStr: styledAttrStr)

      XCTAssertEqual(font.familyName, "Helvetica", "Default font should be Helvetica")
    }
  }

  func testApplyBoldStyles_AppKit() throws {
    let view = LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor

    try editor.update {
      let textNode = TextNode()
      try textNode.setText("hello world")
      textNode.format.bold = true

      let paragraphNode = ParagraphNode()
      try paragraphNode.append([textNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])
      let attributedString = NSMutableAttributedString(string: textNode.getTextPart())
      let styledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let font = firstFontInAttributedString(attrStr: styledAttrStr)

      XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "Font should contain the bold trait")

      textNode.format.bold = false
      let newStyledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let newFont = firstFontInAttributedString(attrStr: newStyledAttrStr)

      XCTAssertFalse(newFont.fontDescriptor.symbolicTraits.contains(.bold), "Font should not contain the bold trait")
    }
  }

  func testApplyItalicStyles_AppKit() throws {
    let view = LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor

    try editor.update {
      let textNode = TextNode()
      try textNode.setText("hello world")
      textNode.format.italic = true

      let paragraphNode = ParagraphNode()
      try paragraphNode.append([textNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])
      let attributedString = NSMutableAttributedString(string: textNode.getTextPart())
      let styledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let font = firstFontInAttributedString(attrStr: styledAttrStr)

      XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic), "Font should contain the italic trait")

      textNode.format.italic = false
      let newStyledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let newFont = firstFontInAttributedString(attrStr: newStyledAttrStr)

      XCTAssertFalse(newFont.fontDescriptor.symbolicTraits.contains(.italic), "Font should not contain the italic trait")
    }
  }

  func testApplyBoldAndItalicStyles_AppKit() throws {
    let view = LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor

    try editor.update {
      let textNode = TextNode()
      try textNode.setText("hello world")
      textNode.format.bold = true
      textNode.format.italic = true

      let paragraphNode = ParagraphNode()
      try paragraphNode.append([textNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])
      let attributedString = NSMutableAttributedString(string: textNode.getTextPart())
      let styledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let font = firstFontInAttributedString(attrStr: styledAttrStr)

      XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "Font should contain the bold trait")
      XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic), "Font should contain the italic trait")

      textNode.format.bold = false
      let newStyledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: textNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let newFont = firstFontInAttributedString(attrStr: newStyledAttrStr)

      XCTAssertFalse(newFont.fontDescriptor.symbolicTraits.contains(.bold), "Font should not contain the bold trait")
      XCTAssertTrue(newFont.fontDescriptor.symbolicTraits.contains(.italic), "Font should contain the italic trait")
    }
  }

  func testFontUpdate_AppKit() throws {
    let view = LexicalView(editorConfig: EditorConfig(theme: Theme(), plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor
    try editor.update {
      let testAttributeNode = TestAttributesNode()

      let paragraphNode = ParagraphNode()
      try paragraphNode.append([testAttributeNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])

      let attributedString = NSMutableAttributedString(string: "Hello World")
      let styledAttrStr = AttributeUtils.attributedStringByAddingStyles(
        attributedString,
        from: testAttributeNode,
        state: editorState,
        theme: editor.getTheme()
      )
      let font = firstFontInAttributedString(attrStr: styledAttrStr)

      XCTAssertEqual(font.familyName, "Arial", "Font attribute is incorrect")
      XCTAssertEqual(font.pointSize, 10, "Font size is incorrect")
      XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "Font should contain the bold trait")
    }
  }

  func testThemeForRootNode_AppKit() throws {
    let rootAttributes: [NSAttributedString.Key: Any] = [
      .fontFamily: "Arial",
      .fontSize: 18 as Float
    ]

    let theme = Theme()
    theme.root = rootAttributes
    let view = LexicalView(editorConfig: EditorConfig(theme: theme, plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor

    try editor.update {
      let paragraphNode = ParagraphNode()
      let textNode = TextNode()
      try textNode.setText("Testing Theme!")

      try paragraphNode.append([textNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])
    }

    let attributedString = view.attributedText
    guard attributedString.length > 1 else {
      XCTFail("Expected non-empty attributed text")
      return
    }

    if let attribute = attributedString.attribute(.font, at: 1, effectiveRange: nil) as? NSFont {
      XCTAssertEqual(attribute.familyName, "Arial")
      XCTAssertEqual(attribute.pointSize, 18)
    } else {
      XCTFail("Expected font attribute")
    }
  }

  func testParagraphStyleKeys_AppKit() throws {
    let rootAttributes: [NSAttributedString.Key: Any] = [
      .paddingHead: 5 as Float,
      .lineHeight: 20 as Float,
      .lineSpacing: 3 as Float,
      .paragraphSpacingBefore: 7 as Float,
    ]

    let theme = Theme()
    theme.root = rootAttributes
    theme.indentSize = 10.0

    let view = LexicalView(editorConfig: EditorConfig(theme: theme, plugins: []), featureFlags: FeatureFlags())
    let editor = view.editor

    try editor.update {
      let paragraphNode = ParagraphNode()
      _ = try paragraphNode.setIndent(2)

      let textNode = TextNode()
      try textNode.setText("Hello")
      try paragraphNode.append([textNode])

      guard let editorState = getActiveEditorState(),
            let rootNode: RootNode = try editorState.getRootNode()?.getWritable()
      else {
        XCTFail("should have editor state")
        return
      }

      try rootNode.append([paragraphNode])
    }

    let attributedString = view.attributedText
    guard attributedString.length > 1 else {
      XCTFail("Expected non-empty attributed text")
      return
    }

    guard let paragraphStyle = attributedString.attribute(.paragraphStyle, at: 1, effectiveRange: nil) as? NSParagraphStyle else {
      XCTFail("Expected paragraphStyle attribute")
      return
    }

    XCTAssertEqual(paragraphStyle.firstLineHeadIndent, 25, accuracy: 0.001)
    XCTAssertEqual(paragraphStyle.headIndent, 25, accuracy: 0.001)
    XCTAssertEqual(paragraphStyle.minimumLineHeight, 20, accuracy: 0.001)
    XCTAssertEqual(paragraphStyle.lineSpacing, 3, accuracy: 0.001)
    XCTAssertEqual(paragraphStyle.paragraphSpacingBefore, 7, accuracy: 0.001)
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)

