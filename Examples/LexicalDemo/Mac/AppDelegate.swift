/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if os(macOS) && !targetEnvironment(macCatalyst)

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    var viewController: ViewController!

    private func setupMainMenuIfNeeded() {
        // In a pure-SwiftPM AppKit app, we don't get a default menu bar.
        // Without an Edit menu, Cmd+C/Cmd+V won't trigger copy:/paste: through the responder chain
        // (even if the contextual menu works).
        if NSApp.mainMenu != nil { return }

        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "Quit Lexical Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMainMenuIfNeeded()

        // Create the main window
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lexical Demo"
        window.center()
        window.minSize = NSSize(width: 600, height: 400)

        // Create and set the view controller
        viewController = ViewController()
        window.contentViewController = viewController

        // Show the window and activate the app
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Manual entry point for SPM executables
@main
struct LexicalDemoMacApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

#else

import Foundation

// Stub entry point so this SPM executable target can be built on non-macOS platforms.
@main
struct LexicalDemoMacApp {
    static func main() {}
}

#endif
