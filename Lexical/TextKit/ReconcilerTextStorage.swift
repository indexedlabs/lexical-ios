/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import LexicalCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared protocol for the Lexical text storage features needed by reconciliation.
///
/// This exists to avoid a circular dependency between `Lexical` and `LexicalAppKit` while still
/// allowing the reconciler to access Lexical-specific state (e.g. `mode`, decorator cache) on
/// platform-specific `NSTextStorage` subclasses.
@MainActor
public protocol ReconcilerTextStorage: NSTextStorage {
  var mode: TextStorageEditingMode { get set }
  var decoratorPositionCache: [NodeKey: Int] { get set }
  var extraLineFragmentAttributes: [NSAttributedString.Key: Any]? { get set }
}
