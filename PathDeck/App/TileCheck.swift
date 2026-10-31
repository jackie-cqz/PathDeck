import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor enum TileCheck {
    static func makeImage(at url: URL, width: Int = 1200, height: Int = 800) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.65, green: 0.83, blue: 0.94, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.46, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: Double(width) * 0.68, y: Double(height) * 0.61, width: Double(width) * 0.13, height: Double(width) * 0.13)).fill()
        let mountains = NSBezierPath(); mountains.move(to: .zero); mountains.line(to: NSPoint(x: Double(width) * 0.3, y: Double(height) * 0.7)); mountains.line(to: NSPoint(x: Double(width) * 0.55, y: Double(height) * 0.25)); mountains.line(to: NSPoint(x: Double(width) * 0.77, y: Double(height) * 0.5)); mountains.line(to: NSPoint(x: width, y: 0)); mountains.close()
        NSColor(calibratedRed: 0.22, green: 0.51, blue: 0.44, alpha: 1).setFill(); mountains.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }; try data.write(to: url)
    }
    static func run(browser original: BrowserViewController, fixture: URL) async -> [String: Bool] {
        guard let app = NSApp.delegate as? AppDelegate else { return ["tileDelegate": false] }
        let preference = original.preferences.value.fileViewMode
        var created: MainWindowController?
        defer { created?.window?.close(); original.preferences.value.fileViewMode = preference; original.preferences.changed(); original.view.window?.makeKeyAndOrderFront(nil) }
        var checks: [String: Bool] = [:]
        do {
            let root = fixture.appendingPathComponent("Image Workspace", isDirectory: true)
            let folder = root.appendingPathComponent("Albums", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = root.appendingPathComponent("Landscape.png"), portrait = root.appendingPathComponent("Portrait.png"), corrupt = root.appendingPathComponent("Corrupt.jpg"), note = root.appendingPathComponent("Notes.txt")
            try makeImage(at: image); try makeImage(at: portrait, width: 600, height: 1000)
            try Data("invalid image".utf8).write(to: corrupt); try Data("notes".utf8).write(to: note)
            original.preferences.value.fileViewMode = nil
            guard let controller = app.makeWindow(at: root) else { return ["tileWindow": false] }; created = controller
            let browser = controller.browser
            await browser.waitForNavigation()
            checks["legacyPreferencesDefaultToTiles"] = browser.fileList.viewMode == .tiles
            browser.changeViewMode(.tiles); controller.window?.contentView?.layoutSubtreeIfNeeded()
            let grid = browser.fileList.grid, collection = grid.collection
            checks["tileModeShowsCollection"] = !grid.scroll.isHidden && browser.fileList.keyboardView === collection && collection.numberOfItems(inSection: 0) == 5
            checks["imageThumbnailsDecode"] = await ReliabilityCheck.eventually {
                let tiles = collection.visibleItems().compactMap { $0 as? FileTileItem }
                return tiles.filter { $0.hasThumbnail }.count == 2
            }
            let tiles = collection.visibleItems().compactMap { $0 as? FileTileItem }
            checks["thumbnailsArePixelBounded"] = tiles.filter(\.hasThumbnail).allSatisfy { tile in guard let size = tile.thumbnail.image?.size else { return false }; return max(size.width, size.height) <= 256 }
            guard let badItem = browser.session.items.first(where: { $0.url.path == corrupt.path }) else { throw CocoaError(.fileReadUnknown) }
            checks["corruptImageFallsBack"] = await withCheckedContinuation { continuation in grid.thumbnails.request(badItem) { continuation.resume(returning: $0 == nil) } }
            let index = browser.session.visibleItems.firstIndex { $0.url.path == image.path }!
            grid.select(IndexSet(integer: index))
            checks["tileSelectionUpdatesSession"] = browser.session.selection.contains(image) && browser.fileList.selectedURLs == [image]
            checks["tileContextMenuCapturesSelection"] = browser.fileList.contextMenu(at: index)?.items.contains { $0.title == "复制" } == true
            let onOpen = browser.fileList.onOpen; var opened: URL?
            browser.fileList.onOpen = { opened = $0.url }; browser.fileList.performShortcut(.open)
            checks["tileKeyboardOpenUsesSelectedFile"] = opened == image
            opened = nil
            checks["tileAccessibilityPressOpensFile"] = collection.item(at: IndexPath(item: index, section: 0))?.view.accessibilityPerformPress() == true && opened == image
            browser.fileList.onOpen = onOpen
            func modeKey(_ digit: String, code: UInt16) -> Bool {
                guard let window = controller.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: digit, charactersIgnoringModifiers: digit, isARepeat: false, keyCode: code) else { return false }
                return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
            }
            checks["command2SelectsDetails"] = modeKey("2", code: 19) && browser.fileList.viewMode == .details
            checks["detailsSwitchPreservesSelection"] = browser.fileList.selectedURLs == [image] && browser.session.selection == [image]
            checks["command1SelectsTiles"] = modeKey("1", code: 18) && browser.fileList.viewMode == .tiles
            checks["tileSwitchPreservesSelection"] = browser.fileList.selectedURLs == [image] && browser.pageSnapshot().fileViewMode == .tiles
            browser.actions.beginRename(browser.fileList.selectedReferences)
            checks["tilesSupportInlineRename"] = browser.fileList.isRenaming && controller.window?.firstResponder is NSTextView
            (controller.window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            checks["tileRenameEscapeDoesNotWrite"] = !browser.fileList.isRenaming && FileManager.default.fileExists(atPath: image.path)
            browser.actions.beginRename(browser.fileList.selectedReferences)
            let count = browser.actions.operations.records.count
            if let editor = controller.window?.firstResponder as? NSTextView {
                editor.insertText("Renamed.png", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                if let record = browser.actions.operations.records.last, browser.actions.operations.records.count > count {
                    let result = await browser.actions.wait(for: record.id)
                    checks["tileRenameChangesRealFile"] = result.successCount == 1 && FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.png").path)
                    if let id = browser.actionContext.undo(owner: browser.actions) { let undone = await browser.actions.wait(for: id); checks["tileRenameCanBeUndone"] = undone.successCount == 1 && FileManager.default.fileExists(atPath: image.path) }
                } else { checks["tileRenameChangesRealFile"] = false }
            }
            browser.fileList.focus(); collection.copy(nil)
            checks["tileCopyUsesSharedClipboard"] = browser.actions.clipboard.hasFileURLs
            browser.fileList.setCutURLs([image]); checks["tileCutAppearance"] = collection.visibleItems().contains { ($0 as? FileTileItem)?.name.stringValue == "Landscape.png" && $0.view.alphaValue == 0.45 }; browser.fileList.setCutURLs([])
            let writer = browser.fileList.grid.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: index, section: 0))
            let board = NSPasteboard(name: .init("PathDeck-tile-check-\(UUID().uuidString)")); if let writer { board.writeObjects([writer]) }; browser.fileList.fileDragState.begin(pasteboard: board)
            checks["tilesExportFileURLsAndIdentity"] = FileDragState.urls(in: board) == [image] && browser.fileList.fileDragState.references.first?.identity == browser.session.visibleItems[index].identity
            browser.fileList.fileDragState.end()
            let incoming = root.appendingPathComponent("incoming.txt"); try Data("drop".utf8).write(to: incoming)
            let pasteboard = NSPasteboard(name: .init("PathDeck-tile-external-\(UUID().uuidString)")); pasteboard.writeObjects([incoming as NSURL])
            let info = DragDropCheck.Info(board: pasteboard, source: nil, mask: .copy, window: controller.window)
            let folderIndex = browser.session.visibleItems.firstIndex { $0.url.path == folder.path }!
            let frame = collection.layoutAttributesForItem(at: IndexPath(item: folderIndex, section: 0))!.frame
            info.draggingLocation = collection.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            browser.drops.modifierFlags = { [] }
            _ = await ReliabilityCheck.eventually { await browser.waitForNavigation(); return browser.drops.canStart }
            checks["tilesAcceptFolderDrop"] = collection.draggingEntered(info) == .copy && collection.performDragOperation(info)
            if let id = await browser.drops.waitForPreparation() { let record = await browser.actions.wait(for: id); checks["tileDropCopiesRealFile"] = record.successCount == 1 && FileManager.default.fileExists(atPath: folder.appendingPathComponent("incoming.txt").path) }
            browser.session.setFilter("Portrait"); checks["tileFilterMatchesFiles"] = collection.numberOfItems(inSection: 0) == 1
            browser.session.setFilter("")
            if let directory = ProcessInfo.processInfo.environment["PATHDECK_TILE_SNAPSHOT"] { try export(controller.window!, to: URL(fileURLWithPath: directory)) }
            checks["tileViewPersistsInPreferences"] = browser.preferences.value.fileViewMode == .tiles && browser.pageSnapshot().fileViewMode == .tiles
        } catch { checks["tileFixture"] = false; fputs("Tile check: \(error)\n", stderr) }
        return checks
    }
    static func export(_ window: NSWindow, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("tiles-light", NSAppearance.Name.aqua), ("tiles-dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: image); try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
