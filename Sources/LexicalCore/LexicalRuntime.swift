/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

/// Global runtime defaults for Lexical.
///
/// Newly created editors/views use a single reconciler strategy across platforms.
/// `FeatureFlags` is reserved for diagnostics and safety checks (not algorithm selection).
@objc public final class LexicalRuntime: NSObject {
  /// Optional override for Objective‑C callers to replace the default flags
  /// generator. When set, this value takes precedence over the closure-based
  /// provider and the builtin mapping.
  @objc public static var defaultFeatureFlagsOverride: FeatureFlags? = nil

  /// Optional closure provider for Swift users to customize default flags
  /// (e.g., to tweak logging) without forking. Ignored if the Obj‑C override
  /// is set.
  public static var defaultFeatureFlagsProvider: (() -> FeatureFlags)? = nil

  /// The default feature flags applied by constructors that do not receive
  /// an explicit `FeatureFlags`.
  @objc public static var defaultFeatureFlags: FeatureFlags {
    if let override = defaultFeatureFlagsOverride { return override }
    if let provider = defaultFeatureFlagsProvider { return provider() }
    return FeatureFlags()
  }

}
