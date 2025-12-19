/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if canImport(UIKit)
import Foundation
import LexicalCore

@MainActor
internal func shadowCompareOptimizedVsBaseline(
  activeEditor: Editor,
  currentEditorState: EditorState,
  pendingEditorState: EditorState
) {
  // Shadow compare was used during staged rollout. It is intentionally a no-op now that the
  // optimized reconciler is the only reconciler strategy.
}
#endif
