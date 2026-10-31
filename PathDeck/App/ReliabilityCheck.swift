import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

/// Integration checks use only this process's disposable fixture and private settings.
@MainActor
enum ReliabilityCheck {
    static func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
    static func run(browser: BrowserViewController, window: NSWindow, fixture: URL) async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        do {
            let fm = FileManager.default
            let directory = fixture.appendingPathComponent("Reliability", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("中文 👋 é.txt")
            try Data("first".utf8).write(to: file)
            browser.navigate(to: directory); browser.applicationActivated(); await browser.waitForNavigation()
            checks["queuedRefreshCannotSupersedeNavigation"] = await eventually { browser.session.currentDirectory == directory && browser.session.contentState == .loaded }
            if let reference = browser.session.items.first?.reference {
                browser.actions.beginRename([reference])
                browser.navigate(to: fixture.appendingPathComponent("Empty", isDirectory: true)); await browser.waitForNavigation()
                checks["explicitNavigationEndsInlineRename"] = !browser.fileList.isRenaming
                browser.navigate(to: directory); await browser.waitForNavigation()
            }
            checks["watchInstalled"] = await eventually { await browser.isMonitoringCurrentDirectory() }
            try? await Task.sleep(for: .milliseconds(150))
            let added = directory.appendingPathComponent("external.txt")
            let started = ProcessInfo.processInfo.systemUptime
            try Data().write(to: added)
            checks["externalCreateWithinOneSecond"] = await eventually { browser.session.items.contains { $0.url == added } } && ProcessInfo.processInfo.systemUptime - started < 1
            _ = browser.fileList.contextMenu(at: browser.session.items.firstIndex(where: { $0.url == file }) ?? 0)
            let renamed = directory.appendingPathComponent("renamed 👋.txt")
            try fm.moveItem(at: file, to: renamed)
            checks["externalRenamePreservesSelection"] = await eventually { browser.fileList.selectedURLs.contains(renamed) }
            try? await Task.sleep(for: .milliseconds(150))
            // Non-atomic content writes don't change the parent directory's entries.
            let handle = try FileHandle(forWritingTo: renamed)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(" more contents".utf8)); try handle.close()
            checks["visibleFileMetadataRefreshes"] = await eventually { browser.session.items.first(where: { $0.url == renamed })?.byteCount == 19 }
            browser.addressBar.beginEditing()
            let draft = directory.path + "/unfinished"
            (browser.addressBar.path.currentEditor() as? NSTextView)?.insertText(draft, replacementRange: NSRange(location: 0, length: (browser.addressBar.path.stringValue as NSString).length))
            try fm.removeItem(at: added)
            checks["externalDeleteRefreshes"] = await eventually { !browser.session.items.contains { $0.url == added } }
            checks["refreshPreservesPathDraft"] = browser.addressBar.isEditing && browser.addressBar.path.stringValue == draft && browser.addressBar.path.currentEditor() != nil
            (browser.addressBar.path.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            if let reference = browser.session.items.first?.reference {
                browser.actions.beginRename([reference])
                let duringRename = directory.appendingPathComponent("during-rename.txt")
                try Data().write(to: duringRename)
                try? await Task.sleep(for: .milliseconds(400))
                checks["watchDoesNotInterruptInlineRename"] = browser.fileList.isRenaming && window.firstResponder is NSTextView
                (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                checks["deferredRefreshRunsAfterRename"] = await eventually { browser.session.items.contains { $0.url == duringRename } }
            }
            let relocated = fixture.appendingPathComponent("Relocated", isDirectory: true)
            browser.addressBar.beginEditing()
            let renameDraft = directory.path + "/pending"
            (browser.addressBar.path.currentEditor() as? NSTextView)?.insertText(renameDraft, replacementRange: NSRange(location: 0, length: (browser.addressBar.path.stringValue as NSString).length))
            try fm.moveItem(at: directory, to: relocated)
            checks["currentDirectoryRenameFollowsIdentity"] = await eventually { browser.session.currentDirectory.path == relocated.path && browser.session.contentState == .loaded }
            checks["directoryRenamePreservesDraft"] = browser.addressBar.path.stringValue == renameDraft && browser.addressBar.path.currentEditor() != nil
            (browser.addressBar.path.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            try? await Task.sleep(for: .milliseconds(150))
            try fm.removeItem(at: relocated)
            checks["deletedDirectoryReportsFailure"] = await eventually { if case .failed = browser.session.contentState { return true }; return false }
            checks["unavailableDirectoryDisablesWrites"] = !browser.actions.canWrite && browser.actions.create(.newFolder) == nil
            browser.navigate(to: fixture); await browser.waitForNavigation()
            checks["canRecoverToAnotherDirectory"] = browser.session.contentState == .loaded && browser.session.currentDirectory == fixture
            for i in 0..<50 { browser.navigate(to: i.isMultiple(of: 2) ? fixture : fixture.appendingPathComponent("Empty", isDirectory: true)) }
            await browser.waitForNavigation()
            checks["rapidNavigationNewestWins"] = browser.session.currentDirectory.lastPathComponent == "Empty" && browser.session.contentState == .loaded && browser.fileList.rowCount == browser.session.items.count
            browser.navigate(to: fixture); await browser.waitForNavigation()
            checks["tableAccessibilityLabel"] = browser.fileList.keyboardView.accessibilityLabel() == "文件列表"
            checks["addressAccessibilityLabel"] = browser.addressBar.path.accessibilityLabel() == "输入文件夹路径"
            browser.fileList.focus(); window.selectNextKeyView(nil)
            checks["tabMovesToTaskButton"] = (window.firstResponder as? NSButton)?.accessibilityLabel() == "文件任务"
            window.selectPreviousKeyView(nil)
            checks["shiftTabReturnsToList"] = window.firstResponder === browser.fileList.keyboardView
            let oldAppearance = window.appearance
            for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                window.appearance = NSAppearance(named: name); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                checks["appearanceLayout." + name.rawValue] = browser.fileList.view.bounds.width > 300 && browser.addressBar.path.frame.width > 300
            }
            window.appearance = oldAppearance
            checks.merge(await restoration(browser: browser, window: window, fixture: fixture)) { _, new in new }
            browser.stopMonitoring()
            checks["closingReleasesWatchers"] = await eventually { await browser.monitorCount() == 0 }
            browser.resumeMonitoring()
            checks["reopenRestartsWatchers"] = await eventually { await browser.monitorCount() > 0 }
            checks["resourcesBounded"] = await browser.monitorCount() <= 64 && browser.fileList.iconCacheCount <= 128 && browser.session.history.count <= 50
            browser.clearRecentDirectories(nil)
            checks["clearHistory"] = browser.preferences.value.recentDirectories.isEmpty && !browser.session.canGoBack && !browser.session.canGoForward
        } catch { checks["reliabilityFixtureSucceeded"] = false; fputs("Reliability check: \(error)\n", stderr) }
        return checks
    }
    private static func restoration(browser: BrowserViewController, window: NSWindow, fixture: URL) async -> [String: Bool] {
        browser.session.changeSort(FileSort(column: .size, ascending: false))
        let columns = [ColumnPreference(id: "size", width: 110), ColumnPreference(id: "name", width: 401), ColumnPreference(id: "modified", width: 155, hidden: true), ColumnPreference(id: "kind", width: 131)]
        browser.fileList.restoreColumns(columns); browser.fileList.windowsFriendly = false
        if !browser.session.showHidden { browser.toggleHidden(nil); await browser.waitForNavigation() }
        browser.capturePreferences()
        browser.preferences.value.favorites = [fixture.path]
        browser.preferences.value.sidebarWidth = 282
        browser.preferences.value.window = WindowPlacement(x: window.frame.minX, y: window.frame.minY, width: 960, height: 620)
        await browser.preferences.flush()
        let loaded = PreferencesController(store: PreferencesStore(url: browser.preferences.store.url)); await loaded.load(migrateLegacy: false)
        let session = BrowserSession(initialDirectory: URL(fileURLWithPath: loaded.value.lastDirectory ?? "/"))
        session.sort = loaded.value.sort; session.showHidden = loaded.value.showHidden
        let controller = MainWindowController(session: session, preferences: loaded)
        controller.showWindow(nil)
        guard let nextWindow = controller.window, let next = nextWindow.contentViewController as? BrowserViewController else { return ["windowRestoration": false] }
        await next.waitForNavigation(); await next.waitForSidebar(); nextWindow.contentView?.layoutSubtreeIfNeeded()
        var result: [String: Bool] = [
            "restoredDirectory": next.session.currentDirectory == fixture,
            "restoredColumns": next.fileList.columnPreferences() == columns,
            "restoredSortAndHidden": next.session.sort == FileSort(column: .size, ascending: false) && next.session.showHidden,
            "restoredKeyboardStyle": !next.fileList.windowsFriendly,
            "restoredWindowFrame": abs(nextWindow.frame.width - 960) < 2 && abs(nextWindow.frame.height - 620) < 2,
            "restoredSidebarWidth": abs(loaded.value.sidebarWidth - 282) < 2,
            "restoredFavorites": loaded.value.favorites == [fixture.path],
        ]
        nextWindow.close(); await controller.persistAndFlush()
        loaded.value.lastDirectory = fixture.appendingPathComponent("missing-saved-directory").path
        let fallback = MainWindowController(session: BrowserSession(initialDirectory: URL(fileURLWithPath: loaded.value.lastDirectory!)), preferences: loaded)
        fallback.showWindow(nil)
        if let content = fallback.window?.contentViewController as? BrowserViewController {
            result["unavailableSavedDirectoryFallsBackHome"] = await eventually { content.session.currentDirectory == FileManager.default.homeDirectoryForCurrentUser && content.session.contentState == .loaded }
        } else { result["unavailableSavedDirectoryFallsBackHome"] = false }
        fallback.window?.close()
        window.makeKeyAndOrderFront(nil)
        return result
    }
}
