/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import Lexical
import LexicalListPlugin
import UIKit

// MARK: - Debug Action Log Entry

struct DebugAction: CustomStringConvertible {
  let timestamp: Date
  let action: String
  let details: String

  var description: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return "[\(formatter.string(from: timestamp))] \(action): \(details)"
  }
}

public class NodeHierarchyViewPlugin: Plugin {
  private var containerView: UIView!
  private var segmentedControl: UISegmentedControl!
  private var _hierarchyView: UITextView!
  private var _actionLogView: UITextView!
  private var _snapshotView: UITextView!
  private var selectionLabel: UILabel!
  private var buttonStack: UIStackView!
  private var debugOptionsStack: UIStackView!
  private var debugOptionsHeightConstraint: NSLayoutConstraint!

  weak var editor: Editor?
  weak var lexicalView: LexicalView? {
    didSet {
      updateSelectionDisplay()
      attachNativeObserversIfNeeded()
    }
  }

  // Debug state
  private var actionLog: [DebugAction] = []
  private var commandListenerRemovers: [() -> Void] = []
  private var nativeObserverTokens: [NSObjectProtocol] = []
  private var pendingSnapshotUpdate: DispatchWorkItem?

  private var captureTextKitEvents = true
  private var captureReconcilerMetrics = true
  private var captureLayoutEvents = true
  private var captureIntegrityChecks = true

  init() {
    setupViews()
  }

  deinit {
    for token in nativeObserverTokens {
      NotificationCenter.default.removeObserver(token)
    }
    nativeObserverTokens.removeAll()
  }

