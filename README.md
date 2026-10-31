# PathDeck

A native macOS file manager with an editable path bar, familiar file controls, independent windows, and native tabs. Built with Swift and AppKit.

Use breadcrumbs or enter a path, pin folders, filter the current directory, create and rename files, copy and cut between windows, and move items to Trash. Open folders in Terminal or files in VS Code, preview with Space, and inspect file properties.

## Build and run

Requires macOS, a Swift 6 toolchain with the macOS SDK, and Python 3.

```bash
bash scripts/build-app.sh release
open build/release/PathDeck.app
```

Or open PathDeck.xcodeproj and run the PathDeck scheme. Core tests: `bash scripts/swift.sh test`.
