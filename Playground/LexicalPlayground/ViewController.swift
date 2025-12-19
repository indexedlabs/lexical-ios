/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import EditorHistoryPlugin
import Lexical
import LexicalInlineImagePlugin
import LexicalLinkPlugin
import LexicalListPlugin
import UIKit

class ViewController: UIViewController, UIToolbarDelegate {

  var lexicalView: LexicalView?
  weak var toolbar: UIToolbar?
  weak var hierarchyView: UIView?
  private let editorStatePersistenceKey = "editorState"
  private let debugPanelVisibilityKey = "debugPanelVisible"
  private var isDebugPanelVisible: Bool = true
  private var featuresBarButton: UIBarButtonItem!
  private var activeFlags: FeatureFlags = FlagsStore.shared.makeFeatureFlags()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    isDebugPanelVisible = UserDefaults.standard.object(forKey: debugPanelVisibilityKey) as? Bool ?? true

    // Always use the single reconciler in the Playground.
    rebuildEditor()
    // Clear persisted state for debugging (start fresh with just an image)
    UserDefaults.standard.removeObject(forKey: editorStatePersistenceKey)
    // Immediately restore any persisted editor state to avoid a first-cycle
    // empty hydration and ensure TS has content before user input.
    restoreEditorState()

    navigationItem.title = "Lexical"
    setUpExportMenu()
    // Add Features menu next to Export
    featuresBarButton = UIBarButtonItem(title: "Features", style: .plain, target: nil, action: nil)
    if let exportItem = navigationItem.rightBarButtonItem {
      navigationItem.rightBarButtonItems = [exportItem, featuresBarButton]
      navigationItem.rightBarButtonItem = nil
    } else {
      navigationItem.rightBarButtonItems = [featuresBarButton]
    }
    updateFeaturesMenu()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    if let lexicalView, let toolbar, let hierarchyView {
      let safeAreaInsets = self.view.safeAreaInsets
      let hierarchyViewHeight = isDebugPanelVisible ? 300.0 : 0.0
      hierarchyView.isHidden = !isDebugPanelVisible

      toolbar.frame = CGRect(x: 0,
                             y: safeAreaInsets.top,
                             width: view.bounds.width,
                             height: 44)
      lexicalView.frame = CGRect(x: 0,
                                 y: toolbar.frame.maxY,
                                 width: view.bounds.width,
                                 height: view.bounds.height - toolbar.frame.maxY - safeAreaInsets.bottom - hierarchyViewHeight)
      hierarchyView.frame = CGRect(x: 0,
                                   y: lexicalView.frame.maxY,
                                   width: view.bounds.width,
                                   height: hierarchyViewHeight)
    }
  }

  func persistEditorState() {
    guard let editor = lexicalView?.editor else {
      return
    }

    let currentEditorState = editor.getEditorState()

    // turn the editor state into stringified JSON
    guard let jsonString = try? currentEditorState.toJSON() else {
      return
    }

    UserDefaults.standard.set(jsonString, forKey: editorStatePersistenceKey)
  }

  func restoreEditorState() {
    guard let editor = lexicalView?.editor else {
      return
    }

    // Try to restore from persisted state
    if let jsonString = UserDefaults.standard.value(forKey: editorStatePersistenceKey) as? String,
       let newEditorState = try? EditorState.fromJSON(json: jsonString, editor: editor) {
      try? editor.setEditorState(newEditorState)
      return
    }

    // No persisted state - set up default state with just an image for testing
    setUpDefaultStateWithImage()
  }

  private func setUpDefaultStateWithImage() {
    guard let editor = lexicalView?.editor else { return }

    try? editor.update {
      guard let root = getRoot() else { return }
      // Clear existing content
      try root.getChildren().forEach { try $0.remove() }

      // Create a paragraph with just an image
      let paragraph = createParagraphNode()
      let imageNode = ImageNode(url: "https://placecats.com/300/200", size: CGSize(width: 300, height: 200), sourceID: "test-image")
      try paragraph.append([imageNode])
      try root.append([paragraph])

      // Add an empty paragraph after for cursor placement
      let emptyParagraph = createParagraphNode()
      try root.append([emptyParagraph])
    }
  }

  func setUpExportMenu() {
    let menuItems = OutputFormat.allCases.map { outputFormat in
      UIAction(title: "Export \(outputFormat.title)", handler: { [weak self] action in
        self?.showExportScreen(outputFormat)
      })
    }
    let menu = UIMenu(title: "Export as…", children: menuItems)
    let barButtonItem = UIBarButtonItem(title: "Export", style: .plain, target: nil, action: nil)
    barButtonItem.menu = menu
    navigationItem.rightBarButtonItem = barButtonItem
  }

  func showExportScreen(_ type: OutputFormat) {
    guard let editor = lexicalView?.editor else { return }
    let vc = ExportOutputViewController(editor: editor, format: type)
    navigationController?.pushViewController(vc, animated: true)
  }

  func position(for bar: UIBarPositioning) -> UIBarPosition {
    return .top
  }

  private func rebuildEditor() {
    // Clean old views
    lexicalView?.removeFromSuperview()
    toolbar?.removeFromSuperview()
    hierarchyView?.removeFromSuperview()

    // Plugins
    let editorHistoryPlugin = EditorHistoryPlugin()
    let toolbarPlugin = ToolbarPlugin(viewControllerForPresentation: self, historyPlugin: editorHistoryPlugin)
    let toolbar = toolbarPlugin.toolbar
    toolbar.delegate = self
    let hierarchyPlugin = NodeHierarchyViewPlugin()
    let hierarchyView = hierarchyPlugin.hierarchyView
    let listPlugin = ListPlugin()
    let imagePlugin = InlineImagePlugin()
    let linkPlugin = LinkPlugin()

    // Theme
    let theme = Theme()
    theme.setBlockLevelAttributes(.heading, value: BlockLevelAttributes(marginTop: 0, marginBottom: 0, paddingTop: 0, paddingBottom: 20))
    theme.indentSize = 40.0
    theme.link = [ .foregroundColor: UIColor.systemBlue ]

    // Feature flags
    let flags: FeatureFlags = activeFlags

    let debugMetricsContainer = PlaygroundDebugMetricsContainer(onReconcilerRun: { [weak hierarchyPlugin] run in
      hierarchyPlugin?.logReconcilerRun(run)
    })
    let editorConfig = EditorConfig(
      theme: theme,
      plugins: [toolbarPlugin, listPlugin, hierarchyPlugin, imagePlugin, linkPlugin, editorHistoryPlugin],
      metricsContainer: debugMetricsContainer
    )
    let lexicalView = LexicalView(editorConfig: editorConfig, featureFlags: flags)
    linkPlugin.lexicalView = lexicalView
    hierarchyPlugin.lexicalView = lexicalView

    self.lexicalView = lexicalView
    self.toolbar = toolbar
    self.hierarchyView = hierarchyView

    hierarchyView.isHidden = !isDebugPanelVisible

    view.addSubview(lexicalView)
    view.addSubview(toolbar)
    view.addSubview(hierarchyView)

    view.setNeedsLayout()
    view.layoutIfNeeded()
  }

  // MARK: - Features menu (flags)
  private func updateFeaturesMenu() {
    func coreToggle(_ name: String, _ isOn: Bool) -> UIAction {
      UIAction(title: name, state: isOn ? .on : .off, handler: { [weak self] _ in
        guard let self else { return }
        let store = FlagsStore.shared
        switch name {
        case "strict-mode": store.strict.toggle()
        case "sanity-check": store.sanityCheck.toggle()
        case "proxy-input-delegate": store.proxyInputDelegate.toggle()
        case "verbose-logging": store.verboseLogging.toggle()
        default: break
        }
        self.activeFlags = store.makeFeatureFlags()
        self.updateFeaturesMenu()
        self.persistEditorState(); self.rebuildEditor(); self.restoreEditorState()
      })
    }
    let debugPanelToggle = UIAction(
      title: "Debug panel",
      state: isDebugPanelVisible ? .on : .off,
      handler: { [weak self] _ in
        guard let self else { return }
        self.isDebugPanelVisible.toggle()
        UserDefaults.standard.set(self.isDebugPanelVisible, forKey: self.debugPanelVisibilityKey)
        self.updateFeaturesMenu()
        UIView.animate(withDuration: 0.2) {
          self.view.setNeedsLayout()
          self.view.layoutIfNeeded()
        }
      }
    )
    let debugMenu = UIMenu(title: "Debug", options: .displayInline, children: [debugPanelToggle])
    let toggles: [UIAction] = [
      coreToggle("strict-mode", activeFlags.reconcilerStrictMode),
      coreToggle("sanity-check", activeFlags.reconcilerSanityCheck),
      coreToggle("proxy-input-delegate", activeFlags.proxyTextViewInputDelegate),
      coreToggle("verbose-logging", activeFlags.verboseLogging)
    ]
    featuresBarButton.menu = UIMenu(title: "Features", children: [debugMenu] + toggles)
  }
}

@MainActor
final class PlaygroundDebugMetricsContainer: NSObject, EditorMetricsContainer {
  private let onReconcilerRun: (ReconcilerMetric) -> Void

  init(onReconcilerRun: @escaping (ReconcilerMetric) -> Void) {
    self.onReconcilerRun = onReconcilerRun
  }

  func record(_ metric: EditorMetric) {
    if case let .reconcilerRun(run) = metric {
      onReconcilerRun(run)
    }
  }

  func resetMetrics() {
    // No-op: the Playground debug panel keeps an external action log.
  }
}
