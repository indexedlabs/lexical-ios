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
  public let reconcilerStrictMode: Bool
  public let useModernTextKitOptimizations: Bool
  public let verboseLogging: Bool

  @objc public init(
    reconcilerSanityCheck: Bool = false,
    proxyTextViewInputDelegate: Bool = false,
    reconcilerStrictMode: Bool = false,
    useModernTextKitOptimizations: Bool = true,
    verboseLogging: Bool = false
  ) {
    self.reconcilerSanityCheck = reconcilerSanityCheck
    self.proxyTextViewInputDelegate = proxyTextViewInputDelegate
    self.reconcilerStrictMode = reconcilerStrictMode
    self.useModernTextKitOptimizations = useModernTextKitOptimizations
    self.verboseLogging = verboseLogging
    super.init()
  }
}
