/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(macOS) && !targetEnvironment(macCatalyst)

import AppKit
import Lexical
import LexicalAppKit
import LexicalListPlugin
import EditorHistoryPlugin
import LexicalInlineImagePlugin
import SelectableDecoratorNode

// MARK: - Debug Action Log

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

@MainActor
final class DebugMetricsContainer: NSObject, EditorMetricsContainer {
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
        // No-op: the demo app keeps an external action log.
    }
}

final class ViewController: NSViewController, NSSplitViewDelegate {

    private var lexicalView: LexicalAppKit.LexicalView!
    private var toolbar: NSStackView!
    private var splitView: NSSplitView!
    private var debugPanel: NSView!
    private var debugTextView: NSTextView!
    private var selectionLabel: NSTextField!
    private var debugOptionsStack: NSStackView!
    private var captureTextKitCheckbox: NSButton!
    private var captureReconcilerCheckbox: NSButton!
    private var captureLayoutCheckbox: NSButton!
    private var captureIntegrityCheckbox: NSButton!
    private var debugMetricsContainer: DebugMetricsContainer?

    // Debug state
    private var actionLog: [DebugAction] = []
    private var commandListenerRemovers: [() -> Void] = []
    private var debugPanelVisible = true
    private var captureTextKitEvents = true
    private var captureReconcilerMetrics = true
    private var captureLayoutEvents = true
    private var captureIntegrityChecks = true
    private var isDebugUIReady = false
    private var pendingDebugPanelUpdate: DispatchWorkItem?

    override func loadView() {
        // Create a basic view - required for programmatic NSViewController
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupToolbar()
        setupSplitView()
    }

