# Lexical iOS

> [!NOTE]
> This is a fork of the original [facebook/lexical-ios](https://github.com/facebook/lexical-ios) library, which is no longer actively maintained. We've diverged significantly from the original and are actively developing new features. This is currently an **alpha** product—APIs may change.

An extensible text editor/renderer written in Swift, built on top of TextKit, and sharing a philosophy and API with [Lexical JavaScript](https://lexical.dev).

## Status

Lexical iOS is in active development as an alpha release.

## Platform Support

Lexical supports multiple Apple platforms:

| Platform | Minimum Version | Target |
|----------|-----------------|--------|
| iOS | 16.0+ | `Lexical`, `LexicalSwiftUI` |
| macOS | 13.0+ | `LexicalAppKit`, `LexicalSwiftUI` |
| Mac Catalyst | 16.0+ | `Lexical`, `LexicalSwiftUI` |

## Playground

We have a sample playground app demonstrating some of Lexical's features:

![Screenshot of playground app](docs/resources/playground.png)

The playground app contains the code for a rich text toolbar. While this is not specifically a reusable toolbar that you can drop straight into your projects, its code should provide a good starting point for you to customise.

This playground app is very new, and many more features will come in time!

## Requirements
Lexical is written in Swift 5.7+ and requires:
- iOS 16.0+ / macOS 13.0+ / Mac Catalyst 16.0+
- Xcode 14.0+

Note: The Playground app requires at least iOS 14 due to use of UIKit features such as UIMenu.

## Installation

### Swift Package Manager

Add Lexical to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/facebook/lexical-ios.git", from: "0.1.0")
]
```

Then add the appropriate target to your dependencies:

```swift
// For iOS apps (UIKit)
.target(name: "YourApp", dependencies: ["Lexical"]),

// For macOS apps (AppKit)
.target(name: "YourApp", dependencies: ["LexicalAppKit"]),

// For SwiftUI apps (any platform)
.target(name: "YourApp", dependencies: ["LexicalSwiftUI"]),
```

### Available Targets

| Target | Platform | Description |
|--------|----------|-------------|
| `Lexical` | iOS, Catalyst | Main UIKit-based editor |
| `LexicalAppKit` | macOS | AppKit-based editor |
| `LexicalSwiftUI` | All | SwiftUI wrappers |
| `LexicalCore` | All | Core types (nodes, selection, etc.) |
| `LexicalListPlugin` | iOS | List formatting support |
| `LexicalLinkPlugin` | iOS | Link support |
| `LexicalHTML` | iOS | HTML import/export |
| `LexicalMarkdown` | iOS | Markdown support |
| `EditorHistoryPlugin` | iOS | Undo/redo support |

Some plugins included in this repository do not yet have package files. Adding these would be an easy PR if you want to start contributing to Lexical!

## Using Lexical in your app

### UIKit (iOS)

For editable text with Lexical on iOS, instantiate a `LexicalView`:

```swift
import Lexical

let config = EditorConfig(theme: Theme(), plugins: [])
let lexicalView = LexicalView(editorConfig: config, featureFlags: FeatureFlags())

// Access the editor for programmatic updates
lexicalView.editor.update {
    // Use the Lexical API here
}
```

### AppKit (macOS)

For macOS apps, use `LexicalAppKit`:

```swift
import LexicalAppKit

let config = EditorConfig(theme: Theme(), plugins: [])
let lexicalView = LexicalView(editorConfig: config, featureFlags: FeatureFlags())

// Access the editor
lexicalView.editor.update {
    // Use the Lexical API here
}
```

### SwiftUI (iOS & macOS)

For SwiftUI apps on any platform, use `LexicalSwiftUI`:

```swift
import LexicalSwiftUI

struct ContentView: View {
    var body: some View {
        LexicalEditorView(
            config: EditorConfig(theme: Theme(), plugins: []),
            onEditorReady: { editor in
                // Configure editor
            }
        )
    }
}
```

For more information, see the documentation.

## Contributing

See the [CONTRIBUTING](CONTRIBUTING.md) file for how to help out.

## Tests

Lexical has a suite of unit tests, in XCTest format, which can be run from within Xcode.

## License

Lexical iOS is [MIT licensed](LICENSE).
