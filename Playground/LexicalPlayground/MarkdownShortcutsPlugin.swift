import Foundation
@preconcurrency import Lexical
import LexicalListPlugin

class MarkdownShortcutsPlugin: Plugin {
  weak var editor: Editor?

  public func setUp(editor: Editor) {
    self.editor = editor

    _ = editor.addNodeTransform(
      nodeType: NodeType.text,
      transform: { node in
        try self.checkForMarkdownShortcuts(node: node)
      }
    )
  }

  public func tearDown() {}

  private func checkForMarkdownShortcuts(node: Node) throws {
    try transformToList(node: node)
  }

  public func transformToList(node: Node) throws {
    guard
      let textNode = node as? TextNode,
      let parent = textNode.getParent() as? ParagraphNode,
      isFirstTextNodeInAnElementNode(node: textNode)
    else { return }

    let text = textNode.getTextContent()
    var listNode: ListNode?
    var listItemNode: ListItemNode?
    var newText: String?
    if text.hasPrefix("* ") || text.hasPrefix("- ") {
      listItemNode = ListItemNode()
      listNode = createListNode(listType: .bullet)
      newText = String(text.dropFirst(2))
    } else if text.hasPrefix("1. ") {
      listItemNode = ListItemNode()
      listNode = createListNode(listType: .number)
      newText = String(text.dropFirst(3))
    }

    if let listNode = listNode,
      let listItemNode = listItemNode,
      let newText = newText
    {
      let listItemNodeChild = createTextNode(text: newText)
      try listItemNodeChild.select(anchorOffset: 0, focusOffset: 0)
      try listItemNode.append([listItemNodeChild])

      try listNode.append([listItemNode])
      try parent.replace(replaceWith: listNode)
    }
  }

  private func isFirstTextNodeInAnElementNode(node: Node) -> Bool {
    guard
      let textNode = node as? TextNode,
      let parent = textNode.getParent(),
      parent.getFirstChild() != nil
    else { return false }

    if textNode == parent.getFirstChild() {
      return true
    }

    return false
  }
}
