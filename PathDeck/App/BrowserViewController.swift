import AppKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class BrowserBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class BrowserViewController: NSViewController, NSMenuItemValidation {
    let session: BrowserSession
    let coordinator: NavigationCoordinator
    let sidebar: SidebarViewController
    let fileList = FileListViewController()
    let filterBar = DirectoryFilterBar(frame: .zero)
    let terminal = TerminalService()
    let vscode = VSCodeService()
    let addressBar: AddressBarView
    private let status = NSTextField(labelWithString: "目录尚未读取")
    private var initialLoad = false
    private var navigationTask: Task<Void, Never>?
    private var navigationStamp = 0
    private var explicitNavigationPending = false
    var isNavigating: Bool { explicitNavigationPending || session.isLoading }
    private var lastSidebarURL: URL?
    private let inspector = DirectoryReader()
    let actionContext: FileActionContext
    lazy var actions = FileActionController(browser: self, context: actionContext)
    lazy var drops = FileDropController(actions: actions)
    private var fileDragging = false
    lazy var preview: FilePreviewController = { let value = FilePreviewController(); value.owner = self; return value }()
    private(set) var propertyWindows: [FilePropertiesWindowController] = []
    var onWindowCommand: ((BrowserShortcut) -> Void)?
    var onOpenPage: ((URL, Bool) -> Void)?
    var onFavoritesChanged: (() -> Void)?
    private var needsWriteRefresh = false
    let preferences: PreferencesController
    private let split = NSSplitViewController()
    private let monitor = DirectoryMonitor()
    private var monitoring = false
    private var monitorUpdateTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var pendingBackgroundRefresh = false
    private var pendingRelocation: URL?
    private var fallbackAttempted = false
    private var statusNotice = ""
    private var renderedDirectory: URL?
    private var loadingIndicatorTask: Task<Void, Never>?
    private let tasksButton = KeyboardButton(title: "文件任务", target: nil, action: nil)
    private var loadingVisible = false
    private var restoreListFocusAfterLoad = false
    private let initialSidebarWidth: Double
    private var pendingPageState: BrowserPageSnapshot?
    private let keepsUnavailablePage: Bool

    init(session: BrowserSession, preferences: PreferencesController, actionContext: FileActionContext? = nil, pageState: BrowserPageSnapshot? = nil) {
        self.session = session
        self.preferences = preferences
        self.actionContext = actionContext ?? FileActionContext()
        pendingPageState = pageState; keepsUnavailablePage = pageState != nil
        initialSidebarWidth = pageState?.sidebarWidth ?? preferences.value.sidebarWidth
        if let pageState { session.sort = pageState.sort; session.showHidden = pageState.showHidden }
        coordinator = NavigationCoordinator(session: session)
        addressBar = AddressBarView(directory: session.currentDirectory)
        sidebar = SidebarViewController(preferences: preferences.value)
        statusNotice = preferences.notice ?? ""
        super.init(nibName: nil, bundle: nil)
        session.onChange = { [weak self] in self?.render() }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(session:)") }

    override func loadView() {
        view = BrowserBackground()
        split.splitView.isVertical = true
        sidebar.preferredContentSize = NSSize(width: 240, height: 0)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180; sidebarItem.maximumThickness = 360; sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(NSSplitViewItem(viewController: fileList)); addChild(split)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle; status.setAccessibilityIdentifier("PathDeck.Status")
        let separator = NSBox(); separator.boxType = .separator
        let tasks = tasksButton; tasks.target = self; tasks.action = #selector(showFileTasks(_:))
        tasks.bezelStyle = .inline
        tasks.setAccessibilityLabel("文件任务"); tasks.setAccessibilityHelp("查看任务进度、失败详情并取消任务。")
        status.setAccessibilityLabel("当前位置与操作状态")
        for subview in [addressBar, filterBar, split.view, separator, status, tasks] { subview.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(subview) }
        NSLayoutConstraint.activate([
            addressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), addressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addressBar.topAnchor.constraint(equalTo: view.topAnchor), addressBar.heightAnchor.constraint(equalToConstant: 58),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor), filterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: addressBar.bottomAnchor), filterBar.heightAnchor.constraint(equalToConstant: 48),
            split.view.topAnchor.constraint(equalTo: filterBar.bottomAnchor), split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), split.view.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor), separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), status.trailingAnchor.constraint(equalTo: tasks.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: view.bottomAnchor, constant: -15),
            tasks.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), tasks.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
        addressBar.onSubmit = { [weak self] input in self?.navigate(input: input) }
        addressBar.onNavigate = { [weak self] in self?.navigate(to: $0) }
        addressBar.onBack = { [weak self] in self?.goBack(nil) }; addressBar.onForward = { [weak self] in self?.goForward(nil) }
        addressBar.onUp = { [weak self] in self?.goUp(nil) }; addressBar.onRefresh = { [weak self] in self?.refreshDirectory(nil) }
        sidebar.onNavigate = { [weak self] in self?.navigate(to: $0) }
        sidebar.onCopyPath = { [weak self] in self?.copyPaths([$0]) }; sidebar.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        sidebar.onTerminal = { [weak self] in self?.openTerminal(at: $0) }
        sidebar.onVSCode = { [weak self] in self?.openInVSCode([$0]) }
        sidebar.hasVSCode = { [weak self] in self?.vscode.applicationURL != nil }
        sidebar.onFailure = { [weak self] in self?.showFailure($0) }
        filterBar.onChange = { [weak self] in self?.session.setFilter($0) }
        filterBar.onExit = { [weak self] in self?.fileList.focus() }
        fileList.onOpen = { [weak self] in self?.open($0) }
        fileList.onBack = { [weak self] in self?.goBack(nil) }; fileList.onRefresh = { [weak self] in self?.refreshDirectory(nil) }
        fileList.onCopyPaths = { [weak self] in self?.copyPaths($0) }; fileList.onReveal = { NSWorkspace.shared.activateFileViewerSelecting($0) }
        fileList.onPin = { [weak self] in self?.sidebar.pin($0) }
        fileList.onOpenWith = { [weak self] in self?.openWith($0) }
        fileList.onTerminal = { [weak self] in self?.openTerminal(at: $0) }
        fileList.onVSCode = { [weak self] in self?.openInVSCode($0) }
        fileList.hasVSCode = { [weak self] in self?.vscode.applicationURL != nil }
        fileList.onSelection = { [weak self] selected, anchor in
            guard let self else { return }; self.session.selection = selected; self.session.scrollAnchor = anchor; self.updateStatus()
            self.preview.setSelection(self.fileList.selectedReferences.map(\.url))
        }
        fileList.onShortcut = { [weak self] in self?.handleShortcut($0) }
        fileList.onPreview = { [weak self] in self?.preview.toggle($0) }
        fileList.onProperties = { [weak self] in self?.showProperties($0) }
        fileList.onOpenPage = { [weak self] in self?.onOpenPage?($0, $1) }
        sidebar.onOpenPage = { [weak self] in self?.onOpenPage?($0, $1) }
        sidebar.onProperties = { [weak self] in self?.showProperties([$0]) }
        fileList.onSort = { [weak self] in self?.session.changeSort($0) }
        fileList.onWriteCopy = { [weak self] in self?.actions.copy($0, cut: $1) }
        fileList.drops = drops; sidebar.drops = drops
        for state in [fileList.fileDragState, sidebar.fileDragState] {
            state.onActivity = { [weak self] active in self?.fileDragging = active; if !active { self?.resumePendingRefresh() } }
        }
        fileList.onWritePaste = { [weak self] destination in Task { _ = await self?.actions.paste(destination: destination) } }
        fileList.onWriteCreate = { [weak self] in _ = self?.actions.create($0, destination: $1) }
        fileList.onWriteRename = { [weak self] in self?.actions.beginRename($0) }
        fileList.onCommitRename = { [weak self] in _ = self?.actions.rename($0, to: $1) }
        fileList.onWriteTrash = { [weak self] refs in Task { _ = await self?.actions.trash(refs) } }
        fileList.hasClipboardFiles = { [weak self] in self?.actions.clipboard.hasFileURLs ?? false }
        actions.onStatusChange = { [weak self] in self?.updateStatus() }
        actions.clipboardChanged()
        fileList.windowsFriendly = preferences.value.windowsFriendly
        fileList.compact = preferences.value.compactList ?? false
        fileList.restoreColumns(pendingPageState?.columns ?? preferences.value.columns)
        fileList.onColumnsChanged = { [weak self] in self?.capturePreferences() }
        fileList.onViewportChanged = { [weak self] in self?.updateMonitoring() }
        fileList.onEditingEnded = { [weak self] in self?.resumePendingRefresh() }
        sidebar.onStateChange = { [weak self] in self?.capturePreferences(); self?.updateMonitoring() }
        sidebar.onFavoritesChange = { [weak self] in
            guard let self else { return }
            self.preferences.value.favorites = self.sidebar.favoritePaths; self.preferences.value.favoriteNames = self.sidebar.favoriteNames
            self.preferences.changed(); self.onFavoritesChanged?()
        }
        sidebar.loadViewIfNeeded()
        if preferences.value.favorites == nil { preferences.value.favorites = sidebar.favoritePaths; preferences.value.favoriteNames = sidebar.favoriteNames; preferences.changed() }
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)), name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged(_:)), name: name, object: nil)
        }
        connectKeyLoop()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        if !initialLoad {
            view.layoutSubtreeIfNeeded()
            split.splitView.setPosition(initialSidebarWidth, ofDividerAt: 0)
            initialLoad = true
            navigate(to: session.currentDirectory)
        }
        connectKeyLoop()
        resumeMonitoring()
    }
    private func connectKeyLoop() {
        addressBar.connectKeyLoop(sidebar: sidebar.keyboardView, list: fileList.keyboardView, tasks: tasksButton)
        sidebar.keyboardView.nextKeyView = filterBar.field; filterBar.field.nextKeyView = fileList.keyboardView
    }
    func navigate(input: String) {
        fileList.cancelRename()
        session.scrollAnchor = fileList.viewportAnchor
        runNavigation { await $0.navigate(input: input) }
    }
    func navigate(to url: URL) {
        fileList.cancelRename()
        session.scrollAnchor = fileList.viewportAnchor
        runNavigation { await $0.navigate(to: url) }
    }
    private func runNavigation(restoreFocus: Bool = true, operation: @escaping @MainActor (NavigationCoordinator) async -> Bool) {
        navigationTask?.cancel(); backgroundTask?.cancel(); pendingBackgroundRefresh = false
        navigationStamp += 1; let stamp = navigationStamp; explicitNavigationPending = true
        navigationTask = Task { [weak self] in
            guard let self else { return }
            let completed = await operation(self.coordinator)
            guard self.navigationStamp == stamp else { return }
            self.explicitNavigationPending = false
            if completed, restoreFocus, !self.addressBar.isEditing, !self.fileList.isRenaming { self.fileList.focus() }
            self.resumePendingRefresh()
        }
    }
    func waitForNavigation() async {
        repeat {
            await navigationTask?.value
            await backgroundTask?.value
            if !explicitNavigationPending, !session.isLoading, backgroundTask == nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        } while !Task.isCancelled
    }
    func refreshAfterOperation(_ record: FileOperationRecord) async {
        // Refresh only the currently displayed location; never navigate back to
        // an operation's source/target after the user has browsed elsewhere.
        if explicitNavigationPending || session.isLoading || fileList.isRenaming || fileDragging { needsWriteRefresh = true; return }
        navigationStamp += 1; let stamp = navigationStamp; explicitNavigationPending = true
        defer { if navigationStamp == stamp { explicitNavigationPending = false; resumePendingRefresh() } }
        session.scrollAnchor = fileList.viewportAnchor
        _ = await coordinator.refresh()
        lastSidebarURL = nil
        sidebar.refreshDirectories([session.currentDirectory])
        sidebar.synchronize(to: session.currentDirectory, showHidden: session.showHidden)
    }
    func waitForSidebar() async { await sidebar.waitForSynchronization() }
    var sidebarDirectory: URL? { sidebar.selectedDirectory }
    private func render() {
        guard isViewLoaded else { return }
        if session.isLoading, view.window?.firstResponder === fileList.keyboardView { restoreListFocusAfterLoad = true }
        fileList.display(session)
        filterBar.display(session.filterQuery)
        filterBar.directory = session.currentDirectory
        if preview.controlsPanel { preview.setSelection(fileList.selectedReferences.map(\.url)) }
        addressBar.showHidden = session.showHidden
        switch session.contentState {
        case .loaded:
            if let saved = pendingPageState { pendingPageState = nil; session.restoreViewState(saved) }
            if restoreListFocusAfterLoad, view.window?.firstResponder is NSWindow, !addressBar.isEditing, !fileList.isRenaming { fileList.focus() }
            restoreListFocusAfterLoad = false
            loadingVisible = false
            loadingIndicatorTask?.cancel()
            addressBar.update(directory: session.currentDirectory, canBack: session.canGoBack, canForward: session.canGoForward, preserveDraft: true)
            if renderedDirectory?.path != session.currentDirectory.path { preferences.value.remember(session.currentDirectory) }
            renderedDirectory = session.currentDirectory
            if lastSidebarURL != session.currentDirectory { lastSidebarURL = session.currentDirectory; sidebar.synchronize(to: session.currentDirectory, showHidden: session.showHidden) }
            view.window?.representedURL = session.currentDirectory
            let title = session.currentDirectory.path == "/" ? "/" : session.currentDirectory.lastPathComponent
            view.window?.title = "\(title) — PathDeck"; view.window?.tab.title = title; view.window?.tab.toolTip = session.currentDirectory.path
            capturePreferences(); updateMonitoring(immediate: true)
        case .failed(let error):
            restoreListFocusAfterLoad = false
            loadingVisible = false
            loadingIndicatorTask?.cancel(); addressBar.showError(error)
            if keepsUnavailablePage, renderedDirectory == nil {
                view.window?.title = "\(session.currentDirectory.lastPathComponent)（不可用）— PathDeck"; view.window?.tab.title = session.currentDirectory.lastPathComponent + "（不可用）"
            }
            if !keepsUnavailablePage && renderedDirectory == nil && !fallbackAttempted && preferences.value.lastDirectory != nil {
                fallbackAttempted = true; statusNotice = "上次的位置不可用，已返回个人文件夹。"
                Task { [weak self] in self?.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
            }
        case .loading:
            loadingVisible = false
            loadingIndicatorTask?.cancel()
            loadingIndicatorTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return }; self?.loadingVisible = true; self?.updateStatus() }
        default: break
        }
        updateStatus()
    }
    private func updateStatus() {
        switch session.contentState {
        case .notLoaded: status.stringValue = "目录尚未读取"
        case .loading(let target):
            guard loadingVisible else { return }; status.stringValue = "正在前往 \(target.path)…"
        case .failed(let error): status.stringValue = "\(error) · 保留位置：\(session.currentDirectory.path)"
        case .loaded:
            let count = session.filterQuery.isEmpty ? "\(session.items.count) 个项目" : "匹配 \(session.visibleItems.count) / \(session.items.count) 个项目"
            status.stringValue = "\(count) · 已选择 \(session.selection.count) 项 · \(session.currentDirectory.path)"
        }
        status.toolTip = status.stringValue
        if !actions.summary.isEmpty { status.stringValue += " · " + actions.summary }
        if !statusNotice.isEmpty { status.stringValue += " · " + statusNotice }
    }
    private func open(_ item: FileItem) {
        if item.kind == .directory { navigate(to: item.url); return }
        if item.kind == .symbolicLink {
            Task { [weak self] in
                guard let self else { return }
                do {
                    if try await self.inspector.isBrowsableDirectory(item.url) { self.navigate(to: item.url) }
                    else { self.openFile(item.url) }
                } catch { self.showFailure(error.localizedDescription) }
            }
            return
        }
        openFile(item.url)
    }
    private func openFile(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.showFailure(error.localizedDescription) } }
        }
    }
    private func openWith(_ url: URL) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.message = "选择用于打开文件的应用"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.showFailure(error.localizedDescription) } }
            }
        }
    }
    private func showFailure(_ text: String) {
        guard let window = view.window else { return }; let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = text; alert.beginSheetModal(for: window)
    }
    private func copyPaths(_ urls: [URL]) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
    @objc func editLocation(_ sender: Any?) { addressBar.beginEditing() }
    @objc func undo(_ sender: Any?) { guard !(view.window?.firstResponder is NSTextView) else { return }; _ = actionContext.undo(owner: actions) }
    @objc func previewSelection(_ sender: Any?) { preview.toggle(fileList.selectedReferences.map(\.url)) }
    @objc func propertiesSelection(_ sender: Any?) { showProperties(fileList.selectedReferences.isEmpty ? [session.currentDirectory] : fileList.selectedReferences.map(\.url)) }
    func showProperties(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = FilePropertiesWindowController(urls: urls)
        propertyWindows.append(controller)
        controller.onClose = { [weak self, weak controller] in self?.propertyWindows.removeAll { $0 === controller } }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func handleShortcut(_ action: BrowserShortcut) {
        switch action {
        case .copy, .cut, .paste, .selectAll, .open, .rename, .trash: fileList.performShortcut(action)
        case .back: goBack(nil)
        case .forward: goForward(nil)
        case .up: goUp(nil)
        case .refresh: refreshDirectory(nil)
        case .newFolder: newFolder(nil)
        case .filter: focusFilter(nil)
        case .preview: previewSelection(nil)
        case .properties: propertiesSelection(nil)
        case .blockedDelete: NSSound.beep()
        case .undo: undo(nil)
        default: onWindowCommand?(action)
        }
    }
    func closeAuxiliaryWindows() {
        preview.dismiss(restoreFocus: false)
        for controller in Array(propertyWindows) { controller.window?.close() }
        propertyWindows.removeAll()
    }
    @objc func focusFilter(_ sender: Any?) { fileList.cancelRename(); filterBar.focus() }
    @objc func openCurrentTerminal(_ sender: Any?) { openTerminal(at: session.currentDirectory) }
    private func openTerminal(at directory: URL) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.terminal.open(directory: directory) } catch { self.showFailure(error.localizedDescription) }
        }
    }
    private func openInVSCode(_ urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.vscode.open(urls) } catch { self.showFailure(error.localizedDescription) }
        }
    }
    @objc func goBack(_ sender: Any?) { runNavigation { await $0.back() } }
    @objc func goForward(_ sender: Any?) { runNavigation { await $0.forward() } }
    @objc func goUp(_ sender: Any?) { navigate(to: session.currentDirectory.deletingLastPathComponent()) }
    @objc func refreshDirectory(_ sender: Any?) {
        let restoreList = view.window?.firstResponder === fileList.keyboardView
        runNavigation(restoreFocus: restoreList) { await $0.refresh() }
    }
    @objc func toggleHidden(_ sender: Any?) { session.showHidden.toggle(); lastSidebarURL = nil; refreshDirectory(nil) }
    @objc func newFolder(_ sender: Any?) { _ = actions.create(.newFolder) }
    @objc func newTextFile(_ sender: Any?) { _ = actions.create(.newTextFile) }
    @objc func renameSelection(_ sender: Any?) { actions.beginRename(fileList.selectedReferences) }
    @objc func trashSelection(_ sender: Any?) { let refs = fileList.selectedReferences; Task { _ = await actions.trash(refs) } }
    @objc func showFileTasks(_ sender: Any?) { actions.showTasks() }
    @objc func clearRecentDirectories(_ sender: Any?) {
        preferences.value.recentDirectories = []; session.clearHistory(); preferences.changed()
        addressBar.update(directory: session.currentDirectory, canBack: false, canForward: false, preserveDraft: true)
    }
    @objc func toggleKeyboardStyle(_ sender: Any?) {
        fileList.windowsFriendly.toggle()
        capturePreferences()
    }
    func capturePreferences() {
        guard isViewLoaded, initialLoad else { return }
        preferences.value.columns = fileList.columnPreferences()
        preferences.value.sidebarWidth = Double(sidebar.view.bounds.width)
        preferences.value.showHidden = session.showHidden; preferences.value.sort = session.sort
        preferences.value.windowsFriendly = fileList.windowsFriendly
        preferences.value.expandedDirectories = sidebar.expansionPaths
        preferences.changed()
    }
    func pageSnapshot() -> BrowserPageSnapshot {
        if let saved = pendingPageState, renderedDirectory == nil { return saved }
        let anchor = fileList.viewportAnchor.flatMap { url in session.items.first { $0.url == url }?.reference }
        return BrowserPageSnapshot(directory: session.currentDirectory.path, selection: fileList.selectedReferences, anchor: anchor, filter: session.filterQuery, sort: session.sort, showHidden: session.showHidden, columns: fileList.columnPreferences(), sidebarWidth: Double(sidebar.view.bounds.width))
    }
    @objc private func splitResized(_ notification: Notification) { capturePreferences() }
    @objc private func volumesChanged(_ notification: Notification) { sidebar.invalidateDirectories(); lastSidebarURL = nil; backgroundRefresh() }
    func applicationActivated() {
        actions.clipboard.synchronize()
        guard view.window?.isVisible == true else { return }
        resumeMonitoring(); sidebar.checkFavorites(); if renderedDirectory != nil { backgroundRefresh() }
    }
    func resumeMonitoring() { monitoring = true; actionContext.setMonitoring(true, for: actions); updateMonitoring(immediate: true) }
    func stopMonitoring() { monitoring = false; monitorUpdateTask?.cancel(); backgroundTask?.cancel(); actionContext.setMonitoring(false, for: actions); monitor.stop() }
    func monitorCount() async -> Int { await monitor.activeCount() }
    func isMonitoringCurrentDirectory() async -> Bool { await monitor.isWatching(session.currentDirectory) }
    private func applyMonitoring(_ urls: [URL]) {
        monitor.setURLs(urls) { [weak self] changes in Task { @MainActor [weak self] in self?.directoryChanged(changes) } }
    }
    private func updateMonitoring(immediate: Bool = false) {
        guard monitoring, isViewLoaded else { return }
        monitorUpdateTask?.cancel()
        let urls = [session.currentDirectory] + Array(sidebar.watchedDirectories.prefix(24)) + fileList.visibleFileURLs
        if immediate { applyMonitoring(urls); return }
        monitorUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80)); guard !Task.isCancelled, let self, self.monitoring else { return }
            self.applyMonitoring(urls)
        }
    }
    private func directoryChanged(_ changes: [DirectoryChange]) {
        guard monitoring else { return }
        sidebar.refreshDirectories(changes.map(\.url))
        if changes.contains(where: { $0.unavailable || $0.relocatedURL != nil }) { sidebar.checkFavorites() }
        if let relocation = changes.first(where: { $0.url.path == session.currentDirectory.path })?.relocatedURL {
            if fileList.isRenaming || fileDragging { pendingRelocation = relocation; return }
            followRelocation(relocation); return
        }
        backgroundRefresh()
    }
    private func followRelocation(_ url: URL) {
        session.scrollAnchor = fileList.viewportAnchor
        runNavigation(restoreFocus: false) { await $0.navigate(to: url, mode: .refresh) }
    }
    private func backgroundRefresh() {
        guard monitoring, renderedDirectory != nil else { return }
        guard !explicitNavigationPending, !session.isLoading, !fileList.isRenaming, !fileDragging, backgroundTask == nil else { pendingBackgroundRefresh = true; return }
        session.scrollAnchor = fileList.viewportAnchor
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { self.backgroundTask = nil; self.resumePendingRefresh(); return }
            guard !self.explicitNavigationPending, !self.session.isLoading, !self.fileList.isRenaming, !self.fileDragging else {
                self.backgroundTask = nil; self.pendingBackgroundRefresh = true; return
            }
            _ = await self.coordinator.refresh()
            self.backgroundTask = nil
            self.resumePendingRefresh()
        }
    }
    private func resumePendingRefresh() {
        guard !explicitNavigationPending, !session.isLoading, !fileList.isRenaming, !fileDragging else { return }
        if let relocation = pendingRelocation { pendingRelocation = nil; followRelocation(relocation) }
        else if needsWriteRefresh { needsWriteRefresh = false; backgroundRefresh() }
        else if pendingBackgroundRefresh { pendingBackgroundRefresh = false; backgroundRefresh() }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            item.title = actionContext.undoHistory.latest.map { "撤销" + $0.title } ?? "撤销文件操作"
            return !actionContext.isBusy && actionContext.undoHistory.latest != nil && !(view.window?.firstResponder is NSTextView)
        }
        if item.action == #selector(previewSelection(_:)) { return !fileList.selectedReferences.isEmpty && !(view.window?.firstResponder is NSTextView) }
        if item.action == #selector(propertiesSelection(_:)) { return !(view.window?.firstResponder is NSTextView) }
        if item.action == #selector(goBack(_:)) { return session.canGoBack }
        if item.action == #selector(goForward(_:)) { return session.canGoForward }
        if item.action == #selector(toggleHidden(_:)) { item.state = session.showHidden ? .on : .off }
        if item.action == #selector(newFolder(_:)) || item.action == #selector(newTextFile(_:)) { return actions.canWrite && !(view.window?.firstResponder is NSTextView) }
        if item.action == #selector(renameSelection(_:)) { return actions.canWrite && fileList.selectedReferences.count == 1 && !(view.window?.firstResponder is NSTextView) }
        if item.action == #selector(trashSelection(_:)) { return actions.canWrite && !fileList.selectedReferences.isEmpty && !(view.window?.firstResponder is NSTextView) }
        if item.action == #selector(toggleKeyboardStyle(_:)) { item.state = fileList.windowsFriendly ? .on : .off }
        return true
    }
}