  private func setupViews() {
    containerView = UIView()
    containerView.backgroundColor = .black

    // Segmented control for switching between views
    segmentedControl = UISegmentedControl(items: ["Hierarchy", "Action Log", "Snapshot"])
    segmentedControl.selectedSegmentIndex = 0
    segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
    segmentedControl.translatesAutoresizingMaskIntoConstraints = false

    // Selection label at top
    selectionLabel = UILabel()
    selectionLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    selectionLabel.textColor = .systemGreen
    selectionLabel.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
    selectionLabel.numberOfLines = 3
    selectionLabel.text = "Selection: --"
    selectionLabel.translatesAutoresizingMaskIntoConstraints = false

    // Hierarchy view
    _hierarchyView = UITextView()
    _hierarchyView.backgroundColor = .black
    _hierarchyView.textColor = .white
    _hierarchyView.isEditable = false
    _hierarchyView.isUserInteractionEnabled = true
    _hierarchyView.isScrollEnabled = true
    _hierarchyView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    _hierarchyView.showsVerticalScrollIndicator = true
    _hierarchyView.translatesAutoresizingMaskIntoConstraints = false

    // Action log view
    _actionLogView = UITextView()
    _actionLogView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
    _actionLogView.textColor = .systemGray
    _actionLogView.isEditable = false
    _actionLogView.isUserInteractionEnabled = true
    _actionLogView.isScrollEnabled = true
    _actionLogView.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    _actionLogView.showsVerticalScrollIndicator = true
    _actionLogView.translatesAutoresizingMaskIntoConstraints = false
    _actionLogView.isHidden = true

    // Snapshot view
    _snapshotView = UITextView()
    _snapshotView.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
    _snapshotView.textColor = .systemGray
    _snapshotView.isEditable = false
    _snapshotView.isUserInteractionEnabled = true
    _snapshotView.isScrollEnabled = true
    _snapshotView.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    _snapshotView.showsVerticalScrollIndicator = true
    _snapshotView.translatesAutoresizingMaskIntoConstraints = false
    _snapshotView.isHidden = true

    // Debug capture toggles (hidden by default)
    debugOptionsStack = UIStackView()
    debugOptionsStack.axis = .vertical
    debugOptionsStack.spacing = 6
    debugOptionsStack.translatesAutoresizingMaskIntoConstraints = false
    debugOptionsStack.isHidden = true

    func makeToggleRow(title: String, initial: Bool, onChange: @escaping (Bool) -> Void) -> UIView {
      let label = UILabel()
      label.text = title
      label.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
      label.textColor = .systemGray

      let toggle = UISwitch()
      toggle.isOn = initial
      toggle.addAction(UIAction { _ in
        onChange(toggle.isOn)
      }, for: .valueChanged)

      let row = UIStackView(arrangedSubviews: [label, toggle])
      row.axis = .horizontal
      row.spacing = 8
      row.alignment = .center
      return row
    }

    debugOptionsStack.addArrangedSubview(makeToggleRow(
      title: "captureTextKitEvents",
      initial: captureTextKitEvents,
      onChange: { [weak self] isOn in
        self?.captureTextKitEvents = isOn
        self?.logAction("debug", details: "captureTextKitEvents=\(isOn)")
      }
    ))
    debugOptionsStack.addArrangedSubview(makeToggleRow(
      title: "captureReconcilerMetrics",
      initial: captureReconcilerMetrics,
      onChange: { [weak self] isOn in
        self?.captureReconcilerMetrics = isOn
        self?.logAction("debug", details: "captureReconcilerMetrics=\(isOn)")
      }
    ))
    debugOptionsStack.addArrangedSubview(makeToggleRow(
      title: "captureLayoutEvents",
      initial: captureLayoutEvents,
      onChange: { [weak self] isOn in
        self?.captureLayoutEvents = isOn
        self?.logAction("debug", details: "captureLayoutEvents=\(isOn)")
      }
    ))
    debugOptionsStack.addArrangedSubview(makeToggleRow(
      title: "captureIntegrityChecks",
      initial: captureIntegrityChecks,
      onChange: { [weak self] isOn in
        self?.captureIntegrityChecks = isOn
        self?.logAction("debug", details: "captureIntegrityChecks=\(isOn)")
      }
    ))

    // Buttons
    let copyStateButton = UIButton(type: .system)
    copyStateButton.setTitle("Copy State", for: .normal)
    copyStateButton.titleLabel?.font = UIFont.systemFont(ofSize: 12)
    copyStateButton.addTarget(self, action: #selector(copyDebugState), for: .touchUpInside)

    let clearButton = UIButton(type: .system)
    clearButton.setTitle("Clear Log", for: .normal)
    clearButton.titleLabel?.font = UIFont.systemFont(ofSize: 12)
    clearButton.addTarget(self, action: #selector(clearActionLog), for: .touchUpInside)

    let optionsButton = UIButton(type: .system)
    optionsButton.setTitle("Options", for: .normal)
    optionsButton.titleLabel?.font = UIFont.systemFont(ofSize: 12)
    optionsButton.addTarget(self, action: #selector(toggleDebugOptions), for: .touchUpInside)

    buttonStack = UIStackView(arrangedSubviews: [copyStateButton, clearButton, optionsButton])
    buttonStack.axis = .horizontal
    buttonStack.spacing = 16
    buttonStack.distribution = .fillEqually
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    containerView.addSubview(segmentedControl)
    containerView.addSubview(selectionLabel)
    containerView.addSubview(debugOptionsStack)
    containerView.addSubview(_hierarchyView)
    containerView.addSubview(_actionLogView)
    containerView.addSubview(_snapshotView)
    containerView.addSubview(buttonStack)

    NSLayoutConstraint.activate([
      segmentedControl.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
      segmentedControl.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      segmentedControl.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),

      selectionLabel.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 4),
      selectionLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      selectionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),

      debugOptionsStack.topAnchor.constraint(equalTo: selectionLabel.bottomAnchor, constant: 6),
      debugOptionsStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      debugOptionsStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),

      _hierarchyView.topAnchor.constraint(equalTo: debugOptionsStack.bottomAnchor, constant: 4),
      _hierarchyView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      _hierarchyView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      _hierarchyView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -4),

      _actionLogView.topAnchor.constraint(equalTo: debugOptionsStack.bottomAnchor, constant: 4),
      _actionLogView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      _actionLogView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      _actionLogView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -4),

