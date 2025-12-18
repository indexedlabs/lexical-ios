/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import Lexical

final class FlagsStore {
  static let shared = FlagsStore()
  private let d = UserDefaults.standard

  // Keys
  private enum K: String {
    case strict, sanityCheck, proxyInputDelegate, verboseLogging
  }

  private init() {}

  private func b(_ k: K, _ def: Bool = false) -> Bool { d.object(forKey: k.rawValue) == nil ? def : d.bool(forKey: k.rawValue) }
  private func set(_ k: K, _ v: Bool) { d.set(v, forKey: k.rawValue); d.synchronize(); notifyChanged() }

  var strict: Bool { get { b(.strict) } set { set(.strict, newValue) } }
  var sanityCheck: Bool { get { b(.sanityCheck) } set { set(.sanityCheck, newValue) } }
  var proxyInputDelegate: Bool { get { b(.proxyInputDelegate) } set { set(.proxyInputDelegate, newValue) } }
  var verboseLogging: Bool { get { b(.verboseLogging) } set { set(.verboseLogging, newValue) } }

  func makeFeatureFlags() -> FeatureFlags {
    FeatureFlags(
      reconcilerSanityCheck: sanityCheck,
      proxyTextViewInputDelegate: proxyInputDelegate,
      reconcilerStrictMode: strict,
      verboseLogging: verboseLogging
    )
  }

  func signature() -> String {
    return [
      strict, sanityCheck, proxyInputDelegate, verboseLogging
    ].map { $0 ? "1" : "0" }.joined()
  }

  private func notifyChanged() { NotificationCenter.default.post(name: .featureFlagsDidChange, object: nil) }
}

extension Notification.Name { static let featureFlagsDidChange = Notification.Name("FeatureFlagsDidChange") }
