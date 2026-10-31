import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
enum DailyUseCheck {
    static func run(browser: BrowserViewController, fixture: URL) async -> [String: Bool] {
        var checks: [String: Bool] = ["filteredContextCopiesOnlyVisibleSelection": false, "favoriteAliasSheetSavesTitle": false, "favoriteMoveMenuChangesOrder": false]
        do {
            let root = fixture.appendingPathComponent("Daily Use", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let a = root.appendingPathComponent("Café.txt"), b = root.appendingPathComponent("中文 👋.md")
            let folder = root.appendingPathComponent("Pinned", isDirectory: true), replacement = root.appendingPathComponent("Replacement", isDirectory: true)
            try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            browser.navigate(to: root); await browser.waitForNavigation()
            _ = await ReliabilityCheck.eventually { await browser.isMonitoringCurrentDirectory() }
            let row = browser.session.visibleItems.firstIndex(where: { $0.url == b }) ?? 0
            _ = browser.fileList.contextMenu(at: row)
            let filterMenu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "编辑" })?.submenu?.items.first(where: { $0.keyEquivalent == "f" })
            checks["filterShortcutRoutesToField"] = NSApplication.shared.sendAction(#selector(AppDelegate.focusFilter(_:)), to: filterMenu?.target, from: filterMenu) && browser.filterBar.field.currentEditor() != nil
            type("CAFE", browser)
            checks["filterMatchesRealNameAndDiacritics"] = browser.fileList.rowCount == 1 && browser.session.visibleItems.first?.url == a
            checks["filteredOutSelectionCannotBeOperatedOn"] = browser.session.selection.isEmpty && browser.fileList.selectedReferences.isEmpty
            let copyMenu = browser.fileList.contextMenu(at: 0)
            if let item = copyMenu?.items.first(where: { $0.title == "复制" }) {
                _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
                let copied = browser.actions.clipboard.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                checks["filteredContextCopiesOnlyVisibleSelection"] = copied == [a]
            }
            let added = root.appendingPathComponent("CAFE-new.txt"); try Data().write(to: added)
            checks["externalRefreshKeepsFilter"] = await ReliabilityCheck.eventually { browser.session.filterQuery == "CAFE" && browser.fileList.rowCount == 2 }
            type("no matches", browser)
            checks["filterNoMatchesPreservesDirectorySnapshot"] = browser.fileList.rowCount == 0 && browser.session.items.count == 5 && browser.session.contentState == .loaded
            (browser.filterBar.field.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            checks["escapeClearsFilterAndFocusesList"] = browser.session.filterQuery.isEmpty && browser.fileList.rowCount == 5 && browser.view.window?.firstResponder === browser.fileList.keyboardView
            type("CAFE", browser)
            if let id = browser.actions.create(.newTextFile) {
                let record = await browser.actions.wait(for: id)
                checks["createRevealsFileAndStartsRename"] = record.successCount == 1 && browser.session.filterQuery.isEmpty && browser.fileList.isRenaming
                (browser.view.window?.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            } else { checks["createRevealsFileAndStartsRename"] = false }
            let blank = browser.fileList.contextMenu(at: -1)
            checks["blankTerminalMenuCapturesDirectory"] = (blank?.items.first(where: { $0.title == "在终端中打开" })?.representedObject as? [URL]) == [root]
            let folderRow = browser.session.visibleItems.firstIndex(where: { $0.url == folder }) ?? 0
            let folderMenu = browser.fileList.contextMenu(at: folderRow)
            checks["folderTerminalMenuCapturesFolder"] = (folderMenu?.items.first(where: { $0.title == "在终端中打开" })?.representedObject as? [URL]) == [folder]
            checks.merge(editorMenus(browser, root: root, file: a, other: b, folder: folder)) { _, new in new }
            type("CAFE", browser); browser.navigate(to: folder); await browser.waitForNavigation()
            checks["navigationClearsFilterField"] = browser.filterBar.field.stringValue.isEmpty && browser.session.filterQuery.isEmpty
            browser.navigate(to: root); await browser.waitForNavigation()
            let sidebar = browser.sidebar
            sidebar.pin(folder); sidebar.pin(replacement)
            let menu = sidebar.contextMenu(for: folder, favoriteRoot: true)
            if let rename = menu.items.first(where: { $0.title == "编辑显示名称…" }) {
                _ = NSApplication.shared.sendAction(rename.action!, to: rename.target, from: rename)
                _ = await ReliabilityCheck.eventually { browser.view.window?.attachedSheet != nil }
                if let sheet = browser.view.window?.attachedSheet, let content = sheet.contentView {
                    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                    let fields = views(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
                    fields.first?.stringValue = "项目 👋"
                    views(content).compactMap { $0 as? NSButton }.first(where: { $0.title == "保存" })?.performClick(nil)
                    checks["favoriteAliasSheetSavesTitle"] = await ReliabilityCheck.eventually { sidebar.favoriteNames[folder.path] == "项目 👋" }
                } else { checks["favoriteAliasSheetSavesTitle"] = false }
            }
            checks["favoriteAliasDoesNotRenameDirectory"] = FileManager.default.fileExists(atPath: folder.path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent("项目 👋").path)
            let before = sidebar.favoritePaths.firstIndex(of: folder.path)
            if let up = sidebar.contextMenu(for: folder, favoriteRoot: true).items.first(where: { $0.title == "上移" }) {
                _ = NSApplication.shared.sendAction(up.action!, to: up.target, from: up)
                checks["favoriteMoveMenuChangesOrder"] = sidebar.favoritePaths.firstIndex(of: folder.path) == before.map { $0 - 1 }
            }
            try FileManager.default.removeItem(at: folder); sidebar.checkFavorites(); await sidebar.waitForAvailability()
            checks["missingFavoriteMarkedUnavailable"] = sidebar.unavailableFavorites.contains(folder)
            checks["unavailableFavoriteTerminalDisabled"] = sidebar.contextMenu(for: folder, favoriteRoot: true).items.first(where: { $0.title == "在终端中打开" })?.isEnabled == false
            sidebar.removeFavorite(replacement)
            checks["favoriteRelinkKeepsAlias"] = await sidebar.relinkFavorite(folder, to: replacement) && sidebar.favoriteNames[replacement.path] == "项目 👋"
            browser.capturePreferences(); await browser.preferences.flush()
            let reloaded = await PreferencesStore(url: browser.preferences.store.url).load()
            checks["favoriteEditsPersistAcrossFreshLoad"] = reloaded.preferences.favorites == sidebar.favoritePaths && reloaded.preferences.favoriteNames?[replacement.path] == "项目 👋"
            sidebar.removeFavorite(replacement)
            checks["removeFavoriteLeavesDirectory"] = FileManager.default.fileExists(atPath: replacement.path) && !sidebar.favoritePaths.contains(replacement.path)
        } catch { checks["dailyUseFixtureSucceeded"] = false; fputs("Daily use check: \(error)\n", stderr) }
        return checks
    }
    private static func editorMenus(_ browser: BrowserViewController, root: URL, file: URL, other: URL, folder: URL) -> [String: Bool] {
        let list = browser.fileList, sidebar = browser.sidebar
        let listCallback = list.onVSCode, listInstalled = list.hasVSCode
        let treeCallback = sidebar.onVSCode, treeInstalled = sidebar.hasVSCode
        defer { list.onVSCode = listCallback; list.hasVSCode = listInstalled; sidebar.onVSCode = treeCallback; sidebar.hasVSCode = treeInstalled }
        list.hasVSCode = { true }; sidebar.hasVSCode = { true }
        var captured: [URL] = [], treeCaptured: URL?
        list.onVSCode = { captured = $0 }; sidebar.onVSCode = { treeCaptured = $0 }
        func invoke(_ menu: NSMenu?) {
            captured = []
            if let item = menu?.items.first(where: { $0.title == "用 VS Code 打开" }), let action = item.action { _ = NSApplication.shared.sendAction(action, to: item.target, from: item) }
        }
        var result: [String: Bool] = [:]
        invoke(list.contextMenu(at: -1)); result["vscodeBlankScope"] = captured == [root]
        let rows = browser.session.visibleItems
        let fileRow = rows.firstIndex(where: { $0.url == file }) ?? -1
        let otherRow = rows.firstIndex(where: { $0.url == other }) ?? -1
        let folderRow = rows.firstIndex(where: { $0.url == folder }) ?? -1
        invoke(list.contextMenu(at: fileRow)); result["vscodeFileScope"] = captured == [file]
        invoke(list.contextMenu(at: folderRow)); result["vscodeFolderScope"] = captured == [folder]
        if fileRow >= 0, otherRow >= 0, let table = list.keyboardView as? NSTableView {
            table.selectRowIndexes(IndexSet([fileRow, otherRow]), byExtendingSelection: false)
            invoke(list.contextMenu(at: fileRow))
            result["vscodeMultiSelectionScope"] = Set(captured) == [file, other]
        } else { result["vscodeMultiSelectionScope"] = false }
        if let item = sidebar.contextMenu(for: folder, favoriteRoot: false).items.first(where: { $0.title == "用 VS Code 打开" }), let action = item.action { _ = NSApplication.shared.sendAction(action, to: item.target, from: item) }
        result["vscodeTreeScope"] = treeCaptured == folder
        list.hasVSCode = { false }; sidebar.hasVSCode = { false }
        result["vscodeAbsentClearlyDisabled"] = list.contextMenu(at: -1)?.items.first(where: { $0.title == "用 VS Code 打开（未安装）" })?.isEnabled == false && sidebar.contextMenu(for: folder, favoriteRoot: false).items.first(where: { $0.title == "用 VS Code 打开（未安装）" })?.isEnabled == false
        return result
    }
    private static func type(_ query: String, _ browser: BrowserViewController) {
        browser.focusFilter(nil)
        guard let editor = browser.filterBar.field.currentEditor() as? NSTextView else { return }
        editor.insertText(query, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }
}
