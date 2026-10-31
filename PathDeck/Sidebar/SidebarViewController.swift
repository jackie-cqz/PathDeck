import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
private final class TreeNode: NSObject {
    let url: URL?
    let title: String
    let group: Bool
    let favoriteRoot: Bool
    var unavailable: String?
    var children: [TreeNode]?
    var loading = false
    var reference: FileReference?
    var loadingTask: Task<Void, Never>?
    lazy var placeholder = TreeNode("正在读取…")
    init(_ title: String, url: URL? = nil, group: Bool = false, children: [TreeNode]? = nil, favoriteRoot: Bool = false) {
        self.title = title; self.url = url; self.group = group; self.children = children; self.favoriteRoot = favoriteRoot
    }
}

@MainActor private final class DirectoryOutline: NSOutlineView, FileDragSource {
    let fileDragState = FileDragState()
    var activateSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { activateSelection?(); return }; super.keyDown(with: event)
    }
}

@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, FileDragSource {
    private let outline = DirectoryOutline()
    private let reader = DirectoryReader()
    private let referenceReader = FileOperationEngine()
    var fileDragState: FileDragState { outline.fileDragState }
    var drops: FileDropController?
    private var validatedDrop: (sequence: Int, node: TreeNode, destination: FileReference)?
    private var roots: [TreeNode] = []
    private var selecting = false
    private var syncGeneration = 0
    private var syncingTask: Task<Void, Never>?
    private var favorites = FavoriteLocations()
    private var showHidden = false
    private var restoredFavorites: [String]?
    private var restoredNames: [String: String]
    private var availabilityTask: Task<Void, Never>?
    private var availabilityGeneration = 0
    private var mountedVolumes: [URL] = []
    private var currentTarget: URL?
    private var expandedPaths: Set<String>
    private var refreshTask: Task<Void, Never>?
    var onStateChange: (() -> Void)?
    var onFavoritesChange: (() -> Void)?
    var keyboardView: NSView { outline }
    var favoritePaths: [String] { favorites.urls.map(\.path) }
    var favoriteNames: [String: String] { favorites.names }
    var unavailableFavorites: [URL] { (roots.first?.children ?? []).filter { $0.unavailable != nil }.compactMap(\.url) }
    var expansionPaths: [String] { Array(expandedPaths.sorted().prefix(128)) }
    var watchedDirectories: [URL] {
        (0..<outline.numberOfRows).compactMap { row -> URL? in
            guard let node = outline.item(atRow: row) as? TreeNode, outline.isItemExpanded(node) else { return nil }; return node.url
        }
    }
    var onNavigate: ((URL) -> Void)?
    var onCopyPath: ((URL) -> Void)?
    var onReveal: ((URL) -> Void)?
    var onTerminal: ((URL) -> Void)?
    var onVSCode: ((URL) -> Void)?
    var hasVSCode: (() -> Bool)?
    var onOpenPage: ((URL, Bool) -> Void)?
    var onProperties: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?

    init(preferences: AppPreferences) {
        restoredFavorites = preferences.favorites
        restoredNames = preferences.favoriteNames ?? [:]
        expandedPaths = Set(preferences.expandedDirectories)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(persistence:)") }

    override func loadView() {
        let effect = NSVisualEffectView(); effect.material = .sidebar; effect.blendingMode = .withinWindow; view = effect
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory")); column.title = "目录"
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
        outline.dataSource = self; outline.delegate = self; outline.rowHeight = 28; outline.style = .sourceList
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityIdentifier("PathDeck.DirectoryTree")
        outline.setAccessibilityLabel("目录树")
        outline.setAccessibilityHelp("左右方向键展开或折叠目录，Enter 前往选中目录。")
        outline.activateSelection = { [weak self] in
            guard let self, let url = (self.outline.item(atRow: self.outline.selectedRow) as? TreeNode)?.url else { return }; self.onNavigate?(url)
        }
        outline.target = self; outline.action = #selector(clicked)
        outline.menu = NSMenu(); outline.menu?.delegate = self; outline.menu?.autoenablesItems = false
        scroll.documentView = outline
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let fm = FileManager.default
        let defaults = [fm.homeDirectoryForCurrentUser] + [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory].compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        favorites = FavoriteLocations(urls: restoredFavorites?.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaults, names: restoredNames)
        rebuild()
        Task { [weak self, reader] in
            let volumes = (try? await reader.mountedVolumes()) ?? []
            guard let self, let locations = self.roots.last else { return }
            self.mountedVolumes = volumes
            let existing = Set((locations.children ?? []).compactMap(\.url))
            locations.children?.append(contentsOf: volumes.filter { !existing.contains($0) }.map { TreeNode($0.lastPathComponent, url: $0) })
            self.outline.reloadItem(locations, reloadChildren: true)
            self.checkFavorites()
        }
    }
    private func rebuild() {
        fileDragState.invalidateOffers()
        syncingTask?.cancel(); syncGeneration += 1
        for root in roots { cancelLoads(root) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots = [TreeNode("常用目录", group: true, children: favorites.urls.map { TreeNode(favorites.title(for: $0), url: $0, favoriteRoot: true) }),
                 TreeNode("位置", group: true, children: [TreeNode("个人文件夹", url: home), TreeNode("文件系统 /", url: URL(fileURLWithPath: "/"))])]
        let existing = Set((roots.last?.children ?? []).compactMap(\.url))
        roots.last?.children?.append(contentsOf: mountedVolumes.filter { !existing.contains($0) }.map { TreeNode($0.lastPathComponent, url: $0) })
        outline.reloadData(); for group in roots { outline.expandItem(group) }
        for node in roots.flatMap({ $0.children ?? [] }) where node.url.map({ expandedPaths.contains($0.path) }) == true { outline.expandItem(node) }
        checkFavorites()
        if let currentTarget { synchronize(to: currentTarget, showHidden: showHidden) }
    }
    func checkFavorites() {
        availabilityGeneration += 1
        availabilityTask?.cancel()
        let nodes = roots.flatMap { $0.children ?? [] }
        availabilityTask = Task { [weak self, reader, referenceReader] in
            for node in nodes {
                guard !Task.isCancelled, let url = node.url else { return }
                let available = (try? await reader.isBrowsableDirectory(url)) == true
                let reference = available ? await referenceReader.capture([url]).first : nil
                guard !Task.isCancelled, let self else { return }
                node.unavailable = available ? nil : "目录不存在、无法访问或已不是普通目录"
                node.reference = reference
                self.outline.reloadItem(node)
            }
        }
    }
    func waitForAvailability() async {
        var generation: Int
        repeat { generation = availabilityGeneration; await availabilityTask?.value } while generation != availabilityGeneration
    }
    func applyFavorites(paths: [String], names: [String: String]) {
        guard favoritePaths != paths || favoriteNames != names else { return }
        favorites = FavoriteLocations(urls: paths.map { URL(fileURLWithPath: $0, isDirectory: true) }, names: names); rebuild()
    }
    func nameFavorite(_ url: URL, title: String) { favorites.setName(title, for: url); rebuild(); onStateChange?(); onFavoritesChange?() }
    func moveFavorite(_ url: URL, by offset: Int) { favorites.move(url, by: offset); rebuild(); onStateChange?(); onFavoritesChange?() }
    func removeFavorite(_ url: URL) { favorites.remove(url); rebuild(); onStateChange?(); onFavoritesChange?() }
    @discardableResult func relinkFavorite(_ url: URL, to replacement: URL) async -> Bool {
        guard (try? await reader.isBrowsableDirectory(replacement)) == true else { onFailure?("请选择可访问的普通目录。"); return false }
        guard favorites.relink(url, to: replacement) else { onFailure?("该目录已经固定，或原固定项已改变。"); return false }
        rebuild(); onStateChange?(); onFavoritesChange?(); return true
    }
    private func cancelLoads(_ node: TreeNode) {
        node.loadingTask?.cancel()
        for child in node.children ?? [] { cancelLoads(child) }
    }
    func invalidateDirectories() { syncingTask?.cancel(); syncGeneration += 1; rebuild() }
    func refreshDirectories(_ urls: [URL]) {
        let paths = Set(urls.map(\.path))
        func nodes(_ roots: [TreeNode]) -> [TreeNode] { roots + roots.flatMap { nodes($0.children ?? []) } }
        let affected = nodes(roots).filter { $0.url.map { paths.contains($0.path) } == true && $0.children != nil }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for node in affected { guard !Task.isCancelled else { return }; await self.load(node, force: true) }
            self.onStateChange?()
        }
    }
    func pin(_ url: URL) {
        loadViewIfNeeded(); favorites.pin(url); rebuild(); onStateChange?(); onFavoritesChange?()
    }
    func synchronize(to url: URL, showHidden: Bool) {
        loadViewIfNeeded()
        currentTarget = url
        if self.showHidden != showHidden { self.showHidden = showHidden; rebuild() }
        syncGeneration += 1; let generation = syncGeneration
        syncingTask?.cancel()
        syncingTask = Task { [weak self] in
            guard let self else { return }
            let choices = self.roots.flatMap { $0.children ?? [] }.filter { node in
                guard let base = node.url else { return false }; return url.pathComponents.starts(with: base.pathComponents)
            }
            guard var node = choices.max(by: { ($0.url?.pathComponents.count ?? 0) < ($1.url?.pathComponents.count ?? 0) }) else { return }
            while let base = node.url, base.standardizedFileURL != url.standardizedFileURL {
                await self.load(node)
                if !(node.children ?? []).contains(where: { child in child.url.map { url.pathComponents.starts(with: $0.pathComponents) } ?? false }) {
                    node.children = nil
                    await self.load(node, revealing: url)
                }
                guard generation == self.syncGeneration, !Task.isCancelled else { return }
                self.selecting = true; self.outline.expandItem(node); self.selecting = false
                guard let next = node.children?.first(where: { child in child.url.map { url.pathComponents.starts(with: $0.pathComponents) } ?? false }) else { break }
                node = next
            }
            guard generation == self.syncGeneration, !Task.isCancelled else { return }
            let row = self.outline.row(forItem: node)
            if row >= 0 { self.selecting = true; self.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); self.outline.scrollRowToVisible(row); self.selecting = false }
        }
    }
    func waitForSynchronization() async { await syncingTask?.value }
    var selectedDirectory: URL? { (outline.item(atRow: outline.selectedRow) as? TreeNode)?.url }
    private func load(_ node: TreeNode, revealing target: URL? = nil, force: Bool = false) async {
        if let task = node.loadingTask { await task.value; return }
        guard node.children == nil || force, let url = node.url else { return }
        let hidden = showHidden; let reader = reader
        let previous = node.children ?? []
        let task = Task { [weak self] in
            node.loading = true
            do {
                let items = try await reader.childDirectories(url, showHidden: hidden || target != nil)
                let old = Dictionary(previous.compactMap { node in node.url.map { ($0, node) } }, uniquingKeysWith: { a, _ in a })
                node.children = items.filter { hidden || !$0.isHidden || target?.pathComponents.starts(with: $0.url.pathComponents) == true }.map { item in
                    let child = old[item.url] ?? TreeNode(item.displayName, url: item.url); child.reference = item.reference; return child
                }
            } catch is CancellationError { node.children = previous.isEmpty ? nil : previous }
            catch { node.children = [TreeNode("无法读取：\(error.localizedDescription)")] }
            node.loading = false; node.loadingTask = nil
            guard let self, !Task.isCancelled else { return }
            self.selecting = true; self.outline.reloadItem(node, reloadChildren: true); self.selecting = false
            // Restore only branches whose parent is already visible/loaded.
            if self.outline.isItemExpanded(node) {
                for child in node.children ?? [] where child.url.map({ self.expandedPaths.contains($0.path) }) == true { self.outline.expandItem(child) }
            }
            self.onStateChange?()
        }
        node.loadingTask = task
        await task.value
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return roots.count }
        return node.children?.count ?? 1
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return roots[index] }
        return node.children?[index] ?? node.placeholder
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }; return node.group || node.url != nil && (node.children == nil || !(node.children?.isEmpty ?? true))
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? TreeNode)?.group ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? TreeNode)?.url != nil }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard drops?.canStart == true, let node = item as? TreeNode, node.unavailable == nil, let reference = node.reference else { return nil }
        return fileDragState.writer(for: reference)
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        session.draggingFormation = .pile; fileDragState.begin(pasteboard: session.draggingPasteboard)
    }
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { fileDragState.end() }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        validatedDrop = nil
        guard let node = item as? TreeNode, !node.group, node.unavailable == nil, let destination = node.reference, let drops else { return [] }
        let operation = drops.validate(info, destination: destination)
        if !operation.isEmpty { outline.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex); validatedDrop = (info.draggingSequenceNumber, node, destination) }
        return operation
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? TreeNode, let validatedDrop, validatedDrop.sequence == info.draggingSequenceNumber,
              validatedDrop.node === node, node.unavailable == nil, node.reference == validatedDrop.destination, outline.row(forItem: node) >= 0 else { return false }
        return drops?.accept(info, destination: validatedDrop.destination) ?? false
    }
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        Task { [weak self] in await self?.load(node) }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        if let path = node.url?.path { expandedPaths.insert(path); if expandedPaths.count > 128 { expandedPaths = Set(expandedPaths.sorted().prefix(128)) } }
        onStateChange?()
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        if let path = node.url?.path { expandedPaths.remove(path) }
        cancelLoads(node)
        node.children = nil
        onStateChange?()
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let cell = NSTableCellView(); let label = NSTextField(labelWithString: node.title + (node.unavailable == nil ? "" : "（不可用）"))
        label.font = .systemFont(ofSize: node.group ? 11 : 13, weight: node.group ? .semibold : .regular)
        label.textColor = node.group || node.url == nil ? .secondaryLabelColor : .labelColor; label.lineBreakMode = .byTruncatingMiddle; label.toolTip = node.url?.path ?? node.title
        label.setAccessibilityLabel(node.group ? "目录分组" : "文件夹")
        label.setAccessibilityValue(label.stringValue); label.setAccessibilityHelp([node.url?.path, node.unavailable].compactMap { $0 }.joined(separator: "，"))
        cell.textField = label; label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label)
        if !node.group {
            let symbol = node.unavailable != nil ? "exclamationmark.triangle" : node.url?.path == "/" ? "internaldrive" : node.url == FileManager.default.homeDirectoryForCurrentUser ? "house" : node.favoriteRoot ? "star" : "folder"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = node.unavailable == nil ? BrowserAppearance.mint : .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)])
        } else { label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true }
        NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    @objc private func clicked() {
        guard !selecting, outline.clickedRow >= 0, outline.clickedColumn >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? TreeNode, let url = node.url else { return }
        // Disclosure triangles have their own expansion action; only the row's label navigates.
        let mouse = outline.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        if mouse.x < outline.frameOfCell(atColumn: 0, row: outline.clickedRow).minX { return }
        onNavigate?(url)
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? TreeNode, let url = node.url else { return }
        for item in contextMenu(for: url, favoriteRoot: node.favoriteRoot).items { item.menu?.removeItem(item); menu.addItem(item) }
    }
    func contextMenu(for url: URL, favoriteRoot: Bool) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = url; item.isEnabled = enabled; menu.addItem(item)
        }
        add("打开", #selector(menuOpen(_:)))
        add("在新标签页打开", #selector(menuNewTab(_:))); add("在新窗口打开", #selector(menuNewWindow(_:)))
        add("在终端中打开", #selector(menuTerminal(_:)), enabled: !unavailableFavorites.contains(url))
        add(hasVSCode?() == true ? "用 VS Code 打开" : "用 VS Code 打开（未安装）", #selector(menuVSCode(_:)), enabled: hasVSCode?() == true && !unavailableFavorites.contains(url))
        add("在访达中显示", #selector(menuReveal(_:)))
        menu.addItem(.separator()); add("复制完整路径", #selector(menuCopy(_:)))
        add(favorites.urls.contains(url) ? "取消固定" : "固定到常用目录", #selector(menuPin(_:)))
        if favoriteRoot, let index = favorites.urls.firstIndex(of: url) {
            menu.addItem(.separator()); add("编辑显示名称…", #selector(menuName(_:)))
            add("上移", #selector(menuMoveUp(_:)), enabled: index > 0)
            add("下移", #selector(menuMoveDown(_:)), enabled: index + 1 < favorites.urls.count)
            add("重新定位…", #selector(menuRelink(_:))); add("检查可用性", #selector(menuCheck(_:)))
        }
        menu.addItem(.separator()); add("属性…", #selector(menuProperties(_:)))
        return menu
    }
    @objc private func menuNewTab(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onOpenPage?(url, true) } }
    @objc private func menuNewWindow(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onOpenPage?(url, false) } }
    @objc private func menuProperties(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onProperties?(url) } }
    @objc private func menuTerminal(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onTerminal?(url) } }
    @objc private func menuVSCode(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onVSCode?(url) } }
    @objc private func menuMoveUp(_ item: NSMenuItem) { if let url = item.representedObject as? URL { moveFavorite(url, by: -1) } }
    @objc private func menuMoveDown(_ item: NSMenuItem) { if let url = item.representedObject as? URL { moveFavorite(url, by: 1) } }
    @objc private func menuCheck(_ item: NSMenuItem) { checkFavorites() }
    @objc private func menuName(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL, let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = "编辑常用目录显示名称"; alert.informativeText = "只改变侧栏标题；留空恢复原名称。\n\(url.path)"
        let field = NSTextField(string: favorites.names[url.path] ?? ""); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("常用目录显示名称"); alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.nameFavorite(url, title: field.stringValue) } }
        alert.window.makeFirstResponder(field)
    }
    @objc private func menuRelink(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL, let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "为这个常用项选择新位置（保留显示名称与顺序）"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let replacement = panel.url else { return }
            Task { @MainActor in await self?.relinkFavorite(url, to: replacement) }
        }
    }
    @objc private func menuOpen(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onNavigate?(url) } }
    @objc private func menuCopy(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onCopyPath?(url) } }
    @objc private func menuReveal(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onReveal?(url) } }
    @objc private func menuPin(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        if favorites.urls.contains(url) { removeFavorite(url) } else { pin(url) }
    }
}
