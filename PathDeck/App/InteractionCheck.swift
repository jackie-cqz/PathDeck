import AppKit
import QuickLookUI
#if SWIFT_PACKAGE
import PathDeckCore
#endif

/// Exercises real AppKit windows, native tab groups, field editors and preview control.
@MainActor
enum InteractionCheck {
    static func run(browser original: BrowserViewController, fixture: URL) async -> [String: Bool] {
        guard let app = NSApp.delegate as? AppDelegate, let first = app.mainWindowController else { return ["interactionApplication": false] }
        var checks: [String: Bool] = [:]
        let previousCompact = original.preferences.value.compactList
        let previousKeyboard = original.fileList.windowsFriendly
        original.fileList.windowsFriendly = true; original.preferences.value.windowsFriendly = true
        let starting = Set(app.windowControllers.map(ObjectIdentifier.init))
        NSApp.activate(); first.window?.makeKeyAndOrderFront(nil); first.window?.makeMain()
        _ = await ReliabilityCheck.eventually { first.window?.isMainWindow == true }
        defer {
            for controller in Array(app.windowControllers) where !starting.contains(ObjectIdentifier(controller)) { controller.window?.close() }
            original.preferences.value.compactList = previousCompact
            original.fileList.compact = previousCompact ?? false
            original.fileList.windowsFriendly = previousKeyboard; original.preferences.value.windowsFriendly = previousKeyboard
            first.window?.makeKeyAndOrderFront(nil)
        }
        do {
            let root = fixture.appendingPathComponent("Interaction", isDirectory: true)
            let a = root.appendingPathComponent("Source", isDirectory: true), b = root.appendingPathComponent("Target", isDirectory: true)
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let file = a.appendingPathComponent("Preview 中文.txt"), other = a.appendingPathComponent("Other.txt")
            try Data("PathDeck preview contents".utf8).write(to: file); try Data("other".utf8).write(to: other)
            first.window?.makeKeyAndOrderFront(nil)
            let count = app.windowControllers.count
            invokeMainMenu("文件", "新建窗口")
            guard let separate = app.windowControllers.last, separate !== first else { return ["newWindowCreatesIndependentWindow": false] }
            await separate.browser.waitForNavigation()
            _ = await ReliabilityCheck.eventually { separate.window?.isMainWindow == true }
            checks["newWindowCreatesIndependentWindow"] = app.windowControllers.count == count + 1 && (separate.window?.tabbedWindows?.count ?? 1) == 1
            separate.browser.navigate(to: a); await separate.browser.waitForNavigation()
            invokeMainMenu("文件", "新建标签页")
            guard let tab = app.windowControllers.last, tab !== separate, let tabWindow = tab.window else { return ["newTabCreatesNativeGroup": false] }
            await tab.browser.waitForNavigation()
            _ = await ReliabilityCheck.eventually { tabWindow.isMainWindow }
            checks["newTabCreatesNativeGroup"] = separate.window?.tabGroup === tabWindow.tabGroup && tabWindow.tabbedWindows?.count == 2
            tab.browser.navigate(to: b); await tab.browser.waitForNavigation()
            checks["tabNavigationIsIndependent"] = separate.browser.session.currentDirectory == a && tab.browser.session.currentDirectory == b && original !== tab.browser
            tab.browser.fileList.focus()
            checks["altLeftRoutesBack"] = key(tabWindow, 123, "", .option)
            await tab.browser.waitForNavigation()
            checks["tabHistoryIsIndependent"] = tab.browser.session.currentDirectory == a && separate.browser.session.currentDirectory == a
            _ = key(tabWindow, 124, "", .option); await tab.browser.waitForNavigation()
            checks["altRightRoutesForward"] = tab.browser.session.currentDirectory == b
            let history = tab.browser.session.canGoBack
            _ = key(tabWindow, 96, "", .function); await tab.browser.waitForNavigation()
            checks["f5RefreshRetainsHistory"] = tab.browser.session.contentState == .loaded && tab.browser.session.canGoBack == history
            _ = key(tabWindow, 126, "", .option); await tab.browser.waitForNavigation()
            checks["altUpNavigatesToParent"] = tab.browser.session.currentDirectory == root
            tab.browser.goBack(nil); await tab.browser.waitForNavigation()
            let jobs = tab.browser.actions.operations.records.count
            _ = key(tabWindow, 45, "N", [.control, .shift])
            if let created = tab.browser.actions.operations.records.last, tab.browser.actions.operations.records.count == jobs + 1 {
                let result = await tab.browser.actions.wait(for: created.id)
                checks["controlShiftNCreatesFolderInCurrentPage"] = result.successCount == 1 && result.request.destination?.url == b && tab.browser.fileList.isRenaming
                (tabWindow.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            } else { checks["controlShiftNCreatesFolderInCurrentPage"] = false }
            _ = key(tabWindow, 3, "f", .control)
            checks["controlFFocusesFilter"] = tab.browser.filterBar.field.currentEditor() != nil
            let jobsBeforeEditing = tab.browser.actions.operations.records.count
            checks["textFocusDoesNotInterceptFileShortcuts"] = !key(tabWindow, 45, "N", [.control, .shift]) && tab.browser.actions.operations.records.count == jobsBeforeEditing
            tab.browser.fileList.focus()
            _ = key(tabWindow, 48, "\t", .control)
            checks["controlTabSelectsOtherPage"] = await ReliabilityCheck.eventually { tabWindow.tabGroup?.selectedWindow === separate.window }
            separate.window?.makeKeyAndOrderFront(nil); separate.window?.makeMain()
            _ = await ReliabilityCheck.eventually { separate.window?.isMainWindow == true }
            app.editLocation(nil)
            checks["menuRoutesToActivePage"] = separate.browser.addressBar.path.currentEditor() != nil && tab.browser.addressBar.path.currentEditor() == nil
            separate.browser.fileList.focus()
            if let window = separate.window { _ = key(window, 48, "\t", [.control, .shift]) }
            checks["controlShiftTabSelectsOtherPage"] = await ReliabilityCheck.eventually { tabWindow.tabGroup?.selectedWindow === tabWindow }
            exportViews(tabWindow, name: "tabs")
            app.detachTab(nil)
            checks["detachTabMakesIndependentWindow"] = (tabWindow.tabbedWindows?.count ?? 1) == 1 && (separate.window?.tabbedWindows?.count ?? 1) == 1

            let source = separate.browser, target = tab.browser
            source.windowForTesting?.makeKeyAndOrderFront(nil); source.windowForTesting?.makeMain()
            _ = await ReliabilityCheck.eventually { source.view.window?.isMainWindow == true }
            source.fileList.focus()
            guard let row = source.session.visibleItems.firstIndex(where: { $0.url == file }), let table = source.fileList.keyboardView as? NSTableView else { return checks.merging(["previewFixtureFound": false]) { _, new in new } }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if let window = source.view.window { _ = key(window, 120, "", .function) }
            checks["f2StartsInlineRename"] = source.fileList.isRenaming && source.view.window?.firstResponder is NSTextView
            (source.view.window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            if let window = source.view.window { _ = key(window, 49, " ", []) }
            checks["quickLookUsesRealFileURL"] = await ReliabilityCheck.eventually { QLPreviewPanel.shared()?.isVisible == true && QLPreviewPanel.shared()?.isKeyWindow == true && source.preview.controlsPanel && source.preview.urls == [file] }
            if let panel = QLPreviewPanel.shared(), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
                checks["quickLookKeyboardDelegateInstalled"] = (panel.delegate as AnyObject?) === source.preview && source.preview.responds(to: NSSelectorFromString("previewPanel:handleEvent:"))
                panel.sendEvent(event)
            }
            checks["spaceToggleRestoresListFocus"] = await ReliabilityCheck.eventually { QLPreviewPanel.shared()?.isVisible == false && source.view.window?.isKeyWindow == true && source.view.window?.firstResponder === table }
            table.selectAll(nil); source.previewSelection(nil)
            checks["quickLookSupportsMultipleSelection"] = await ReliabilityCheck.eventually { source.preview.urls.count == 2 && QLPreviewPanel.shared()?.isVisible == true && QLPreviewPanel.shared()?.dataSource?.numberOfPreviewItems(in: QLPreviewPanel.shared()) == 2 }
            source.preview.dismiss()
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if let window = source.view.window { _ = key(window, 36, "\r", .option) }
            if let properties = source.propertyWindows.last {
                await properties.waitForLoad()
                checks["altEnterOpensSelectedFileProperties"] = properties.values.first?.url == file && properties.window?.isVisible == true
                properties.window?.close()
            } else { checks["altEnterOpensSelectedFileProperties"] = false }
            source.showProperties([file, b, root.appendingPathComponent("gone")])
            if let properties = source.propertyWindows.last {
                await properties.waitForLoad()
                checks["propertiesShowsActualMetadataAndErrors"] = properties.values.count == 3 && properties.values.first?.bytes == 25 && properties.detail.contains(file.path) && properties.detail.contains("POSIX") && properties.values.last?.error != nil
                if let window = properties.window { exportViews(window, name: "properties") }
                properties.window?.close(); checks["propertiesCloseReleasesController"] = source.propertyWindows.isEmpty
            }
            source.windowForTesting?.makeKeyAndOrderFront(nil); source.windowForTesting?.makeMain(); source.fileList.focus()
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let context = source.fileList.contextMenu(at: row)
            checks["fileContextHasPreviewPropertiesAndGroups"] = context?.items.contains { $0.title == "快速预览" } == true && context?.items.contains { $0.title == "属性…" } == true && (context?.items.filter(\.isSeparatorItem).count ?? 0) >= 2
            let folderMenu = original.sidebar.contextMenu(for: b, favoriteRoot: false)
            checks["treeContextOffersNewPages"] = folderMenu.items.contains { $0.title == "在新标签页打开" } && folderMenu.items.contains { $0.title == "在新窗口打开" }
            let blankMenu = source.fileList.contextMenu(at: -1)
            checks["blankContextCapturesNewPageDirectory"] = (blankMenu?.items.first { $0.title == "在新标签页打开" }?.representedObject as? [URL]) == [a]
            checks["allPagesShareOperationsAndClipboard"] = source.actions.operations === target.actions.operations && source.actions.clipboard === target.actions.clipboard
            source.actions.copy([source.session.items[row].reference], cut: true)
            separate.window?.close()
            if let id = await target.actions.paste() {
                let result = await target.actions.wait(for: id)
                checks["cutPasteSurvivesSourceWindowClose"] = result.successCount == 1 && !FileManager.default.fileExists(atPath: file.path) && (try? String(contentsOf: b.appendingPathComponent(file.lastPathComponent), encoding: .utf8)) == "PathDeck preview contents" && target.actions.clipboard.cutURLs.isEmpty
            } else { checks["cutPasteSurvivesSourceWindowClose"] = false }

            // A queued copy belongs to an action controller even after its browser is released.
            // The conflict must move to a live window, preserving both original files.
            try Data("existing target".utf8).write(to: b.appendingPathComponent("Other.txt"))
            var closing = app.makeWindow(at: b)
            await closing?.browser.waitForNavigation()
            weak var releasedBrowser = closing?.browser
            let references = await target.actions.operations.engine.capture([other])
            closing?.browser.actions.copy(references, cut: false)
            if let id = await closing?.browser.actions.paste() {
                closing?.window?.close(); closing = nil
                checks["closedBrowserReleasesDuringOwnedTask"] = await ReliabilityCheck.eventually { releasedBrowser == nil }
                releasedBrowser = nil
                let sheetShown = await ReliabilityCheck.eventually { app.windowControllers.contains { $0.window?.attachedSheet != nil } }
                checks["conflictAfterOwnerCloseUsesLiveWindow"] = sheetShown
                if let sheet = app.windowControllers.compactMap({ $0.window?.attachedSheet }).first, let content = sheet.contentView {
                    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                    if let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "保留两份" }) { button.performClick(nil) }
                    else { target.actions.context.cancelAll() }
                } else { target.actions.context.cancelAll() }
                let result = await target.actions.operations.wait(for: id)
                checks["copyCompletesAfterOwnerWindowClose"] = result.successCount == 1 && (try? String(contentsOf: b.appendingPathComponent("Other.txt"), encoding: .utf8)) == "existing target" && (try? String(contentsOf: b.appendingPathComponent("Other (2).txt"), encoding: .utf8)) == "other"
            } else { closing?.window?.close(); checks["copyCompletesAfterOwnerWindowClose"] = false }
            original.sidebar.pin(b)
            checks["favoritesSynchronizeAcrossWindows"] = target.sidebar.favoritePaths.contains(b.path)
            original.sidebar.removeFavorite(b)

            tabWindow.makeKeyAndOrderFront(nil); tabWindow.makeMain()
            _ = await ReliabilityCheck.eventually { tabWindow.isMainWindow }
            target.fileList.focus(); app.toggleCompactList(nil)
            checks["densityChangeAppliesAcrossWindows"] = app.windowControllers.allSatisfy { $0.browser.fileList.compact == original.preferences.value.compactList }
            await original.preferences.flush()
            let saved = await PreferencesStore(url: original.preferences.store.url).load()
            checks["densityPreferencePersists"] = saved.preferences.compactList == original.preferences.value.compactList
            let tabCount = app.windowControllers.count
            _ = key(tabWindow, 17, "t", .control)
            if let closingTab = app.windowControllers.last, closingTab !== tab {
                await closingTab.browser.waitForNavigation(); closingTab.browser.fileList.focus()
                if let window = closingTab.window { _ = key(window, 13, "w", .control) }
                checks["controlTAndWCreateAndCloseTab"] = app.windowControllers.count == tabCount && tabWindow.isVisible
            } else { checks["controlTAndWCreateAndCloseTab"] = false }
        } catch { checks["interactionFixtures"] = false; fputs("Interaction check: \(error)\n", stderr) }
        return checks
    }
    private static func invokeMainMenu(_ menu: String, _ title: String) {
        guard let item = NSApp.mainMenu?.items.first(where: { $0.title == menu })?.submenu?.items.first(where: { $0.title == title }), let action = item.action else { return }
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }
    @discardableResult private static func key(_ window: NSWindow, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return false }
        return window.performKeyEquivalent(with: event)
    }
    private static func exportViews(_ window: NSWindow, name: String) {
        guard let destination = ProcessInfo.processInfo.environment["PATHDECK_SNAPSHOT_DIR"], let view = window.contentView else { return }
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = window.appearance
        for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("pathdeck-\(name)-\(style).png"))
            }
        }
        window.appearance = previous
    }
}

private extension BrowserViewController {
    var windowForTesting: NSWindow? { viewIfLoaded?.window }
}
