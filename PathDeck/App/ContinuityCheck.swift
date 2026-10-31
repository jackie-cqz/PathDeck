import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor enum ContinuityCheck {
    static func run(browser original: BrowserViewController, fixture: URL) async -> [String: Bool] {
        guard let app = NSApp.delegate as? AppDelegate else { return ["continuityDelegate": false] }
        let starting = Set(app.windowControllers.map(ObjectIdentifier.init))
        defer {
            for controller in Array(app.windowControllers) where !starting.contains(ObjectIdentifier(controller)) { controller.window?.close() }
            original.view.window?.makeKeyAndOrderFront(nil)
        }
        var checks: [String: Bool] = [:]
        do {
            let root = fixture.appendingPathComponent("Continuity", isDirectory: true), destination = root.appendingPathComponent("Other tab", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let originalFile = root.appendingPathComponent("Original.txt")
            try Data("original".utf8).write(to: originalFile)
            guard let source = app.makeWindow(at: root) else { return ["continuityWindow": false] }
            await source.browser.waitForNavigation()
            let reference = try FileReference.capture(originalFile)
            if let id = source.browser.actions.rename(reference, to: "Renamed.txt") {
                _ = await source.browser.actions.wait(for: id); source.browser.fileList.focus()
                let count = source.browser.actions.operations.records.count
                checks["commandZRoutesFileUndo"] = key(source, modifiers: .command)
                if let undo = source.browser.actions.operations.records.last, source.browser.actions.operations.records.count > count {
                    let result = await source.browser.actions.wait(for: undo.id)
                    checks["menuUndoRestoresRename"] = result.request.kind == .undo && result.successCount == 1 && FileManager.default.fileExists(atPath: originalFile.path)
                } else { checks["menuUndoRestoresRename"] = false }
            }
            fputs("Continuity: rename checked\n", stderr)
            let dragFile = root.appendingPathComponent("Tab drag.txt"); try Data("tab payload".utf8).write(to: dragFile)
            source.browser.navigate(to: root); await source.browser.waitForNavigation()
            guard let tab = app.makeWindow(at: destination, tabOf: source) else { return ["continuityTab": false] }
            await tab.browser.waitForNavigation(); tab.browser.fileList.windowsFriendly = true; tab.browser.drops.modifierFlags = { [] }
            source.window?.tabGroup?.selectedWindow = source.window
            checks["tabSourceFinishesRefresh"] = await ReliabilityCheck.eventually {
                await source.browser.waitForNavigation()
                return source.browser.drops.canStart && (source.browser.fileList.keyboardView as? NSTableView)?.isEnabled == true
            }
            let info = try DragDropCheck.sourceInfo(source.browser, urls: [dragFile], target: tab.browser)
            fputs("Continuity: tab source ready\n", stderr)
            if let drop = tab.window?.tab.accessoryView as? TabDropView {
                checks["tabHoverSelectsDestinationPage"] = drop.draggingEntered(info) == .move && tab.window?.tabGroup?.selectedWindow === tab.window
                checks["tabIconAcceptsFileDrop"] = drop.prepareForDragOperation(info) && drop.performDragOperation(info)
                source.browser.fileList.fileDragState.end()
                if let id = await tab.browser.drops.waitForPreparation() {
                    let moved = await tab.browser.actions.wait(for: id); await tab.browser.waitForNavigation(); tab.browser.fileList.focus()
                    checks["tabDropMovesRealFile"] = moved.successCount == 1 && (try? String(contentsOf: destination.appendingPathComponent("Tab drag.txt"), encoding: .utf8)) == "tab payload"
                    let count = tab.browser.actions.operations.records.count
                    checks["controlZRoutesFileUndo"] = key(tab, modifiers: .control)
                    if let undo = tab.browser.actions.operations.records.last, tab.browser.actions.operations.records.count > count {
                        let restored = await tab.browser.actions.wait(for: undo.id)
                        checks["undoRestoresDragMove"] = restored.successCount == 1 && (try? String(contentsOf: dragFile, encoding: .utf8)) == "tab payload"
                    } else { checks["undoRestoresDragMove"] = false }
                }
            }
            fputs("Continuity: tab move checked\n", stderr)
            source.window?.tabGroup?.selectedWindow = source.window
            source.window?.makeKeyAndOrderFront(nil); source.window?.makeMain(); await source.browser.waitForNavigation()
            if let id = source.browser.actions.create(.newFolder) {
                let created = await source.browser.actions.wait(for: id)
                (source.window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                source.browser.fileList.focus()
                let count = source.browser.actions.operations.records.count; _ = key(source, modifiers: .command)
                if let undo = source.browser.actions.operations.records.last, source.browser.actions.operations.records.count > count {
                    let result = await source.browser.actions.wait(for: undo.id)
                    if let trash = result.results.first?.destination, let url = created.results.first?.destination {
                        checks["undoCreationUsesRecoverableTrash"] = result.successCount == 1 && !FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: trash.path)
                        try FileManager.default.moveItem(at: trash, to: url)
                    } else { checks["undoCreationUsesRecoverableTrash"] = false }
                } else { checks["undoCreationUsesRecoverableTrash"] = false }
            }
            fputs("Continuity: creation checked\n", stderr)
            source.window?.tabGroup?.selectedWindow = source.window
            source.window?.makeKeyAndOrderFront(nil); source.window?.makeMain()
            _ = await ReliabilityCheck.eventually { NSApp.keyWindow === source.window && NSApp.mainWindow === source.window }
            source.browser.focusFilter(nil)
            if let editor = source.window?.firstResponder as? NSTextView {
                checks["textEditorIsCommandTarget"] = NSApp.keyWindow?.firstResponder === editor
                let before = editor.string, count = source.browser.actions.operations.records.count
                editor.breakUndoCoalescing()
                editor.insertText("undo-probe", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.breakUndoCoalescing()
                fputs("Continuity: text inserted\n", stderr)
                _ = await ReliabilityCheck.eventually { editor.undoManager?.groupingLevel == 0 }
                let handled = key(source, modifiers: .command)
                checks["textEditingKeepsNativeUndo"] = handled && editor.string == before && source.browser.actions.operations.records.count == count
                if checks["textEditingKeepsNativeUndo"] == false { fputs("Text undo: handled=\(handled), lengths=\(before.count)/\(editor.string.count), queued=\(source.browser.actions.operations.records.count - count), groups=\(editor.undoManager?.groupingLevel ?? -1)\n", stderr) }
                editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            } else { checks["textEditingKeepsNativeUndo"] = false }
            fputs("Continuity: text undo checked\n", stderr)
            source.browser.navigate(to: root); await source.browser.waitForNavigation()
            source.browser.session.setFilter("Original"); WorkspaceRestartCheck.select(source.browser, names: ["Original.txt"])
            tab.browser.navigate(to: destination); await tab.browser.waitForNavigation()
            guard let other = app.makeWindow(at: root) else { return checks }
            await other.browser.waitForNavigation()
            source.window?.tabGroup?.selectedWindow = source.window; other.window?.makeKeyAndOrderFront(nil); other.window?.makeMain()
            let snapshot = WorkspaceController.capture([source, tab, other], active: other)
            let store = PreferencesStore(url: root.appendingPathComponent("workspace.json")); var prefs = AppPreferences(); prefs.workspace = snapshot; try await store.save(prefs)
            let loaded = await PreferencesStore(url: store.url).load()
            checks["workspaceSavedAsTwoGroupsThreePages"] = loaded.preferences.workspace?.groups.count == 2 && loaded.preferences.workspace?.groups.flatMap(\.pages).count == 3
            for window in [source, tab, other] { window.window?.close() }
            let restored = await app.restoreWorkspace(loaded.preferences.workspace!)
            fputs("Continuity: workspace restored\n", stderr)
            let after = WorkspaceController.capture(restored, active: app.mainWindowController)
            checks["workspaceRestoresTabGroupsAndOrder"] = after.groups.map { $0.pages.map(\.directory) } == snapshot.groups.map { $0.pages.map(\.directory) }
            checks["workspaceRestoresSelectedTabsAndWindow"] = after.groups.map(\.selectedIndex) == snapshot.groups.map(\.selectedIndex) && after.activeGroup == snapshot.activeGroup
            checks["workspaceRestoresSelectedFilesAndFilter"] = after.groups.first?.pages.first?.selection == snapshot.groups.first?.pages.first?.selection && after.groups.first?.pages.first?.filter == "Original"
            checks["workspaceRestoresScrollAnchor"] = after.groups.first?.pages.first?.anchor?.identity == snapshot.groups.first?.pages.first?.anchor?.identity
        } catch { checks["continuityFixtures"] = false; fputs("Continuity check: \(error)\n", stderr) }
        return checks
    }
    private static func key(_ controller: MainWindowController, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let window = controller.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) else { return false }
        // NSApplication offers Command equivalents to the main menu before the window.
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true || window.performKeyEquivalent(with: event)
    }
}
