/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import XCTest
@testable import Lexical

@MainActor
final class ReconcilerMetricsCollector: EditorMetricsContainer {
  private(set) var reconcilerRuns: [ReconcilerMetric] = []

  func record(_ metric: EditorMetric) {
    if case let .reconcilerRun(run) = metric {
      reconcilerRuns.append(run)
    }
  }

  func resetMetrics() {
    reconcilerRuns.removeAll()
  }

  func summarize(label: String) -> ReconcilerMetricsSummary {
    ReconcilerMetricsSummary(label: label, runs: reconcilerRuns)
  }

  func makeAttachment(label: String, name: String = "reconciler-metrics") -> XCTAttachment {
    let summary = summarize(label: label)
    let attachment = XCTAttachment(string: summary.prettyPrintedJSON ?? summary.debugDescription)
    attachment.name = "\(name) (\(label))"
    return attachment
  }
}

struct ReconcilerMetricsSummary: Codable, CustomDebugStringConvertible {
  struct Percentiles: Codable {
    let p50: TimeInterval
    let p90: TimeInterval
    let p95: TimeInterval
    let p99: TimeInterval
    let min: TimeInterval
    let max: TimeInterval
  }

  struct Counters: Codable {
    let dirtyNodes: Int
    let rangesAdded: Int
    let rangesDeleted: Int
    let deleteCount: Int
    let insertCount: Int
    let setAttributesCount: Int
    let fixAttributesCount: Int
    let movedChildren: Int
  }

  let label: String
  let runs: Int
  let totalDuration: TimeInterval
  let avgDuration: TimeInterval
  let duration: Percentiles
  let planning: Percentiles
  let apply: Percentiles
  let counters: Counters
  let treatedAllNodesAsDirtyRuns: Int
  let pathHistogram: [String: Int]

  init(label: String, runs: [ReconcilerMetric]) {
    self.label = label
    self.runs = runs.count

    func percentiles(_ values: [TimeInterval]) -> Percentiles {
      guard !values.isEmpty else {
        return Percentiles(p50: 0, p90: 0, p95: 0, p99: 0, min: 0, max: 0)
      }
      let sorted = values.sorted()
      func at(_ q: Double) -> TimeInterval {
        let clamped = max(0, min(1, q))
        let rawIndex = clamped * Double(sorted.count - 1)
        let low = Int(floor(rawIndex))
        let high = Int(ceil(rawIndex))
        if low == high { return sorted[low] }
        let t = rawIndex - Double(low)
        return sorted[low] * (1 - t) + sorted[high] * t
      }
      return Percentiles(
        p50: at(0.50),
        p90: at(0.90),
        p95: at(0.95),
        p99: at(0.99),
        min: sorted.first ?? 0,
        max: sorted.last ?? 0
      )
    }

    let durations = runs.map(\.duration)
    let planningDurations = runs.map(\.planningDuration)
    let applyDurations = runs.map(\.applyDuration)

    self.totalDuration = durations.reduce(0, +)
    self.avgDuration = durations.isEmpty ? 0 : (self.totalDuration / Double(durations.count))
    self.duration = percentiles(durations)
    self.planning = percentiles(planningDurations)
    self.apply = percentiles(applyDurations)

    self.counters = Counters(
      dirtyNodes: runs.reduce(0) { $0 + $1.dirtyNodes },
      rangesAdded: runs.reduce(0) { $0 + $1.rangesAdded },
      rangesDeleted: runs.reduce(0) { $0 + $1.rangesDeleted },
      deleteCount: runs.reduce(0) { $0 + $1.deleteCount },
      insertCount: runs.reduce(0) { $0 + $1.insertCount },
      setAttributesCount: runs.reduce(0) { $0 + $1.setAttributesCount },
      fixAttributesCount: runs.reduce(0) { $0 + $1.fixAttributesCount },
      movedChildren: runs.reduce(0) { $0 + $1.movedChildren }
    )

    self.treatedAllNodesAsDirtyRuns = runs.reduce(0) { $0 + ($1.treatedAllNodesAsDirty ? 1 : 0) }

    var histogram: [String: Int] = [:]
    for run in runs {
      let label = run.pathLabel ?? "unknown"
      histogram[label, default: 0] += 1
    }
    self.pathHistogram = histogram
  }

  var prettyPrintedJSON: String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  var debugDescription: String {
    "ReconcilerMetricsSummary(label=\(label) runs=\(runs) total=\(totalDuration)s avg=\(avgDuration)s duration(p50=\(duration.p50)s p95=\(duration.p95)s max=\(duration.max)s) counters(ranges +\(counters.rangesAdded)/-\(counters.rangesDeleted) del=\(counters.deleteCount) ins=\(counters.insertCount) attrs=\(counters.setAttributesCount)+\(counters.fixAttributesCount)) paths=\(pathHistogram))"
  }
}

@MainActor
func measureWallTime(_ block: () throws -> Void) rethrows -> TimeInterval {
  let start = CFAbsoluteTimeGetCurrent()
  try block()
  return CFAbsoluteTimeGetCurrent() - start
}

