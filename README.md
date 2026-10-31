<p align="center">
  <img src="assets/branding/PathDeck-master.png" width="96" alt="PathDeck app icon">
</p>

<h1 align="center">PathDeck</h1>
<p align="center">Clear paths. Familiar controls. A native Mac workspace for your files.</p>
<p align="center"><strong>English</strong> · <a href="README_zh.md">简体中文</a></p>

PathDeck is a native macOS file manager built with **Swift and AppKit**. Type a path, jump to a folder, and get back to your work. It brings an editable address bar, useful context menus, and familiar Windows file controls to the Mac, with native tabs, Quick Look, and light and dark appearances.

![PathDeck displaying image thumbnails in its tile view](docs/images/showcase/tiles-light.png)

*Screenshots show the actual AppKit interface with sample files. The app interface is currently in Simplified Chinese.*

## Features

- **Browse images at a glance.** The default tile view shows image thumbnails alongside folders and file icons. Switch to the details list whenever you need columns, dates, or sizes. Each tab remembers its view.
- **Go straight to a path.** Switch between breadcrumbs and an editable address bar. Use absolute paths, `~`, relative paths, or local `file://` URLs. Enter a file path to open its parent folder and select the file.
- **Keep folders within reach.** Browse the directory tree, pin favorite folders, rename their display labels, and reorder them. Filter the current folder by name without starting a recursive search.
- **Use familiar file controls.** Create folders and text files, rename inline, copy, cut, paste, or move items to Trash. Open a folder in Terminal or files in VS Code from the context menu.
- **Move files between places.** Drag files between windows, folders, and tabs, or exchange them with Finder. Hover over a tab’s folder icon to switch to that tab and drop into its directory.
- **Undo file changes.** Undo new empty files or folders, renames, and moves. File identity checks and conflict handling protect items that changed after the original operation.
- **Pick up where you left off.** Restore windows, tabs, folders, selected items, filters, sorting, and list layout after restarting. Each tab keeps its own browsing state.
- **Stay native.** Press Space for Quick Look, inspect file properties, use keyboard navigation, and choose a comfortable list density. Folder changes refresh automatically.

## A closer look

### A grid for images, a list for details

Use the view switch beside the filter box, or press `⌘1` for tiles and `⌘2` for details. Thumbnails load in the background as images become visible; large photos are decoded to preview size.

![PathDeck's details list with the view switch beside the filter box](docs/images/showcase/overview-light.png)

### Paths you can see and edit

Click the address bar or press `⌘L` to type a location. Breadcrumbs keep the folder hierarchy visible, while name filtering narrows the files in front of you.

<table>
  <tr>
    <td width="50%"><img src="docs/images/showcase/path-entry.png" alt="Editable path bar in PathDeck"><br><strong>Enter a path directly</strong></td>
    <td width="50%"><img src="docs/images/showcase/name-filter.png" alt="PathDeck filtering the current folder for notes"><br><strong>Find files in the current folder</strong></td>
  </tr>
</table>

### Everyday file work, close at hand

Rename a file where it is listed, inspect its path and permissions, or open it in another app. File tasks share one queue across windows, with results and cancellation available in the task panel.

<table>
  <tr>
    <td width="66%" valign="top"><img src="docs/images/showcase/inline-rename.png" alt="Renaming a project document inline in the file list"><br><strong>Rename without leaving the list</strong></td>
    <td width="34%" valign="top"><img src="docs/images/showcase/file-properties.png" alt="Native file properties showing a sample document's path, size, dates and permissions"><br><strong>Inspect file details</strong></td>
  </tr>
</table>

### Light and dark, with native controls

PathDeck follows the system appearance and keeps standard selection, focus, scrolling, and text editing behavior.

![PathDeck displaying the image gallery in dark appearance](docs/images/showcase/tiles-dark.png)

## Build and run

**Requirements:** macOS, a Swift 6 toolchain with the macOS SDK, and Python 3. The app targets macOS 14 and later; development and validation currently use Apple Silicon. There are no third-party runtime dependencies.

```bash
git clone https://github.com/jackie-cqz/PathDeck.git
cd PathDeck
bash scripts/build-app.sh release
open build/release/PathDeck.app
```

The script builds a locally signed app without an Apple Developer account. Drag the resulting `PathDeck.app` into Applications to keep it installed.

Prefer Xcode? Open `PathDeck.xcodeproj`, select the **PathDeck** scheme and **My Mac**, then run. You can also build with Command Line Tools using the scripts above.

## Keyboard shortcuts

| Action | Mac | Windows controls in the file list |
| --- | --- | --- |
| Tiles / details | `⌘1` / `⌘2` | View switch |
| Edit the path | `⌘L` | `Ctrl+L` / `Alt+D` |
| Copy / cut / paste | `⌘C` / `⌘X` / `⌘V` | `Ctrl+C` / `Ctrl+X` / `Ctrl+V` |
| Undo | `⌘Z` | `Ctrl+Z` |
| Open a selection | `⌘↓` | `Enter` |
| Rename | Context menu; `Enter` with Windows controls off | `F2` |
| New folder | `⌘⇧N` | `Ctrl+Shift+N` |
| Move to Trash | `⌘⌫` | Forward Delete |
| Filter this folder | `⌘F` | `Ctrl+F` |
| Refresh | `⌘R` | `F5` |
| Back / forward | `⌘[` / `⌘]` | `Alt+←` / `Alt+→` |
| Parent folder | `⌘↑` | `Alt+↑` |
| New window / tab / close | `⌘N` / `⌘T` / `⌘W` | `Ctrl+N` / `Ctrl+T` / `Ctrl+W` |
| Switch tabs | `⌘⇧[` / `⌘⇧]` | `Ctrl+Shift+Tab` / `Ctrl+Tab` |
| Quick Look | `Space` | `Space` |
| Properties | `⌘I` | `Alt+Enter` |

Toggle Windows controls in the PathDeck menu. File-list shortcuts apply while the list is focused; text fields keep normal editing and undo behavior. In Windows mode, Backspace goes back and Control-click selects multiple items.

## Working with files

- **Drag behavior:** within PathDeck, same-volume drops move by default; external or cross-volume drops copy. Hold Option, or Control with Windows controls enabled, to copy. Dragging out to another app offers a copy.
- **Conflicts and undo:** existing files are never silently replaced. Choose to skip, keep both copies, or cancel. Undo covers creation, renaming, and same-volume moves; undoing creation requires an unchanged empty item and moves it to Trash. Copy undo, Trash undo, and file redo are not provided.
- **Storage and access:** cross-volume copying is supported; cross-volume moves and folder merging are not. Dragging accepts local file URLs. macOS controls access to protected folders. Settings and operation records stay in `~/Library/Application Support/PathDeck/`.

## Development

```bash
# Core tests
bash scripts/swift.sh test

# Build a debug app
bash scripts/build-app.sh debug

# Core tests, packaging, and native window checks (requires a graphical session)
bash scripts/verify.sh

# Check the generated Xcode project after adding or removing Swift files
python3 scripts/generate-project.py --check
```

To regenerate the product screenshots from the real AppKit views, run `python3 scripts/capture-readme.py` in a graphical macOS session. It uses a temporary sample workspace and private settings.

See the [product specification](SPEC.md), [design decisions](docs/decisions.md), and [validation notes](docs/tiles-validation.md) for implementation details. These documents are primarily in Chinese. Issues and focused pull requests are welcome; include reproduction steps for bugs and the validation relevant to a change.
