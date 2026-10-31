import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

/// Runs the real field editor, navigation callbacks and table using disposable files.
@MainActor
enum ApplicationSmokeCheck {
    static func makeFixture() throws -> URL {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("PathDeck-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        guard let physical = candidate.withUnsafeFileSystemRepresentation({ path in path.flatMap { realpath($0, nil) } }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let child = root.appendingPathComponent("中文 Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("actual contents".utf8).write(to: child.appendingPathComponent("hello.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        return root
    }

    static func run(window: NSWindow, fixture: URL, reopen: () -> Void) async {
        defer { try? FileManager.default.removeItem(at: fixture) }
        guard let browser = window.contentViewController as? BrowserViewController else { print("Missing browser"); exit(1) }
        await browser.waitForNavigation()
        window.contentView?.layoutSubtreeIfNeeded()
        let initialFrame = window.frame
        var checks: [String: Bool] = [
            "windowVisible": window.isVisible,
            "initialDirectoryRead": browser.session.items.map(\.realName).sorted() == ["Empty", "中文 Folder"].sorted(),
            "menuInstalled": NSApplication.shared.mainMenu?.items.map(\.title) == ["PathDeck", "文件", "编辑", "显示", "前往", "窗口"],
        ]
        let locationMenuItem = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "前往" })?.submenu?.items.first
        let accepted = NSApplication.shared.sendAction(#selector(BrowserViewController.editLocation(_:)), to: locationMenuItem?.target, from: locationMenuItem)
        checks["commandRouting"] = accepted
        checks["pathFieldFocused"] = browser.addressBar.path.currentEditor() is NSTextView
        let child = fixture.appendingPathComponent("中文 Folder", isDirectory: true)
        await enter(child.path, in: browser)
        checks["enteredPathNavigates"] = browser.session.currentDirectory.path == child.path
        checks["realFileRendered"] = browser.fileList.rowCount == 1 && browser.session.items.first?.realName == "hello.txt"
        checks["pathAndRowsAgree"] = browser.addressBar.path.stringValue == browser.session.currentDirectory.path
        exportViews(window: window)
        await browser.waitForSidebar()
        checks["treeTracksPath"] = browser.sidebarDirectory?.path == browser.session.currentDirectory.path
        let previous = browser.session.currentDirectory
        await enter(fixture.appendingPathComponent("nonexistent").path, in: browser)
        checks["failedPathPreservesRows"] = browser.session.currentDirectory == previous && browser.fileList.rowCount == 1
        checks["failedInputRetained"] = browser.addressBar.path.stringValue.hasSuffix("nonexistent")
        checks["failedInputRemainsEditable"] = browser.addressBar.isEditing && !browser.addressBar.path.isHidden && browser.addressBar.path.currentEditor() != nil
        exportViews(window: window, prefix: "error")
        await enter(child.appendingPathComponent("hello.txt").path, in: browser)
        checks["filePathSelectsFile"] = browser.fileList.selectedURLs.contains(child.appendingPathComponent("hello.txt"))
        let itemMenu = browser.fileList.contextMenu(at: 0)
        let fileURLs = itemMenu?.items.first(where: { $0.title == "复制完整路径" })?.representedObject as? [URL]
        checks["fileMenuCapturesFile"] = fileURLs == [child.appendingPathComponent("hello.txt")]
        let blankMenu = browser.fileList.contextMenu(at: -1)
        let folderURLs = blankMenu?.items.first(where: { $0.title == "复制当前路径" })?.representedObject as? [URL]
        checks["blankMenuCapturesDirectory"] = folderURLs == [browser.session.currentDirectory]
        browser.addressBar.beginEditing()
        if let editor = browser.addressBar.path.currentEditor() as? NSTextView {
            editor.insertText(fixture.path + "/中", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            await browser.addressBar.waitForCompletions()
            checks["directoryCompletionVisible"] = browser.addressBar.completionCount == 1 && browser.addressBar.completionIsVisible
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            checks["tabAcceptsCompletion"] = browser.addressBar.path.stringValue == child.path + "/"
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await browser.waitForNavigation()
        } else { checks["directoryCompletionVisible"] = false; checks["tabAcceptsCompletion"] = false }
        browser.goBack(nil); await browser.waitForNavigation()
        checks["backReturnsToRoot"] = browser.session.currentDirectory.path == fixture.path
        browser.goForward(nil); await browser.waitForNavigation()
        checks["forwardReturnsToChild"] = browser.session.currentDirectory.path == child.path
        await enter(fixture.appendingPathComponent("Empty").path, in: browser)
        checks["emptyDirectoryIsLoaded"] = browser.session.contentState == .loaded && browser.fileList.rowCount == 0
        await enter(fixture.path, in: browser)
        browser.toggleHidden(nil); await browser.waitForNavigation()
        checks["hiddenToggleReadsRealItem"] = browser.session.items.contains { $0.realName == ".hidden" }
        browser.refreshDirectory(nil); await browser.waitForNavigation()
        checks["refreshDoesNotAddHistory"] = !browser.session.canGoForward
        fputs("Smoke: file operations\n", stderr)
        checks.merge(await fileOperations(browser: browser, fixture: fixture)) { _, new in new }
        fputs("Smoke: reliability\n", stderr)
        checks.merge(await ReliabilityCheck.run(browser: browser, window: window, fixture: fixture)) { _, new in new }
        fputs("Smoke: daily use\n", stderr)
        checks.merge(await DailyUseCheck.run(browser: browser, fixture: fixture)) { _, new in new }
        fputs("Smoke: interaction\n", stderr)
        checks.merge(await InteractionCheck.run(browser: browser, fixture: fixture)) { _, new in new }
        checks.merge(await DragDropCheck.run(browser: browser, fixture: fixture)) { _, new in new }
        checks.merge(await ContinuityCheck.run(browser: browser, fixture: fixture)) { _, new in new }
        fputs("Smoke: completed\n", stderr)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        checks["addressFitsMinimumSize"] = browser.addressBar.path.frame.width > 300
        checks["canResizeToMinimum"] = window.frame.width <= 825 && window.frame.height <= 525
        window.close(); reopen(); checks["canReopenWindow"] = window.isVisible
        window.setFrame(initialFrame, display: true)
        let passed = checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["milestone": "Interaction and appearance", "passed": passed, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        // Clean up before termination (NSApplication.terminate doesn't unwind defer).
        browser.stopMonitoring()
        await browser.preferences.flush()
        try? FileManager.default.removeItem(at: fixture)
        fflush(stdout)
        exit(passed ? 0 : 1)
    }

    private static func enter(_ input: String, in browser: BrowserViewController) async {
        browser.addressBar.beginEditing()
        guard let editor = browser.addressBar.path.currentEditor() as? NSTextView else { return }
        editor.insertText(input, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await browser.waitForNavigation()
        _ = await ReliabilityCheck.eventually { !browser.session.isLoading }
    }

    private static func exportViews(window: NSWindow, prefix: String = "browse") {
        guard let destination = ProcessInfo.processInfo.environment["PATHDECK_SNAPSHOT_DIR"], let view = window.contentView else { return }
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = window.appearance
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("pathdeck-m3-\(prefix)-\(name).png"))
        }
        window.appearance = previous
    }

    private static func fileOperations(browser: BrowserViewController, fixture: URL) async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let child = fixture.appendingPathComponent("中文 Folder", isDirectory: true)
        let target = fixture.appendingPathComponent("Empty", isDirectory: true)
        await enter(child.path, in: browser)
        let actions = browser.actions
        let resolver = actions.operations.resolveConflict
        defer { actions.operations.resolveConflict = resolver }
        if let id = actions.create(.newFolder) {
            let created = await actions.wait(for: id)
            checks["newFolderCreated"] = created.successCount == 1
            checks["newFolderStartsInlineRename"] = browser.fileList.isRenaming
            if let editor = browser.view.window?.firstResponder as? NSTextView {
                editor.insertText("Created Folder", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                if let renameID = actions.operations.records.last?.id, renameID != id {
                    let renamed = await actions.wait(for: renameID)
                    checks["inlineRenameCommits"] = renamed.successCount == 1 && FileManager.default.fileExists(atPath: child.appendingPathComponent("Created Folder").path)
                } else { checks["inlineRenameCommits"] = false }
            } else { checks["inlineRenameCommits"] = false }
        } else { checks["newFolderCreated"] = false }
        if let id = actions.create(.newTextFile) {
            let created = await actions.wait(for: id)
            checks["newTextFileIsEmpty"] = created.successCount == 1 && (try? Data(contentsOf: child.appendingPathComponent("Untitled.txt"))) == Data()
            if let window = browser.view.window { exportViews(window: window, prefix: "files") }
            if let editor = browser.view.window?.firstResponder as? NSTextView {
                let count = actions.operations.records.count
                editor.insertText("temporary", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                editor.deleteBackward(nil)
                checks["textDeleteDoesNotTouchFiles"] = actions.operations.records.count == count && FileManager.default.fileExists(atPath: child.appendingPathComponent("Untitled.txt").path)
                editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                checks["escapeCancelsRename"] = !browser.fileList.isRenaming && actions.operations.records.count == count
            }
        } else { checks["newTextFileIsEmpty"] = false }
        guard let source = browser.session.items.first(where: { $0.realName == "hello.txt" })?.reference else { checks["copyFileHasSource"] = false; return checks }
        await copyWhenReady([source], cut: false, in: browser)
        checks["copyWritesStandardFileURLs"] = actions.clipboard.hasFileURLs && actions.clipboard.cutURLs.isEmpty
        await enter(target.path, in: browser)
        if let id = await pasteWhenReady(browser) {
            let copied = await actions.wait(for: id)
            checks["pasteCopiesRealContents"] = copied.successCount == 1 && (try? Data(contentsOf: target.appendingPathComponent("hello.txt"))) == (try? Data(contentsOf: source.url))
            if checks["pasteCopiesRealContents"] == false { fputs("Copy failure: current=\(browser.session.currentDirectory.path) target=\(String(describing: copied.request.destination?.url.path)) results=\(copied.results)\n", stderr) }
        } else { checks["pasteCopiesRealContents"] = false }
        actions.operations.resolveConflict = { _ in ConflictDecision(.keepBoth) }
        if let id = await pasteWhenReady(browser) {
            let copied = await actions.wait(for: id)
            checks["keepBothCreatesNewName"] = copied.successCount == 1 && FileManager.default.fileExists(atPath: target.appendingPathComponent("hello (2).txt").path)
            if checks["keepBothCreatesNewName"] == false { fputs("Keep both failure: target=\(String(describing: copied.request.destination?.url.path)) results=\(copied.results)\n", stderr) }
        }
        await copyWhenReady([source], cut: true, in: browser)
        checks["cutDoesNotMoveEarly"] = FileManager.default.fileExists(atPath: source.url.path) && actions.clipboard.cutURLs.contains(source.url)
        if let id = await pasteWhenReady(browser) {
            let moved = await actions.wait(for: id)
            checks["cutPasteMovesSameObject"] = moved.successCount == 1 && !FileManager.default.fileExists(atPath: source.url.path) && (try? FileIdentity.read(target.appendingPathComponent("hello (3).txt"))) == source.identity
            checks["completedCutClearsIntent"] = actions.clipboard.cutURLs.isEmpty
        } else { checks["cutPasteMovesSameObject"] = false }
        if let item = browser.session.items.first(where: { $0.realName == "hello (2).txt" }) {
            await copyWhenReady([item.reference], cut: true, in: browser)
            actions.clipboard.pasteboard.clearContents(); actions.clipboard.pasteboard.setString("replacement text", forType: .string); actions.clipboard.synchronize()
            checks["clipboardReplacementClearsCut"] = actions.clipboard.cutURLs.isEmpty && FileManager.default.fileExists(atPath: item.url.path)
        }
        // This one disposable object is sent to the actual system Trash, then restored.
        // No existing Trash item is enumerated, deleted, or overwritten.
        if let item = browser.session.items.first(where: { $0.realName == "hello (3).txt" }) {
            actions.confirmTrash = { _ in true }
            if let id = await actions.trash([item.reference]) {
                let trashed = await actions.wait(for: id)
                checks["systemTrashMovesOnlyFixture"] = trashed.successCount == 1 && !FileManager.default.fileExists(atPath: item.url.path)
                if let location = trashed.results.first?.destination {
                    do { try FileManager.default.moveItem(at: location, to: item.url); checks["trashFixtureRestored"] = true }
                    catch { checks["trashFixtureRestored"] = false }
                } else { checks["trashFixtureRestored"] = false }
            }
        }
        // Partial cut: one item moves, a replaced item fails and keeps its intent.
        if let first = browser.session.items.first(where: { $0.realName == "hello.txt" }),
           let second = browser.session.items.first(where: { $0.realName == "hello (2).txt" }) {
            await copyWhenReady([first.reference, second.reference], cut: true, in: browser)
            do {
                try FileManager.default.moveItem(at: second.url, to: target.appendingPathComponent("kept-original"))
                try Data("replacement".utf8).write(to: second.url)
                let partialTarget = child.appendingPathComponent("Created Folder", isDirectory: true)
                await enter(partialTarget.path, in: browser)
                if let id = await pasteWhenReady(browser) {
                    let result = await actions.wait(for: id)
                    checks["partialCutRetainsOnlyFailedIntent"] = result.successCount == 1 && result.failureCount == 1 && actions.clipboard.cutURLs == [second.url]
                    checks["failedCutReplacementPreserved"] = (try? String(contentsOf: second.url, encoding: .utf8)) == "replacement"
                }
            } catch { checks["partialCutRetainsOnlyFailedIntent"] = false }
        }
        actions.showTasks()
        checks["taskWindowCanOpen"] = actions.panel.window?.isVisible == true
        actions.panel.window?.close()
        return checks
    }
    private static func pasteWhenReady(_ browser: BrowserViewController) async -> UUID? {
        var id: UUID?
        _ = await ReliabilityCheck.eventually {
            guard !browser.isNavigating, browser.session.contentState == .loaded else { return false }
            id = await browser.actions.paste(); return id != nil
        }
        return id
    }
    private static func copyWhenReady(_ references: [FileReference], cut: Bool, in browser: BrowserViewController) async {
        _ = await ReliabilityCheck.eventually {
            guard !browser.isNavigating, browser.session.contentState == .loaded else { return false }
            browser.actions.copy(references, cut: cut)
            return browser.actions.clipboard.hasFileURLs && (cut ? browser.actions.clipboard.cutURLs == Set(references.map(\.url)) : browser.actions.clipboard.cutURLs.isEmpty)
        }
    }
}
