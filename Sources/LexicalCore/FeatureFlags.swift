/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

@objc public class FeatureFlags: NSObject {
  public let reconcilerSanityCheck: Bool
  public let proxyTextViewInputDelegate: Bool
  @available(*, deprecated, message: "Optimized reconciler is always enabled on UIKit; this flag is ignored.")
  public let useOptimizedReconciler: Bool
  public let useReconcilerFenwickDelta: Bool
  public let useReconcilerKeyedDiff: Bool
  public let useReconcilerBlockRebuild: Bool
  public let useOptimizedReconcilerStrictMode: Bool
  public let useReconcilerFenwickCentralAggregation: Bool
  public let useReconcilerShadowCompare: Bool
  public let useReconcilerInsertBlockFenwick: Bool
  public let useReconcilerDeleteBlockFenwick: Bool
  public let useReconcilerPrePostAttributesOnly: Bool
  public let useModernTextKitOptimizations: Bool
  public let verboseLogging: Bool
  public let prePostAttrsOnlyMaxTargets: Int

  // Profiles: convenience presets to reduce flag surface in product contexts.
  // Advanced flags remain available for development and testing.
  public enum OptimizedProfile {
    case minimal         // optimized + fenwick + modern batching; strict OFF
    case minimalDebug    // same as minimal, but verbose logging enabled
    case balanced        // minimal + pre/post attrs-only + insert-block
    case aggressive      // balanced + central aggregation + keyed diff + block rebuild
    case aggressiveDebug // same as aggressive, but verbose logging enabled
    case aggressiveEditor // tuned for live editing safety in the Editor tab
  }

  @objc public init(
    reconcilerSanityCheck: Bool = false,
    proxyTextViewInputDelegate: Bool = false,
    useOptimizedReconciler: Bool = true,
    useReconcilerFenwickDelta: Bool = true,
    useReconcilerKeyedDiff: Bool = true,
    useReconcilerBlockRebuild: Bool = true,
    useOptimizedReconcilerStrictMode: Bool = false,
    useReconcilerFenwickCentralAggregation: Bool = true,
    useReconcilerShadowCompare: Bool = false,
    useReconcilerInsertBlockFenwick: Bool = true,
    useReconcilerDeleteBlockFenwick: Bool = true,
    useReconcilerPrePostAttributesOnly: Bool = false,
    useModernTextKitOptimizations: Bool = true,
    verboseLogging: Bool = false,
    prePostAttrsOnlyMaxTargets: Int = 0
  ) {
    self.reconcilerSanityCheck = reconcilerSanityCheck
    self.proxyTextViewInputDelegate = proxyTextViewInputDelegate
    self.useOptimizedReconciler = true
    self.useReconcilerFenwickDelta = useReconcilerFenwickDelta
    self.useReconcilerKeyedDiff = useReconcilerKeyedDiff
    self.useReconcilerBlockRebuild = useReconcilerBlockRebuild
    self.useOptimizedReconcilerStrictMode = useOptimizedReconcilerStrictMode
    self.useReconcilerFenwickCentralAggregation = useReconcilerFenwickCentralAggregation
    self.useReconcilerShadowCompare = useReconcilerShadowCompare
    self.useReconcilerInsertBlockFenwick = useReconcilerInsertBlockFenwick
    self.useReconcilerDeleteBlockFenwick = useReconcilerDeleteBlockFenwick
    self.useReconcilerPrePostAttributesOnly = useReconcilerPrePostAttributesOnly
    self.useModernTextKitOptimizations = useModernTextKitOptimizations
    self.verboseLogging = verboseLogging
    self.prePostAttrsOnlyMaxTargets = prePostAttrsOnlyMaxTargets
    super.init()
  }

  // MARK: - Convenience Profiles
  /// A conservative optimized configuration intended to replace the historical "legacy" reconciler
  /// baseline for perf comparisons and parity tests.
  ///
  /// This keeps the optimized reconciler enabled while leaving advanced strategy toggles off.
  public static func optimizedBaseline() -> FeatureFlags {
    FeatureFlags(
      reconcilerSanityCheck: false,
      proxyTextViewInputDelegate: false,
      useOptimizedReconciler: true,
      useReconcilerFenwickDelta: false,
      useReconcilerKeyedDiff: false,
      useReconcilerBlockRebuild: false,
      useOptimizedReconcilerStrictMode: true,
      useReconcilerFenwickCentralAggregation: false,
      useReconcilerShadowCompare: false,
      useReconcilerInsertBlockFenwick: false,
      useReconcilerDeleteBlockFenwick: false,
      useReconcilerPrePostAttributesOnly: false,
      useModernTextKitOptimizations: true,
      verboseLogging: false,
      prePostAttrsOnlyMaxTargets: 0
    )
  }

