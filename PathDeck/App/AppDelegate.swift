import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private(set) var windowControllers: [MainWindowController] = []
    private weak var lastActive: MainWindowController?
    private var closedWindow: MainWindowController?
    private lazy var actionContext = FileActionContext()
    var mainWindowController: MainWindowController? {
        windowControllers.first { $0.window === NSApp.mainWindow } ?? windowControllers.first { $0.window === NSApp.keyWindow } ?? lastActive ?? windowControllers.last
    }
    private var smokeFixture: URL?
    private var preferences: PreferencesController?
    private var workspaceTimer: Timer?
    private var isRestoringWorkspace = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        AppMenu.install(commandTarget: self)
        Task { [weak self] in
            guard let self else { return }
            if RuntimeContext.isTesting {
                do { self.smokeFixture = try ApplicationSmokeCheck.makeFixture() }
                catch { print("Cannot prepare test fixture: \(error)"); exit(1) }
            }
            let url = RuntimeContext.testPreferencesURL ?? self.smokeFixture?.appendingPathComponent(".settings/preferences.json") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PathDeck/preferences.json")
            let preferences = PreferencesController(store: PreferencesStore(url: url))
            await preferences.load(migrateLegacy: !RuntimeContext.isTesting)
            self.preferences = preferences
            let startupWorkspace = preferences.value.workspace
            if let workspace = startupWorkspace, !workspace.groups.isEmpty {
                _ = await self.restoreWorkspace(workspace)
            } else { self.showMainWindow() }
            self.workspaceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.captureWorkspace() } }
            NSApplication.shared.activate()
            if CommandLine.arguments.contains("--workspace-save-test"), let root = self.smokeFixture {
                let checks = await WorkspaceRestartCheck.prepare(app: self, root: root)
                let passed = checks.values.allSatisfy { $0 }
                if let data = try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "fixture": root.path], options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                fflush(stdout); exit(passed ? 0 : 1)
            }
            if CommandLine.arguments.contains("--workspace-load-test") {
                let checks = WorkspaceRestartCheck.verify(app: self, saved: startupWorkspace)
                let passed = checks.values.allSatisfy { $0 }
                if let data = try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks], options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                await self.saveWorkspace(); if let root = self.smokeFixture { try? FileManager.default.removeItem(at: root) }
                fflush(stdout); exit(passed ? 0 : 1)
            }
            if CommandLine.arguments.contains("--smoke-test") {
                guard let window = self.mainWindowController?.window, let fixture = self.smokeFixture else {
                    print("PathDeck smoke test: missing window")
                    exit(1)
                }
                await ApplicationSmokeCheck.run(window: window, fixture: fixture) { self.showMainWindow() }
            }
            if CommandLine.arguments.contains("--performance-test"), let window = self.mainWindowController?.window, let fixture = self.smokeFixture {
                await PerformanceCheck.run(window: window, fixture: fixture)
            }
            if CommandLine.arguments.contains("--terminal-test"), let browser = self.browser, let fixture = self.smokeFixture {
                await TerminalCheck.run(browser: browser, fixture: fixture)
            }
            if CommandLine.arguments.contains("--continuity-test"), let browser = self.browser, let fixture = self.smokeFixture {
                await browser.waitForNavigation()
                let checks = await ContinuityCheck.run(browser: browser, fixture: fixture)
                let passed = checks.values.allSatisfy { $0 }
                if let data = try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks], options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                browser.stopMonitoring(); await preferences.flush(); try? FileManager.default.removeItem(at: fixture)
                fflush(stdout); exit(passed ? 0 : 1)
            }
            if CommandLine.arguments.contains("--drag-test"), let browser = self.browser, let fixture = self.smokeFixture {
                await browser.waitForNavigation()
                let checks = await DragDropCheck.run(browser: browser, fixture: fixture)
                let passed = checks.values.allSatisfy { $0 }
                if let data = try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks], options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                browser.stopMonitoring(); await preferences.flush(); try? FileManager.default.removeItem(at: fixture)
                fflush(stdout); exit(passed ? 0 : 1)
            }
            if CommandLine.arguments.contains("--interaction-test"), let browser = self.browser, let fixture = self.smokeFixture {
                await browser.waitForNavigation()
                let checks = await InteractionCheck.run(browser: browser, fixture: fixture)
                let passed = checks.values.allSatisfy { $0 }
                if let data = try? JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks], options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                browser.stopMonitoring(); await preferences.flush(); try? FileManager.default.removeItem(at: fixture)
                fflush(stdout); exit(passed ? 0 : 1)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // A normal Mac app remains available in the Dock after its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var browser: BrowserViewController? { mainWindowController?.browser }
    func applicationDidBecomeActive(_ notification: Notification) { browser?.applicationActivated() }
    @objc func undo(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            // NSTextView exposes its undo manager, not a public undo: action.
            // Sending undo: through that responder can route back to this delegate.
            if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
        }
        else { browser?.undo(sender) }
    }
    @objc func editLocation(_ sender: Any?) { browser?.editLocation(sender) }
    @objc func focusFilter(_ sender: Any?) { browser?.focusFilter(sender) }
    @objc func openCurrentTerminal(_ sender: Any?) { browser?.openCurrentTerminal(sender) }
    @objc func goBack(_ sender: Any?) { browser?.goBack(sender) }
    @objc func goForward(_ sender: Any?) { browser?.goForward(sender) }
    @objc func goUp(_ sender: Any?) { browser?.goUp(sender) }
    @objc func refreshDirectory(_ sender: Any?) { browser?.refreshDirectory(sender) }
    @objc func toggleHidden(_ sender: Any?) { browser?.toggleHidden(sender) }
    @objc func newFolder(_ sender: Any?) { browser?.newFolder(sender) }
    @objc func newTextFile(_ sender: Any?) { browser?.newTextFile(sender) }
    @objc func renameSelection(_ sender: Any?) { browser?.renameSelection(sender) }
    @objc func trashSelection(_ sender: Any?) { browser?.trashSelection(sender) }
    @objc func showFileTasks(_ sender: Any?) { actionContext.panel.update(); actionContext.panel.showWindow(sender); actionContext.panel.window?.makeKeyAndOrderFront(sender) }
    @objc func clearRecentDirectories(_ sender: Any?) { browser?.clearRecentDirectories(sender) }
    @objc private func goRecent(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { browser?.navigate(to: URL(fileURLWithPath: path, isDirectory: true)) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "最近目录" else { return }
        menu.removeAllItems()
        for path in preferences?.value.recentDirectories ?? [] {
            let item = menu.addItem(withTitle: path, action: #selector(goRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = path
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "清除历史记录", action: #selector(clearRecentDirectories(_:)), keyEquivalent: "").target = self
    }
    @objc func toggleKeyboardStyle(_ sender: Any?) {
        guard let browser else { return }; let enabled = !browser.fileList.windowsFriendly
        for controller in windowControllers { controller.browser.fileList.windowsFriendly = enabled }
        preferences?.value.windowsFriendly = enabled; preferences?.changed()
    }
    @objc func toggleCompactList(_ sender: Any?) {
        guard let preferences else { return }; let enabled = !(preferences.value.compactList ?? false)
        preferences.value.compactList = enabled
        for controller in windowControllers { controller.browser.fileList.compact = enabled }
        preferences.changed()
    }
    @objc func previewSelection(_ sender: Any?) { browser?.previewSelection(sender) }
    @objc func propertiesSelection(_ sender: Any?) { browser?.propertiesSelection(sender) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard actionContext.isBusy else { return flushBeforeQuit(sender) }
        let alert = NSAlert(); alert.messageText = "还有文件任务未完成"
        alert.informativeText = "可以等待任务完成，或请求取消后退出。当前正在执行的系统操作可能需要先结束。"
        alert.addButton(withTitle: "等待完成后退出"); alert.addButton(withTitle: "取消任务后退出"); alert.addButton(withTitle: "返回")
        let choice = alert.runModal()
        if choice == .alertThirdButtonReturn { return .terminateCancel }
        if !actionContext.isBusy { return flushBeforeQuit(sender) }
        actionContext.onIdle = { [weak self] in self?.actionContext.onIdle = nil; _ = self?.flushBeforeQuit(sender) }
        if choice == .alertSecondButtonReturn { actionContext.cancelAll() }
        return .terminateLater
    }
    private func flushBeforeQuit(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { [weak self] in
            if let self, let browser = self.browser { self.preferences?.value.remember(browser.session.currentDirectory) }
            self?.mainWindowController?.captureWindow()
            self?.captureWorkspace()
            await self?.preferences?.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)), let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            item.title = editor.undoManager?.undoMenuItemTitle ?? "撤销"; return editor.undoManager?.canUndo == true
        }
        if item.action == #selector(newWindow(_:)) || item.action == #selector(showMainWindow(_:)) { return preferences != nil }
        if item.action == #selector(showFileTasks(_:)) { return true }
        if item.action == #selector(toggleCompactList(_:)) { item.state = preferences?.value.compactList == true ? .on : .off; return browser != nil }
        if item.action == #selector(nextTab(_:)) || item.action == #selector(previousTab(_:)) || item.action == #selector(detachTab(_:)) { return (mainWindowController?.window?.tabbedWindows?.count ?? 1) > 1 }
        return browser?.validateMenuItem(item) ?? false
    }

    @objc func showMainWindow(_ sender: Any? = nil) {
        guard let preferences else { return }
        if windowControllers.isEmpty {
            if let closed = closedWindow {
                closedWindow = nil; windowControllers.append(closed); lastActive = closed
            } else {
                let saved = preferences.value.lastDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                _ = makeWindow(at: smokeFixture ?? saved ?? FileManager.default.homeDirectoryForCurrentUser)
            }
        }
        mainWindowController?.showWindow(sender)
        mainWindowController?.window?.makeKeyAndOrderFront(sender)
        mainWindowController?.window?.makeMain()
        browser?.resumeMonitoring()
        captureWorkspace()
    }

    @discardableResult func makeWindow(at url: URL, tabOf origin: MainWindowController? = nil, pageState: BrowserPageSnapshot? = nil) -> MainWindowController? {
        guard let preferences else { return nil }
        let session = BrowserSession(initialDirectory: url)
        session.sort = preferences.value.sort; session.showHidden = preferences.value.showHidden
        let controller = MainWindowController(session: session, preferences: preferences, actionContext: actionContext, pageState: pageState)
        windowControllers.append(controller)
        controller.onActivate = { [weak self, weak controller] in
            guard let self, let controller else { return }; self.lastActive = controller
            if controller.browser.session.contentState == .loaded { self.preferences?.value.remember(controller.browser.session.currentDirectory); self.preferences?.changed() }
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
            if self.lastActive === controller { self.lastActive = self.windowControllers.last }
            if self.windowControllers.isEmpty { self.closedWindow = controller }
            self.captureWorkspace()
        }
        controller.onNewTab = { [weak self, weak controller] in
            guard let controller else { return }; _ = self?.makeWindow(at: controller.browser.session.currentDirectory, tabOf: controller)
        }
        controller.browser.onOpenPage = { [weak self, weak controller] url, tab in _ = self?.makeWindow(at: url, tabOf: tab ? controller : nil) }
        controller.browser.onFavoritesChanged = { [weak self] in
            guard let self, let preferences = self.preferences else { return }
            for page in self.windowControllers { page.browser.sidebar.applyFavorites(paths: preferences.value.favorites ?? [], names: preferences.value.favoriteNames ?? [:]) }
        }
        controller.browser.onWindowCommand = { [weak self, weak controller] command in
            guard let self, let controller else { return }
            switch command {
            case .newWindow: _ = self.makeWindow(at: controller.browser.session.currentDirectory)
            case .newTab: _ = self.makeWindow(at: controller.browser.session.currentDirectory, tabOf: controller)
            case .closeTab: controller.window?.performClose(nil)
            case .nextTab: controller.window?.selectNextTab(nil)
            case .previousTab: controller.window?.selectPreviousTab(nil)
            default: break
            }
        }
        if let origin, let window = controller.window { origin.window?.addTabbedWindow(window, ordered: .above) }
        else if let previous = windowControllers.dropLast().last?.window {
            _ = controller.window?.cascadeTopLeft(from: NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeMain()
        lastActive = controller
        return controller
    }
    func captureWorkspace() {
        guard !isRestoringWorkspace, let preferences else { return }
        let snapshot = WorkspaceController.capture(windowControllers, active: mainWindowController)
        if preferences.value.workspace != snapshot { preferences.value.workspace = snapshot; preferences.changed() }
    }
    func saveWorkspace() async { captureWorkspace(); await preferences?.flush() }
    @discardableResult func restoreWorkspace(_ source: WorkspaceSnapshot) async -> [MainWindowController] {
        guard let snapshot = source.sanitized() else { return [] }
        isRestoringWorkspace = true
        defer { isRestoringWorkspace = false; captureWorkspace() }
        var all: [MainWindowController] = [], selected: [MainWindowController] = []
        for group in snapshot.groups {
            var pages: [MainWindowController] = []
            for state in group.pages {
                if let controller = makeWindow(at: URL(fileURLWithPath: state.directory, isDirectory: true), tabOf: pages.last, pageState: state) { pages.append(controller); all.append(controller) }
            }
            for page in pages { await page.browser.waitForNavigation() }
            if let page = pages.indices.contains(group.selectedIndex) ? pages[group.selectedIndex] : pages.first {
                if let frame = group.frame { page.applyPlacement(frame) }
                page.window?.tabGroup?.selectedWindow = page.window; selected.append(page)
            }
        }
        if selected.indices.contains(snapshot.activeGroup), let window = selected[snapshot.activeGroup].window { window.makeKeyAndOrderFront(nil); window.makeMain(); lastActive = selected[snapshot.activeGroup] }
        return all
    }
    func applicationWillTerminate(_ notification: Notification) { workspaceTimer?.invalidate() }
    @objc func newWindow(_ sender: Any?) { _ = makeWindow(at: browser?.session.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser) }
    @objc func newTab(_ sender: Any?) { _ = makeWindow(at: browser?.session.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser, tabOf: mainWindowController) }
    @objc func nextTab(_ sender: Any?) { mainWindowController?.window?.selectNextTab(sender) }
    @objc func previousTab(_ sender: Any?) { mainWindowController?.window?.selectPreviousTab(sender) }
    @objc func detachTab(_ sender: Any?) { mainWindowController?.window?.moveTabToNewWindow(sender) }
}

