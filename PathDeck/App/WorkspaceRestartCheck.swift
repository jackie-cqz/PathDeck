import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor enum WorkspaceRestartCheck {
    static func prepare(app: AppDelegate, root: URL) async -> [String: Bool] {
        guard let first = app.mainWindowController else { return ["producerWindow": false] }
        do {
            try Data("PathDeck workspace QA".utf8).write(to: root.appendingPathComponent(".workspace-qa"))
            let a = root.appendingPathComponent("中文 Folder", isDirectory: true), b = root.appendingPathComponent("Empty", isDirectory: true), c = root.appendingPathComponent("Session C", isDirectory: true)
            try Data("saved B".utf8).write(to: b.appendingPathComponent("saved.txt"))
            try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
            for name in ["keep.session.txt", "replace.session.txt"] { try Data("saved C".utf8).write(to: c.appendingPathComponent(name)) }
            first.browser.navigate(to: a); await first.browser.waitForNavigation()
            first.browser.session.setFilter("hello")
            select(first.browser, names: ["hello.txt"])
            guard let tab = app.makeWindow(at: b, tabOf: first), let other = app.makeWindow(at: c) else { return ["producerPages": false] }
            await tab.browser.waitForNavigation(); await other.browser.waitForNavigation()
            select(tab.browser, names: ["saved.txt"])
            let d = root.appendingPathComponent("Third tab", isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            guard let third = app.makeWindow(at: d, tabOf: tab) else { return ["producerThirdTab": false] }
            await third.browser.waitForNavigation()
            other.browser.toggleHidden(nil); await other.browser.waitForNavigation()
            other.browser.session.setFilter("session"); select(other.browser, names: ["keep.session.txt", "replace.session.txt"])
            first.window?.tabGroup?.selectedWindow = first.window
            other.window?.makeKeyAndOrderFront(nil); other.window?.makeMain()
            await app.saveWorkspace()
            let snapshot = WorkspaceController.capture(app.windowControllers, active: other)
            return ["producerTwoGroups": snapshot.groups.count == 2, "producerFourPages": snapshot.groups.flatMap(\.pages).count == 4,
                "producerThreeTabOrder": snapshot.groups.first?.pages.map(\.directory) == [a.path, b.path, d.path],
                "producerActiveGroup": snapshot.activeGroup == 1, "producerSelectedItems": snapshot.groups.flatMap(\.pages).map(\.selection.count).sorted() == [0, 1, 1, 2]]
        } catch { return ["producerFixture": false] }
    }
    static func verify(app: AppDelegate, saved: WorkspaceSnapshot?) -> [String: Bool] {
        guard let saved else { return ["consumerReadSavedWorkspace": false] }
        let actual = WorkspaceController.capture(app.windowControllers, active: app.mainWindowController)
        var checks: [String: Bool] = ["consumerTwoGroups": actual.groups.count == saved.groups.count,
            "consumerAllPages": actual.groups.flatMap(\.pages).count == saved.groups.flatMap(\.pages).count,
            "consumerActiveGroup": actual.activeGroup == saved.activeGroup,
            "consumerPageOrder": actual.groups.map { $0.pages.map(\.directory) } == saved.groups.map { $0.pages.map(\.directory) },
            "consumerSelectedTabs": actual.groups.map(\.selectedIndex) == saved.groups.map(\.selectedIndex)]
        var selectionCorrect = true, fieldsCorrect = true, missingKept = false, replacementSkipped = false, renamedSelected = false
        for state in saved.groups.flatMap(\.pages) {
            guard let page = app.windowControllers.first(where: { $0.browser.session.currentDirectory.path == state.directory })?.browser else { fieldsCorrect = false; continue }
            if case .failed = page.session.contentState { missingKept = page.pageSnapshot().directory == state.directory; continue }
            let available = Set(page.session.items.compactMap(\.identity)), expected = Set(state.selection.compactMap(\.identity)).intersection(available)
            selectionCorrect = selectionCorrect && Set(page.fileList.selectedReferences.compactMap(\.identity)) == expected
            fieldsCorrect = fieldsCorrect && page.session.filterQuery == state.filter && page.session.sort == state.sort && page.session.showHidden == state.showHidden && page.fileList.columnPreferences().map(\.id) == state.columns.map(\.id)
            if state.directory.hasSuffix("Session C") { replacementSkipped = page.fileList.selectedReferences.count == 1 && page.fileList.selectedReferences.first?.url.lastPathComponent == "keep.session.txt" }
            if state.directory.hasSuffix("中文 Folder") { renamedSelected = page.fileList.selectedReferences.first?.url.lastPathComponent == "hello-renamed.txt" }
        }
        checks["consumerIdentitySelection"] = selectionCorrect; checks["consumerPerPageSettings"] = fieldsCorrect
        checks["consumerUnavailablePagePreserved"] = missingKept; checks["consumerReplacementNotSelected"] = replacementSkipped; checks["consumerRenamedObjectSelected"] = renamedSelected
        return checks
    }
    static func select(_ browser: BrowserViewController, names: Set<String>) {
        (browser.fileList.keyboardView as? NSTableView)?.selectRowIndexes(IndexSet(browser.session.visibleItems.indices.filter { names.contains(browser.session.visibleItems[$0].realName) }), byExtendingSelection: false)
    }
}