  public static func optimizedProfile(_ p: OptimizedProfile) -> FeatureFlags {
    switch p {
    case .minimal:
      return FeatureFlags(
        reconcilerSanityCheck: false,
        proxyTextViewInputDelegate: false,
        useOptimizedReconciler: true,
        useReconcilerFenwickDelta: true,
        useReconcilerKeyedDiff: false,
        useReconcilerBlockRebuild: false,
        useOptimizedReconcilerStrictMode: true,
        useReconcilerFenwickCentralAggregation: false,
        useReconcilerShadowCompare: false,
        useReconcilerInsertBlockFenwick: true,
        useReconcilerDeleteBlockFenwick: true,
        useReconcilerPrePostAttributesOnly: false,
        useModernTextKitOptimizations: true,
        verboseLogging: false,
        prePostAttrsOnlyMaxTargets: 16
      )
    case .minimalDebug:
      return FeatureFlags(
        reconcilerSanityCheck: false,
        proxyTextViewInputDelegate: false,
        useOptimizedReconciler: true,
        useReconcilerFenwickDelta: true,
        useReconcilerKeyedDiff: false,
        useReconcilerBlockRebuild: false,
        useOptimizedReconcilerStrictMode: true,
        useReconcilerFenwickCentralAggregation: false,
        useReconcilerShadowCompare: false,
        useReconcilerInsertBlockFenwick: true,
        useReconcilerDeleteBlockFenwick: true,
        useReconcilerPrePostAttributesOnly: false,
        useModernTextKitOptimizations: true,
        verboseLogging: true,
        prePostAttrsOnlyMaxTargets: 16
      )
    case .balanced:
      return FeatureFlags(
        reconcilerSanityCheck: false,
        proxyTextViewInputDelegate: false,
        useOptimizedReconciler: true,
        useReconcilerFenwickDelta: true,
        useReconcilerKeyedDiff: false,
        useReconcilerBlockRebuild: false,
        useOptimizedReconcilerStrictMode: true,
        useReconcilerFenwickCentralAggregation: false,
        useReconcilerShadowCompare: false,
        useReconcilerInsertBlockFenwick: true,
        useReconcilerDeleteBlockFenwick: true,
        useReconcilerPrePostAttributesOnly: true,
        useModernTextKitOptimizations: true,
        verboseLogging: false,
        prePostAttrsOnlyMaxTargets: 16
      )
    case .aggressive:
      return FeatureFlags(
        reconcilerSanityCheck: false,
        proxyTextViewInputDelegate: false,
        useOptimizedReconciler: true,
        useReconcilerFenwickDelta: true,
        useReconcilerKeyedDiff: true,
        useReconcilerBlockRebuild: true,
        useOptimizedReconcilerStrictMode: true,
        useReconcilerFenwickCentralAggregation: true,
        useReconcilerInsertBlockFenwick: true,
        useReconcilerDeleteBlockFenwick: true,
        useReconcilerPrePostAttributesOnly: true,
        useModernTextKitOptimizations: true,
        verboseLogging: false,
        prePostAttrsOnlyMaxTargets: 16
      )
    case .aggressiveDebug:
      return FeatureFlags(
        reconcilerSanityCheck: false,
        proxyTextViewInputDelegate: false,
        useOptimizedReconciler: true,
        useReconcilerFenwickDelta: true,
        useReconcilerKeyedDiff: true,
        useReconcilerBlockRebuild: true,
        useOptimizedReconcilerStrictMode: true,
        useReconcilerFenwickCentralAggregation: true,
        useReconcilerInsertBlockFenwick: true,
        useReconcilerDeleteBlockFenwick: true,
        useReconcilerPrePostAttributesOnly: true,
        useModernTextKitOptimizations: true,
        verboseLogging: true,
        prePostAttrsOnlyMaxTargets: 16
      )
    case .aggressiveEditor:
      return FeatureFlags(
        reconcilerSanityCheck: false,
        proxyTextViewInputDelegate: false,
        useOptimizedReconciler: true,
        useReconcilerFenwickDelta: true,
        useReconcilerKeyedDiff: true,
        useReconcilerBlockRebuild: true,
        useOptimizedReconcilerStrictMode: false,
        useReconcilerFenwickCentralAggregation: true,
        useReconcilerShadowCompare: false,
        useReconcilerInsertBlockFenwick: true,
        useReconcilerDeleteBlockFenwick: true,
        useReconcilerPrePostAttributesOnly: false,
        useModernTextKitOptimizations: true,
        verboseLogging: false,
        prePostAttrsOnlyMaxTargets: 0
      )
    }
  }
}