      _snapshotView.topAnchor.constraint(equalTo: debugOptionsStack.bottomAnchor, constant: 4),
      _snapshotView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      _snapshotView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      _snapshotView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -4),

      buttonStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      buttonStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      buttonStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
      buttonStack.heightAnchor.constraint(equalToConstant: 30)
    ])

    debugOptionsHeightConstraint = debugOptionsStack.heightAnchor.constraint(equalToConstant: 0)
    debugOptionsHeightConstraint.isActive = true
  }

  private func isSnapshotVisible() -> Bool {
    segmentedControl.selectedSegmentIndex == 2
  }

  private func scheduleSnapshotUpdate() {
    guard isSnapshotVisible() else { return }
    if pendingSnapshotUpdate != nil { return }

    let work = DispatchWorkItem { [weak self] in
      self?.pendingSnapshotUpdate = nil
      self?.refreshSnapshot()
    }
    pendingSnapshotUpdate = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
  }

  private func attachNativeObserversIfNeeded() {
    guard let lexicalView else { return }
    guard nativeObserverTokens.isEmpty else { return }

    // Best-effort capture of text system activity.
    nativeObserverTokens.append(NotificationCenter.default.addObserver(
      forName: UITextView.textDidChangeNotification,
      object: lexicalView.textView,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.logTextKitTypingAttributesIfEnabled()
      }
    })
  }

  @objc private func toggleDebugOptions() {
    let show = debugOptionsStack.isHidden
    debugOptionsStack.isHidden = !show
    debugOptionsHeightConstraint.isActive = !show
    scheduleSnapshotUpdate()
  }

  @objc private func segmentChanged() {
    let index = segmentedControl.selectedSegmentIndex
    _hierarchyView.isHidden = index != 0
    _actionLogView.isHidden = index != 1
    _snapshotView.isHidden = index != 2
    if index == 2 {
      refreshSnapshot()
    }
  }

  // MARK: - Plugin API

  public func setUp(editor: Editor) {
    self.editor = editor

    _ = editor.registerUpdateListener { [weak self] activeEditorState, previousEditorState, dirtyNodes in
      if let self {
        self.updateHierarchyView(editorState: activeEditorState)
        self.updateSelectionDisplay()
      }
    }

    setupDebugLogging(editor: editor)
  }

  public func tearDown() {
    // Remove command listeners
    for remover in commandListenerRemovers {
      remover()
    }
    commandListenerRemovers.removeAll()
  }

  public var hierarchyView: UIView {
    get {
      containerView
    }
  }

  public func logReconcilerRun(_ run: ReconcilerMetric) {
    guard captureReconcilerMetrics else { return }
    let path = run.pathLabel ?? "nil"
    let details =
      "path=\(path) treatedAllNodesAsDirty=\(run.treatedAllNodesAsDirty) dirtyNodes=\(run.dirtyNodes) ranges(+\(run.rangesAdded)/-\(run.rangesDeleted)) movedChildren=\(run.movedChildren) dur=\(formatSeconds(run.duration))s planning=\(formatSeconds(run.planningDuration))s apply=\(formatSeconds(run.applyDuration))s"
    logAction("reconciler.run", details: details)
  }

  // MARK: - Debug Logging

  private func formatSeconds(_ seconds: TimeInterval) -> String {
    String(format: "%.4f", seconds)
  }

  private func setupDebugLogging(editor: Editor) {
    let priority = CommandPriority.Critical

    // Log text insertion
    let insertTextRemover = editor.registerCommand(type: .insertText, listener: { [weak self] payload in
      if let text = payload as? String {
        let displayText = text.replacingOccurrences(of: "\n", with: "\\n")
        self?.logAction("insertText", details: "text=\"\(displayText)\"")
      }
      return false
    }, priority: priority)
    commandListenerRemovers.append(insertTextRemover)

    // Log paragraph insertion
    let insertParagraphRemover = editor.registerCommand(type: .insertParagraph, listener: { [weak self] _ in
      self?.logAction("insertParagraph", details: "")
      return false
    }, priority: priority)
    commandListenerRemovers.append(insertParagraphRemover)

    // Log line break insertion
    let insertLineBreakRemover = editor.registerCommand(type: .insertLineBreak, listener: { [weak self] _ in
      self?.logAction("insertLineBreak", details: "")
      return false
    }, priority: priority)
    commandListenerRemovers.append(insertLineBreakRemover)

    // Log delete character
    let deleteCharRemover = editor.registerCommand(type: .deleteCharacter, listener: { [weak self] payload in
      let isBackward = (payload as? Bool) ?? true
      self?.logAction("deleteCharacter", details: "backward=\(isBackward)")
      return false
    }, priority: priority)
    commandListenerRemovers.append(deleteCharRemover)

    // Log delete word
    let deleteWordRemover = editor.registerCommand(type: .deleteWord, listener: { [weak self] payload in
      let isBackward = (payload as? Bool) ?? true
      self?.logAction("deleteWord", details: "backward=\(isBackward)")
      return false
    }, priority: priority)
    commandListenerRemovers.append(deleteWordRemover)

    // Log format text
    let formatTextRemover = editor.registerCommand(type: .formatText, listener: { [weak self] payload in
      if let format = payload as? TextFormatType {
        self?.logAction("formatText", details: "format=\(format)")
      }
      return false
    }, priority: priority)
    commandListenerRemovers.append(formatTextRemover)

    // Log selection change
    let selectionChangeRemover = editor.registerCommand(type: .selectionChange, listener: { [weak self] _ in
      self?.updateSelectionDisplay()
      self?.logSelectionState()
      self?.logLayoutSelectionIfEnabled()
      return false
    }, priority: priority)
    commandListenerRemovers.append(selectionChangeRemover)

    // Log undo/redo
    let undoRemover = editor.registerCommand(type: .undo, listener: { [weak self] _ in
      self?.logAction("undo", details: "")
      return false
    }, priority: priority)
    commandListenerRemovers.append(undoRemover)

    let redoRemover = editor.registerCommand(type: .redo, listener: { [weak self] _ in
      self?.logAction("redo", details: "")
      return false
    }, priority: priority)
    commandListenerRemovers.append(redoRemover)

    // Log list commands
    let bulletListRemover = editor.registerCommand(type: .insertUnorderedList, listener: { [weak self] _ in
      self?.logAction("insertUnorderedList", details: "")
      return false
    }, priority: priority)
    commandListenerRemovers.append(bulletListRemover)

    let numberedListRemover = editor.registerCommand(type: .insertOrderedList, listener: { [weak self] _ in
      self?.logAction("insertOrderedList", details: "")
      return false
    }, priority: priority)
    commandListenerRemovers.append(numberedListRemover)
  }

  private func logAction(_ action: String, details: String) {
    let entry = DebugAction(timestamp: Date(), action: action, details: details)
    actionLog.append(entry)
    // Keep log manageable
    if actionLog.count > 500 {
      actionLog.removeFirst(100)
    }
    updateActionLogView()
    scheduleSnapshotUpdate()
  }

  private func logSelectionState() {
    guard let editor else { return }
    var logDetails = ""

    try? editor.read {
      if let selection = try? getSelection() as? RangeSelection {
        let anchor = selection.anchor
        let focus = selection.focus
        logDetails = "anchor=(\(anchor.key),\(anchor.offset),\(anchor.type)) focus=(\(focus.key),\(focus.offset),\(focus.type))"
      } else {
        logDetails = "nil selection"
      }
    }

    logAction("selectionChange", details: logDetails)
  }

  private func logLayoutSelectionIfEnabled() {
    guard captureLayoutEvents else { return }
    guard let lexicalView else { return }

    let textView = lexicalView.textView
    let layoutManager = textView.layoutManager
    let textContainer = textView.textContainer

    var visibleRectInTextContainerCoords = textView.bounds
    visibleRectInTextContainerCoords.origin.x -= textView.textContainerInset.left
    visibleRectInTextContainerCoords.origin.y -= textView.textContainerInset.top

    let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRectInTextContainerCoords, in: textContainer)
    let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
    let native = textView.selectedRange
    let totalGlyphs = layoutManager.numberOfGlyphs

    logAction(
      "layout.selection",
      details: "visibleGlyph=(\(visibleGlyphRange.location),\(visibleGlyphRange.length)) visibleChar=(\(visibleCharRange.location),\(visibleCharRange.length)) nativeSelection=(\(native.location),\(native.length)) totalGlyphs=\(totalGlyphs)"
    )
  }

  private func logTextKitTypingAttributesIfEnabled() {
    guard captureTextKitEvents else { return }
    guard let lexicalView else { return }

    let attrs = lexicalView.textView.typingAttributes
    let font = (attrs[.font] as? UIFont)?.fontName ?? "nil"
    let color = attrs[.foregroundColor].map { String(describing: $0) } ?? "nil"
    logAction("textKit.typingAttrs", details: "font=\(font) color=\(color)")
  }

  private func updateSelectionDisplay() {
    guard let editor else { return }
    var selectionText = "Selection: "

    try? editor.read {
      if let selection = try? getSelection() as? RangeSelection {
        let anchor = selection.anchor
        let focus = selection.focus
        let collapsed = selection.isCollapsed()
        selectionText += "anchor=(\(anchor.key),\(anchor.offset)) focus=(\(focus.key),\(focus.offset)) collapsed=\(collapsed)"
      } else {
        selectionText += "nil"
      }
    }

    if let lexicalView {
      let native = lexicalView.textView.selectedRange
      selectionText += " native=(\(native.location),\(native.length))"
    }
    selectionLabel.text = selectionText
  }

  private func updateActionLogView() {
    let recentActions = actionLog.suffix(100)
    let logText = recentActions.map { $0.description }.joined(separator: "\n")
    _actionLogView.text = logText

    // Scroll to bottom
    if !logText.isEmpty {
      let range = NSRange(location: logText.count - 1, length: 1)
      _actionLogView.scrollRangeToVisible(range)
    }
  }

  @objc private func copyDebugState() {
    guard let editor else { return }

    let debugOutput = makeDebugSnapshotString(editor: editor)

    // Copy to clipboard
    UIPasteboard.general.string = debugOutput

    if isSnapshotVisible() {
      _snapshotView.text = debugOutput
    }

    // Flash feedback
    let originalColor = containerView.backgroundColor
    containerView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.3)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.containerView.backgroundColor = originalColor
    }
  }

  private func refreshSnapshot() {
    guard let editor else { return }
    _snapshotView.text = makeDebugSnapshotString(editor: editor)
  }

  private func makeDebugSnapshotString(editor: Editor) -> String {
    var debugOutput = "=== LEXICAL DEBUG STATE ===\n"
    debugOutput += "Timestamp: \(Date())\n\n"

    debugOutput += "--- DEBUG CAPTURE ---\n"
    debugOutput += "captureTextKitEvents: \(captureTextKitEvents)\n"
    debugOutput += "captureReconcilerMetrics: \(captureReconcilerMetrics)\n"
    debugOutput += "captureLayoutEvents: \(captureLayoutEvents)\n"
    debugOutput += "captureIntegrityChecks: \(captureIntegrityChecks)\n\n"

    // Current selection
    debugOutput += "--- SELECTION ---\n"
    var anchorKey: NodeKey?
    try? editor.read {
      if let selection = try? getSelection() as? RangeSelection {
        let anchor = selection.anchor
        let focus = selection.focus
        anchorKey = anchor.key
        debugOutput += "Anchor: key=\"\(anchor.key)\", offset=\(anchor.offset), type=\(anchor.type)\n"
        debugOutput += "Focus: key=\"\(focus.key)\", offset=\(focus.offset), type=\(focus.type)\n"
        debugOutput += "isCollapsed: \(selection.isCollapsed())\n"
      } else {
        debugOutput += "No selection\n"
      }
    }

    // Native selection + layout
    if let lexicalView {
      let native = lexicalView.textView.selectedRange
      let textLen = (lexicalView.textView.text as NSString).length
      debugOutput += "\n--- NATIVE SELECTION ---\n"
      debugOutput += "UITextView.selectedRange: location=\(native.location), length=\(native.length)\n"
      debugOutput += "Text length: \(textLen)\n"

      let layoutManager = lexicalView.textView.layoutManager
      let textContainer = lexicalView.textView.textContainer

      var visibleRectInTextContainerCoords = lexicalView.textView.bounds
      visibleRectInTextContainerCoords.origin.x -= lexicalView.textView.textContainerInset.left
      visibleRectInTextContainerCoords.origin.y -= lexicalView.textView.textContainerInset.top

      let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRectInTextContainerCoords, in: textContainer)
      let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

      debugOutput += "\n--- LAYOUT ---\n"
      debugOutput += "visibleGlyphRange: location=\(visibleGlyphRange.location), length=\(visibleGlyphRange.length)\n"
      debugOutput += "visibleCharRange: location=\(visibleCharRange.location), length=\(visibleCharRange.length)\n"
      debugOutput += "totalGlyphs: \(layoutManager.numberOfGlyphs)\n"
    }

    // Editor state as JSON
    debugOutput += "\n--- EDITOR STATE JSON ---\n"
    do {
      let json = try editor.getEditorState().toJSON(outputFormatting: [.prettyPrinted, .sortedKeys])
      debugOutput += json
    } catch {
      debugOutput += "Error serializing state: \(error)\n"
    }

    // Range cache
    debugOutput += "\n\n--- RANGE CACHE ---\n"
    debugOutput += "rangeCache.count: \(editor.rangeCache.count)\n"
    if let anchorKey {
      if let item = editor.rangeCache[anchorKey] {
        debugOutput += "anchorKey=\(anchorKey) range=(\(item.location),\(item.textLength)) pre=\(item.preambleLength) text=\(item.textLength) children=\(item.childrenLength) post=\(item.postambleLength)\n"
      } else {
        debugOutput += "anchorKey=\(anchorKey) rangeCache: missing\n"
      }
    }

    // Action log
    debugOutput += "\n\n--- ACTION LOG (last 100) ---\n"
    for action in actionLog.suffix(100) {
      debugOutput += "\(action)\n"
    }

    // Focused views for easier scanning
    debugOutput += "\n--- RECONCILER RUNS (last 50) ---\n"
    for action in actionLog.filter({ $0.action == "reconciler.run" }).suffix(50) {
      debugOutput += "\(action)\n"
    }
    debugOutput += "\n--- TEXTKIT EVENTS (last 50) ---\n"
    for action in actionLog.filter({ $0.action.hasPrefix("textKit.") }).suffix(50) {
      debugOutput += "\(action)\n"
    }

    return debugOutput
  }

  @objc private func clearActionLog() {
    actionLog.removeAll()
    _actionLogView.text = ""
    _snapshotView.text = ""
    selectionLabel.text = "Selection: --"
  }

  // MARK: - Hierarchy Update

  private func updateHierarchyView(editorState: EditorState) {
    do {
      let hierarchyString = try getNodeHierarchy(editorState: editorState)
      let selectionString = try getSelectionData(editorState: editorState)
      _hierarchyView.text = "\(hierarchyString)\n\n\(selectionString)"
    } catch {
      _hierarchyView.text = "Error updating node hierarchy: \(error)"
    }
  }
}
