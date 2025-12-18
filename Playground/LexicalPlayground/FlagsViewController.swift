/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import UIKit

final class FlagsViewController: UITableViewController {
  private enum Section: Int, CaseIterable { case reconciler, input, diagnostics }
  private struct Row { let title: String; let keyPath: WritableKeyPath<FlagsStore, Bool> }
  private var sections: [[Row]] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Flags"
    tableView = UITableView(frame: .zero, style: .insetGrouped)
    buildModel()
  }

  private func buildModel() {
    sections = [
      // Reconciler
      [
        Row(title: "Strict Mode", keyPath: \.strict),
        Row(title: "Reconciler Sanity Check", keyPath: \.sanityCheck),
      ],
      // Input / TextKit
      [
        Row(title: "Proxy InputDelegate", keyPath: \.proxyInputDelegate),
        Row(title: "Modern TextKit Optimizations", keyPath: \.modernTextKit),
      ],
      // Diagnostics
      [
        Row(title: "Verbose Logging", keyPath: \.verboseLogging),
      ]
    ]
  }

  override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch Section(rawValue: section)! {
    case .reconciler: return "Reconciler"
    case .input: return "Input / TextKit"
    case .diagnostics: return "Diagnostics"
    }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    let row = sections[indexPath.section][indexPath.row]
    cell.textLabel?.text = row.title
    let sw = UISwitch()
    sw.isOn = FlagsStore.shared[keyPath: row.keyPath]
    sw.addTarget(self, action: #selector(onSwitchChanged(_:)), for: .valueChanged)
    sw.tag = (indexPath.section << 16) | indexPath.row
    cell.accessoryView = sw
    return cell
  }

  @objc private func onSwitchChanged(_ sender: UISwitch) {
    let section = sender.tag >> 16
    let rowIndex = sender.tag & 0xFFFF
    let row = sections[section][rowIndex]
    var store = FlagsStore.shared
    store[keyPath: row.keyPath] = sender.isOn
  }
}