    private func setupToolbar() {
        toolbar = NSStackView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        // Bold button
        let boldButton = NSButton(title: "B", target: self, action: #selector(toggleBold))
        boldButton.font = NSFont.boldSystemFont(ofSize: 14)
        boldButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(boldButton)

        // Italic button
        let italicButton = NSButton(title: "I", target: self, action: #selector(toggleItalic))
        italicButton.font = NSFont(descriptor: NSFontDescriptor().withSymbolicTraits(.italic), size: 14)
        italicButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(italicButton)

        // Underline button
        let underlineButton = NSButton(title: "U", target: self, action: #selector(toggleUnderline))
        underlineButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(underlineButton)

        // Separator
        let separator1 = NSBox()
        separator1.boxType = .separator
        separator1.widthAnchor.constraint(equalToConstant: 1).isActive = true
        toolbar.addArrangedSubview(separator1)

        // Bullet list button
        let bulletButton = NSButton(title: "Bullet List", target: self, action: #selector(insertBulletList))
        bulletButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(bulletButton)

        // Numbered list button
        let numberedButton = NSButton(title: "Numbered List", target: self, action: #selector(insertNumberedList))
        numberedButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(numberedButton)

        // Separator
        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.widthAnchor.constraint(equalToConstant: 1).isActive = true
        toolbar.addArrangedSubview(separator2)

        // Inline image button
        let imageButton = NSButton(title: "Image", target: self, action: #selector(insertInlineImage))
        imageButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(imageButton)

        // Selectable image button
        let selectableImageButton = NSButton(title: "Sel. Image", target: self, action: #selector(insertSelectableImage))
        selectableImageButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(selectableImageButton)

        // Separator
        let separator2b = NSBox()
        separator2b.boxType = .separator
        separator2b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        toolbar.addArrangedSubview(separator2b)

        // Undo button
        let undoButton = NSButton(title: "Undo", target: self, action: #selector(performUndo))
        undoButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(undoButton)

        // Redo button
        let redoButton = NSButton(title: "Redo", target: self, action: #selector(performRedo))
        redoButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(redoButton)

        // Clear editor button (useful for memory testing after large pastes)
        let clearEditorButton = NSButton(title: "Clear Editor", target: self, action: #selector(clearEditor))
        clearEditorButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(clearEditorButton)

        // Separator
        let separator3 = NSBox()
        separator3.boxType = .separator
        separator3.widthAnchor.constraint(equalToConstant: 1).isActive = true
        toolbar.addArrangedSubview(separator3)

        // Debug button - copies state to clipboard
        let debugButton = NSButton(title: "Copy State", target: self, action: #selector(copyDebugState))
        debugButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(debugButton)

        // Clear log button
        let clearLogButton = NSButton(title: "Clear", target: self, action: #selector(clearActionLog))
        clearLogButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(clearLogButton)

        // Toggle debug panel button
        let toggleDebugButton = NSButton(title: "Toggle Debug", target: self, action: #selector(toggleDebugPanel))
        toggleDebugButton.bezelStyle = .rounded
        toolbar.addArrangedSubview(toggleDebugButton)

        // Spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)

        view.addSubview(toolbar)
    }

    private func setupSplitView() {
        // Create split view
        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Create editor container
        let editorContainer = NSView()
        editorContainer.translatesAutoresizingMaskIntoConstraints = false

        // Create debug panel (build UI before LexicalView init so early metrics can't crash logging)
        debugPanel = NSView()
        debugPanel.translatesAutoresizingMaskIntoConstraints = false
        debugPanel.wantsLayer = true
        debugPanel.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor

        // Selection label at top
        selectionLabel = NSTextField(labelWithString: "Selection: --")
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        selectionLabel.textColor = NSColor.systemGreen
        selectionLabel.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
        selectionLabel.drawsBackground = true
        selectionLabel.maximumNumberOfLines = 3
        selectionLabel.lineBreakMode = .byWordWrapping
        debugPanel.addSubview(selectionLabel)

        // Debug capture toggles
        debugOptionsStack = NSStackView()
        debugOptionsStack.translatesAutoresizingMaskIntoConstraints = false
        debugOptionsStack.orientation = .horizontal
        debugOptionsStack.spacing = 8

        captureTextKitCheckbox = NSButton(checkboxWithTitle: "TextKit", target: self, action: #selector(toggleCaptureTextKit))
        captureTextKitCheckbox.state = captureTextKitEvents ? .on : .off
        debugOptionsStack.addArrangedSubview(captureTextKitCheckbox)

        captureReconcilerCheckbox = NSButton(checkboxWithTitle: "Reconciler", target: self, action: #selector(toggleCaptureReconciler))
        captureReconcilerCheckbox.state = captureReconcilerMetrics ? .on : .off
        debugOptionsStack.addArrangedSubview(captureReconcilerCheckbox)

        captureLayoutCheckbox = NSButton(checkboxWithTitle: "Layout", target: self, action: #selector(toggleCaptureLayout))
        captureLayoutCheckbox.state = captureLayoutEvents ? .on : .off
        debugOptionsStack.addArrangedSubview(captureLayoutCheckbox)

        captureIntegrityCheckbox = NSButton(checkboxWithTitle: "Integrity", target: self, action: #selector(toggleCaptureIntegrity))
        captureIntegrityCheckbox.state = captureIntegrityChecks ? .on : .off
        debugOptionsStack.addArrangedSubview(captureIntegrityCheckbox)

        debugPanel.addSubview(debugOptionsStack)

        // Debug log text view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        debugTextView = NSTextView()
        debugTextView.isEditable = false
        debugTextView.isSelectable = true
        debugTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        debugTextView.textColor = NSColor.systemGray
        debugTextView.backgroundColor = NSColor(white: 0.15, alpha: 1.0)
        debugTextView.autoresizingMask = [.width, .height]
        debugTextView.isVerticallyResizable = true
        debugTextView.isHorizontallyResizable = false
        debugTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        debugTextView.textContainer?.widthTracksTextView = true

        scrollView.documentView = debugTextView
        debugPanel.addSubview(scrollView)

        NSLayoutConstraint.activate([
            selectionLabel.topAnchor.constraint(equalTo: debugPanel.topAnchor, constant: 8),
            selectionLabel.leadingAnchor.constraint(equalTo: debugPanel.leadingAnchor, constant: 8),
            selectionLabel.trailingAnchor.constraint(equalTo: debugPanel.trailingAnchor, constant: -8),

            debugOptionsStack.topAnchor.constraint(equalTo: selectionLabel.bottomAnchor, constant: 6),
            debugOptionsStack.leadingAnchor.constraint(equalTo: debugPanel.leadingAnchor, constant: 8),
            debugOptionsStack.trailingAnchor.constraint(lessThanOrEqualTo: debugPanel.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: debugOptionsStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: debugPanel.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: debugPanel.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: debugPanel.bottomAnchor)
        ])

        // Create Lexical view
        let theme = Theme()
        let listPlugin = ListPlugin()
        let historyPlugin = EditorHistoryPlugin()
        let inlineImagePlugin = InlineImagePlugin()
        debugMetricsContainer = DebugMetricsContainer(onReconcilerRun: { [weak self] run in
            self?.logReconcilerRun(run)
        })
        let editorConfig = EditorConfig(
            theme: theme,
            plugins: [listPlugin, historyPlugin, inlineImagePlugin],
            metricsContainer: debugMetricsContainer
        )

        // Enable verbose logging to debug selection sync issues
        let flags = FeatureFlags(verboseLogging: true)
        lexicalView = LexicalAppKit.LexicalView(editorConfig: editorConfig, featureFlags: flags)
        lexicalView.translatesAutoresizingMaskIntoConstraints = false
        lexicalView.placeholderText = LexicalPlaceholderText(
            text: "Start typing...",
            font: .systemFont(ofSize: 16),
            color: .placeholderTextColor
        )
        editorContainer.addSubview(lexicalView)

        NSLayoutConstraint.activate([
            lexicalView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            lexicalView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            lexicalView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            lexicalView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor)
        ])

        // Add views to split view
        splitView.addArrangedSubview(editorContainer)
        splitView.addArrangedSubview(debugPanel)

        view.addSubview(splitView)

        // Layout constraints
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Set initial split position - debug panel is ~280px wide
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.splitView.setPosition(self.view.bounds.width - 280, ofDividerAt: 0)
        }

        // Register SelectableImageNode type
        try? lexicalView.editor.registerNode(nodeType: NodeType.selectableImage, class: SelectableImageNode.self)

        // Add sample content
        addSampleContent()

        // Setup debug logging
        setupDebugLogging()
        isDebugUIReady = true
        updateDebugPanel()
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 300 // Minimum editor width
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.bounds.width - 180 // Minimum debug panel width
    }

    private func addSampleContent() {
        try? lexicalView.editor.update {
            guard let root = getRoot() else { return }

            // Clear any existing children (e.g., default empty paragraph) before adding sample content
            for child in root.getChildren() {
                try? child.remove()
            }

            let heading = createParagraphNode()
            let headingText = createTextNode(text: "Welcome to Lexical on macOS!")
            try? headingText.setBold(true)
            try? heading.append([headingText])

            let paragraph = createParagraphNode()
            let text = createTextNode(text: "This is a demo of the Lexical rich text editor running on macOS using AppKit. Try typing, formatting text, and using the toolbar buttons above.")
            try? paragraph.append([text])

            let paragraph2 = createParagraphNode()
            let text2 = createTextNode(text: "Features include bold, italic, underline, lists, and undo/redo support.")
            try? paragraph2.append([text2])

            try? root.append([heading, paragraph, paragraph2])
        }
    }

    // MARK: - Toolbar Actions

    @objc private func toggleBold() {
        lexicalView.editor.dispatchCommand(type: .formatText, payload: TextFormatType.bold)
    }

    @objc private func toggleItalic() {
        lexicalView.editor.dispatchCommand(type: .formatText, payload: TextFormatType.italic)
    }

    @objc private func toggleUnderline() {
        lexicalView.editor.dispatchCommand(type: .formatText, payload: TextFormatType.underline)
    }

    @objc private func insertBulletList() {
        lexicalView.editor.dispatchCommand(type: .insertUnorderedList, payload: nil)
    }

    @objc private func insertNumberedList() {
        lexicalView.editor.dispatchCommand(type: .insertOrderedList, payload: nil)
    }

    @objc private func insertInlineImage() {
        // Use a sample image URL
        let imageURL = "https://placecats.com/200/150"
        try? lexicalView.editor.update {
            let imageNode = ImageNode(url: imageURL, size: CGSize(width: 200, height: 150), sourceID: "sample-image")
            if let selection = try getSelection() {
                _ = try selection.insertNodes(nodes: [imageNode], selectStart: false)
            }
        }
    }

    @objc private func insertSelectableImage() {
        // Use a sample image URL
        let imageURL = "https://placecats.com/200/150"
        try? lexicalView.editor.update {
            let imageNode = SelectableImageNode(url: imageURL, size: CGSize(width: 200, height: 150), sourceID: "sample-selectable-image")
            if let selection = try getSelection() {
                _ = try selection.insertNodes(nodes: [imageNode], selectStart: false)
            }
        }
    }

    @objc private func performUndo() {
        lexicalView.editor.dispatchCommand(type: .undo, payload: nil)
    }

    @objc private func performRedo() {
        lexicalView.editor.dispatchCommand(type: .redo, payload: nil)
    }

    @objc private func clearEditor() {
        // For memory testing: clear the TextKit backing store first (so any TextKit caches can release),
        // then reset the Lexical editor state.
        if let textStorage = lexicalView.textStorage as? TextStorageAppKit {
            let previousMode = textStorage.mode
            textStorage.mode = .controllerMode
            textStorage.beginEditing()
            textStorage.setAttributedString(NSAttributedString(string: ""))
            textStorage.endEditing()
            textStorage.mode = previousMode
        } else {
            lexicalView.textStorage.setAttributedString(NSAttributedString(string: ""))
        }

        try? lexicalView.editor.clearEditor()
        lexicalView.showPlaceholderText()
    }

    @objc private func toggleDebugPanel() {
        debugPanelVisible.toggle()
        if debugPanelVisible {
            debugPanel.isHidden = false
            splitView.setPosition(view.bounds.width * 0.65, ofDividerAt: 0)
        } else {
            debugPanel.isHidden = true
        }
    }

    // MARK: - Debug Functions

    @objc private func toggleCaptureTextKit() {
        captureTextKitEvents = (captureTextKitCheckbox.state == .on)
        logAction("debug", details: "captureTextKitEvents=\(captureTextKitEvents)")
    }

    @objc private func toggleCaptureReconciler() {
        captureReconcilerMetrics = (captureReconcilerCheckbox.state == .on)
        logAction("debug", details: "captureReconcilerMetrics=\(captureReconcilerMetrics)")
    }

    @objc private func toggleCaptureLayout() {
        captureLayoutEvents = (captureLayoutCheckbox.state == .on)
        logAction("debug", details: "captureLayoutEvents=\(captureLayoutEvents)")
    }

    @objc private func toggleCaptureIntegrity() {
        captureIntegrityChecks = (captureIntegrityCheckbox.state == .on)
        logAction("debug", details: "captureIntegrityChecks=\(captureIntegrityChecks)")
    }

    private func setupDebugLogging() {
        let editor = lexicalView.editor

        // Use Critical priority so debug listeners run first (before handlers that might return true)
        let priority = CommandPriority.Critical

        // Log text insertion
        let insertTextRemover = editor.registerCommand(type: .insertText, listener: { [weak self] payload in
            if let text = payload as? String {
                let displayText = text.replacingOccurrences(of: "\n", with: "\\n")
                self?.logAction("insertText", details: "text=\"\(displayText)\"")
            }
            return false // Don't intercept
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

        // Log delete line
        let deleteLineRemover = editor.registerCommand(type: .deleteLine, listener: { [weak self] payload in
            let isBackward = (payload as? Bool) ?? true
            self?.logAction("deleteLine", details: "backward=\(isBackward)")
            return false
        }, priority: priority)
        commandListenerRemovers.append(deleteLineRemover)

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
            self?.logSelectionState()
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

        // Also listen for NSTextView selection changes directly (backup for when command isn't dispatched)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nativeSelectionDidChange),
            name: NSTextView.didChangeSelectionNotification,
            object: lexicalView.textView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nativeTextDidChange),
            name: NSText.didChangeNotification,
            object: lexicalView.textView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onTextViewDidChangeTypingAttributes),
            name: NSTextView.didChangeTypingAttributesNotification,
            object: lexicalView.textView
        )

        if let ts = lexicalView.textView.textStorage {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTextStorageWillProcessEditingNotification),
                name: NSTextStorage.willProcessEditingNotification,
                object: ts
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onTextStorageDidProcessEditingNotification),
                name: NSTextStorage.didProcessEditingNotification,
                object: ts
            )
        }
    }

    @objc private func nativeSelectionDidChange(_ notification: Notification) {
        updateSelectionDisplay()

        // Log selection change to action log
        var logDetails = ""
        let textView = lexicalView.textView
        let nativeRange = textView.selectedRange()

        try? lexicalView.editor.read {
            if let selection = try? getSelection() as? RangeSelection {
                let anchor = selection.anchor
                let focus = selection.focus
                logDetails = "anchor=(\(anchor.key),\(anchor.offset)) focus=(\(focus.key),\(focus.offset)) native=(\(nativeRange.location),\(nativeRange.length))"
            } else {
                logDetails = "nil lexical, native=(\(nativeRange.location),\(nativeRange.length))"
            }
        }
        logAction("selection", details: logDetails)

        if captureLayoutEvents {
            logLayoutSnapshot(action: "layout.selection")
        }
    }

    @objc private func nativeTextDidChange(_ notification: Notification) {
        guard captureTextKitEvents else { return }
        let textView = lexicalView.textView
        let range = textView.selectedRange()
        logAction("textKit.textDidChange", details: "nativeSelection=(\(range.location),\(range.length)) length=\(textView.string.count)")

        if captureLayoutEvents {
            logLayoutSnapshot(action: "layout.textDidChange")
        }

        guard captureIntegrityChecks else { return }
        // Only log on mismatch to keep noise down while typing.
        var lexicalText: String?
        try? lexicalView.editor.read {
            if let root = getRoot() {
                lexicalText = root.getTextContent()
            }
        }
        if let lexicalText, lexicalText != textView.string {
            let nativePrefix = String(textView.string.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
            let lexicalPrefix = String(lexicalText.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
            logAction(
                "integrity.mismatch",
                details: "nativeLen=\(textView.string.count) lexicalLen=\(lexicalText.count) nativePrefix=\"\(nativePrefix)\" lexicalPrefix=\"\(lexicalPrefix)\""
            )
        }
    }

    @objc private func onTextStorageWillProcessEditingNotification(_ notification: Notification) {
        guard captureTextKitEvents else { return }
        guard let ts = notification.object as? NSTextStorage else { return }
        let editedRange = ts.editedRange
        let delta = ts.changeInLength
        logAction(
            "textKit.willProcessEditing",
            details: "mask=\(ts.editedMask.rawValue) editedRange=(\(editedRange.location),\(editedRange.length)) delta=\(delta) length=\(ts.length)"
        )
    }

    @objc private func onTextStorageDidProcessEditingNotification(_ notification: Notification) {
        guard captureTextKitEvents else { return }
        guard let ts = notification.object as? NSTextStorage else { return }
        let editedRange = ts.editedRange
        let delta = ts.changeInLength
        let length = ts.length

        let s = ts.string as NSString
        let ctx = 40
        let start = max(0, editedRange.location - ctx)
        let end = min(length, editedRange.location + editedRange.length + ctx)
        let snippetRange = NSRange(location: start, length: max(0, end - start))
        let snippet = (snippetRange.length > 0) ? s.substring(with: snippetRange) : ""
        let displaySnippet = snippet
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")

        let textView = lexicalView.textView
        let nativeSel = textView.selectedRange()
        logAction(
            "textKit.didProcessEditing",
            details: "mask=\(ts.editedMask.rawValue) editedRange=(\(editedRange.location),\(editedRange.length)) delta=\(delta) length=\(length) nativeSelection=(\(nativeSel.location),\(nativeSel.length)) snippet=\"\(displaySnippet)\""
        )

        if captureLayoutEvents {
            // Defer layout snapshot to next run loop - accessing layoutManager.numberOfGlyphs
            // during didProcessEditing causes a crash because glyph generation is not allowed
            // while textStorage is still editing.
            DispatchQueue.main.async { [weak self] in
                self?.logLayoutSnapshot(action: "layout.didProcessEditing")
            }
        }

        if length == 0 {
            logAction("textKit.emptyStorage", details: "editedRange=(\(editedRange.location),\(editedRange.length)) delta=\(delta)")
        }
        if editedRange.location == 0 && editedRange.length == length && length > 0 {
            logAction("textKit.fullEdit", details: "fullRange=(0,\(length)) delta=\(delta)")
        }
    }

    private func logLayoutSnapshot(action: String) {
        guard let layoutManager = lexicalView.textView.layoutManager,
              let textContainer = lexicalView.textView.textContainer else { return }

        let visible = lexicalView.textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        let nativeSel = lexicalView.textView.selectedRange()
        logAction(
            action,
            details: "visibleGlyph=(\(visibleGlyphRange.location),\(visibleGlyphRange.length)) visibleChar=(\(visibleCharRange.location),\(visibleCharRange.length)) nativeSelection=(\(nativeSel.location),\(nativeSel.length)) totalGlyphs=\(layoutManager.numberOfGlyphs)"
        )
    }

    @objc private func onTextViewDidChangeTypingAttributes(_ notification: Notification) {
        guard captureLayoutEvents else { return }
        let attrs = lexicalView.textView.typingAttributes
        let font = (attrs[.font] as? NSFont)?.fontName ?? "nil"
        let color = (attrs[.foregroundColor] as? NSColor)?.description ?? "nil"
        logAction("textKit.typingAttrs", details: "font=\(font) color=\(color)")
    }

    private func logReconcilerRun(_ run: ReconcilerMetric) {
        guard captureReconcilerMetrics else { return }
        let label = run.pathLabel ?? "nil"
        let dur = String(format: "%.4f", run.duration)
        let planning = String(format: "%.4f", run.planningDuration)
        let apply = String(format: "%.4f", run.applyDuration)
        logAction(
            "reconciler.run",
            details: "path=\(label) treatedAllNodesAsDirty=\(run.treatedAllNodesAsDirty) dirtyNodes=\(run.dirtyNodes) ranges(+\(run.rangesAdded)/-\(run.rangesDeleted)) movedChildren=\(run.movedChildren) dur=\(dur)s planning=\(planning)s apply=\(apply)s"
        )
    }

    private func updateSelectionDisplay() {
        var selectionText = "Selection: "

        let textView = lexicalView.textView
        let nativeRange = textView.selectedRange()

        try? lexicalView.editor.read {
            if let selection = try? getSelection() as? RangeSelection {
                let anchor = selection.anchor
                let focus = selection.focus
                let collapsed = selection.isCollapsed()
                selectionText += "anchor=(\(anchor.key),\(anchor.offset)) focus=(\(focus.key),\(focus.offset)) collapsed=\(collapsed)"
            } else {
                selectionText += "nil"
            }
        }

        // Also show native selection
        selectionText += "\nNative: loc=\(nativeRange.location), len=\(nativeRange.length)"

        selectionLabel.stringValue = selectionText
    }

    private func logAction(_ action: String, details: String) {
        let entry = DebugAction(timestamp: Date(), action: action, details: details)
        actionLog.append(entry)
        // Keep log manageable
        if actionLog.count > 500 {
            actionLog.removeFirst(100)
        }
        scheduleDebugPanelUpdate()
    }

    private func scheduleDebugPanelUpdate() {
        guard isDebugUIReady else { return }
        if pendingDebugPanelUpdate != nil { return }

        let work = DispatchWorkItem { [weak self] in
            self?.pendingDebugPanelUpdate = nil
            self?.updateDebugPanel()
        }
        pendingDebugPanelUpdate = work
        // Coalesce rapid logs so the debug UI itself doesn't become the bottleneck while typing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func logSelectionState() {
        var logDetails = ""

        try? lexicalView.editor.read {
            if let selection = try? getSelection() {
                if let rangeSelection = selection as? RangeSelection {
                    let anchor = rangeSelection.anchor
                    let focus = rangeSelection.focus
                    logDetails = "anchor=(\(anchor.key),\(anchor.offset),\(anchor.type)) focus=(\(focus.key),\(focus.offset),\(focus.type))"
                } else if let nodeSelection = selection as? NodeSelection {
                    let keys = (try? nodeSelection.getNodes().map { $0.key }) ?? []
                    logDetails = "NodeSelection keys=[\(keys.joined(separator: ", "))]"
                } else {
                    logDetails = "unknown selection type: \(type(of: selection))"
                }
            } else {
                logDetails = "nil selection"
            }
        }

        updateSelectionDisplay()
        logAction("selectionChange", details: logDetails)
    }

    private func updateDebugPanel() {
        guard isDebugUIReady else { return }
        // Update the debug text view with recent actions
        let recentActions = actionLog.suffix(50)
        let logText = recentActions.map { $0.description }.joined(separator: "\n")
        debugTextView.string = logText

        // Scroll to bottom
        debugTextView.scrollToEndOfDocument(nil)
    }

    @objc private func copyDebugState() {
        var debugOutput = "=== LEXICAL DEBUG STATE ===\n"
        debugOutput += "Timestamp: \(Date())\n\n"
        debugOutput += "--- DEBUG CAPTURE ---\n"
        debugOutput += "captureTextKitEvents: \(captureTextKitEvents)\n"
        debugOutput += "captureReconcilerMetrics: \(captureReconcilerMetrics)\n"
        debugOutput += "captureLayoutEvents: \(captureLayoutEvents)\n"
        debugOutput += "captureIntegrityChecks: \(captureIntegrityChecks)\n"
        debugOutput += "\n"

        // Current selection
        debugOutput += "--- SELECTION ---\n"
        try? lexicalView.editor.read {
            if let selection = try? getSelection() as? RangeSelection {
                let anchor = selection.anchor
                let focus = selection.focus
                debugOutput += "Anchor: key=\"\(anchor.key)\", offset=\(anchor.offset), type=\(anchor.type)\n"
                debugOutput += "Focus: key=\"\(focus.key)\", offset=\(focus.offset), type=\(focus.type)\n"
                debugOutput += "isCollapsed: \(selection.isCollapsed())\n"
            } else {
                debugOutput += "No selection\n"
            }
        }

        // Native NSTextView selection
        debugOutput += "\n--- NATIVE SELECTION ---\n"
        let textView = lexicalView.textView
        let selectedRange = textView.selectedRange()
        debugOutput += "NSTextView.selectedRange: location=\(selectedRange.location), length=\(selectedRange.length)\n"
        debugOutput += "Text length: \(textView.string.count)\n"

        // Layout snapshot
        debugOutput += "\n--- LAYOUT ---\n"
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            let visible = textView.visibleRect
            let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
            let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
            debugOutput += "visibleGlyphRange: location=\(visibleGlyphRange.location), length=\(visibleGlyphRange.length)\n"
            debugOutput += "visibleCharRange: location=\(visibleCharRange.location), length=\(visibleCharRange.length)\n"
            debugOutput += "totalGlyphs: \(layoutManager.numberOfGlyphs)\n"
        } else {
            debugOutput += "layoutManager/textContainer: nil\n"
        }

        // Editor state as JSON
        debugOutput += "\n--- EDITOR STATE JSON ---\n"
        do {
            let json = try lexicalView.editor.getEditorState().toJSON(outputFormatting: [.prettyPrinted, .sortedKeys])
            debugOutput += json
        } catch {
            debugOutput += "Error serializing state: \(error)\n"
        }

        // RangeCache quick stats (helps debug “flashing” blocks)
        debugOutput += "\n\n--- RANGE CACHE ---\n"
        debugOutput += "rangeCache.count: \(lexicalView.editor.rangeCache.count)\n"
        try? lexicalView.editor.read {
            if let selection = try? getSelection() as? RangeSelection {
                let key = selection.anchor.key
                if let item = lexicalView.editor.rangeCache[key] {
                    debugOutput += "anchorKey=\(key) range=(\(item.range.location),\(item.range.length)) pre=\(item.preambleLength) text=\(item.textLength) children=\(item.childrenLength) post=\(item.postambleLength)\n"
                } else {
                    debugOutput += "anchorKey=\(key) rangeCache: missing\n"
                }
            }
        }

        // Action log
        debugOutput += "\n\n--- ACTION LOG (last 100) ---\n"
        let recentActions = actionLog.suffix(100)
        for action in recentActions {
            debugOutput += "\(action)\n"
        }

        // Focused views for easier scanning
        debugOutput += "\n--- RECONCILER RUNS (last 50) ---\n"
        let reconcilerActions = actionLog.filter { $0.action == "reconciler.run" }.suffix(50)
        for action in reconcilerActions {
            debugOutput += "\(action)\n"
        }
        debugOutput += "\n--- TEXTKIT EVENTS (last 50) ---\n"
        let textKitActions = actionLog.filter { $0.action.hasPrefix("textKit.") }.suffix(50)
        for action in textKitActions {
            debugOutput += "\(action)\n"
        }

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(debugOutput, forType: .string)

        // Flash the debug panel to confirm
        let originalColor = debugPanel.layer?.backgroundColor
        debugPanel.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.3).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.debugPanel.layer?.backgroundColor = originalColor
        }
    }

    @objc private func clearActionLog() {
        actionLog.removeAll()
        debugTextView.string = ""
        selectionLabel.stringValue = "Selection: --"
    }
}

#endif // os(macOS) && !targetEnvironment(macCatalyst)
