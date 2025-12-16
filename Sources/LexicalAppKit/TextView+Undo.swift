/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Lexical

// MARK: - Undo/Redo Support

/// Undo/redo extensions for TextViewAppKit.
///
/// NSTextView provides built-in undo support. This extension ensures proper
/// integration with Lexical's history plugin.
extension TextViewAppKit {
  private static let undoCommand = CommandType(rawValue: "undo")
  private static let redoCommand = CommandType(rawValue: "redo")
  private static let canUndoCommand = CommandType(rawValue: "canUndo")
  private static let canRedoCommand = CommandType(rawValue: "canRedo")

  internal func setUpLexicalUndoRedoIntegration() {
    _ = editor.registerCommand(
      type: Self.canUndoCommand,
      listener: { [weak self] payload in
        self?.lexicalCanUndo = (payload as? Bool) ?? false
        return false
      },
      shouldWrapInUpdateBlock: false
    )

    _ = editor.registerCommand(
      type: Self.canRedoCommand,
      listener: { [weak self] payload in
        self?.lexicalCanRedo = (payload as? Bool) ?? false
        return false
      },
      shouldWrapInUpdateBlock: false
    )
  }

  // MARK: - Undo Manager

  /// The undo manager for this text view.
  ///
  /// NSTextView provides an undo manager automatically when `allowsUndo` is true.
  /// We override to potentially integrate with Lexical's history system.
  public override var undoManager: UndoManager? {
    guard allowsUndo else {
      return nil
    }

    // Use the window's undo manager if available, otherwise fall back to super
    return window?.undoManager ?? super.undoManager
  }

  // MARK: - Undo Actions

  /// Perform undo.
  @objc public func performUndo(_ sender: Any?) {
    undo(sender)
  }

  /// Perform redo.
  @objc public func performRedo(_ sender: Any?) {
    redo(sender)
  }

  /// Perform undo (standard AppKit action).
  ///
  /// Note: AppKit's `NSTextView` does not expose an overridable `undo(_:)` in Swift
  /// on modern SDKs, so we provide the action here instead of overriding.
  @IBAction @objc public func undo(_ sender: Any?) {
    guard allowsUndo else { return }
    editor.dispatchCommand(type: Self.undoCommand)
  }

  /// Perform undo with no sender.
  @objc public func undo() {
    undo(nil)
  }

  /// Perform redo (standard AppKit action).
  ///
  /// Note: AppKit's `NSTextView` does not expose an overridable `redo(_:)` in Swift
  /// on modern SDKs, so we provide the action here instead of overriding.
  @IBAction @objc public func redo(_ sender: Any?) {
    guard allowsUndo else { return }
    editor.dispatchCommand(type: Self.redoCommand)
  }

  /// Perform redo with no sender.
  @objc public func redo() {
    redo(nil)
  }

  // MARK: - Menu Validation

  /// Validate undo/redo menu items.
  public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(undo)
      || menuItem.action == #selector(undo(_:))
      || menuItem.action == #selector(performUndo(_:))
    {
      return allowsUndo && lexicalCanUndo
    }
    if menuItem.action == #selector(redo)
      || menuItem.action == #selector(redo(_:))
      || menuItem.action == #selector(performRedo(_:))
    {
      return allowsUndo && lexicalCanRedo
    }
    return super.validateMenuItem(menuItem)
  }

  // MARK: - Undo Registration

  /// Begin an undo grouping.
  ///
  /// Call this before making multiple changes that should be undone together.
  public func beginUndoGrouping() {
    undoManager?.beginUndoGrouping()
  }

  /// End an undo grouping.
  public func endUndoGrouping() {
    undoManager?.endUndoGrouping()
  }

  /// Perform changes without registering undo.
  ///
  /// Use this for changes that shouldn't be undoable, like programmatic updates.
  public func withoutUndoRegistration(_ action: () -> Void) {
    let wasEnabled = undoManager?.isUndoRegistrationEnabled ?? false

    if wasEnabled {
      undoManager?.disableUndoRegistration()
    }

    action()

    if wasEnabled {
      undoManager?.enableUndoRegistration()
    }
  }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
