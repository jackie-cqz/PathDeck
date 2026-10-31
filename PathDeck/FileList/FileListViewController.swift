import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
private final class BrowserTable: NSTableView {
    var buildMenu: ((Int) -> NSMenu?)?
    var openSelection: (() -> Void)?
    var onBack: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    var windowsFriendly = true
    var canPaste: (() -> Bool)?
    var onShortcut: ((BrowserShortcut) -> Void)?
    override func mouseDown(with event: NSEvent) {
        if windowsFriendly && event.modifierFlags.contains(.control) {
            // Use AppKit's complete multi-selection tracking, including drag initiation.
            var flags = event.modifierFlags; flags.remove(.control); flags.insert(.command)
            if let translated = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: flags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) {
                super.mouseDown(with: translated); return
            }
        }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return contextMenu(at: row)
    }
    func contextMenu(at row: Int) -> NSMenu? {
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return buildMenu?(row)
    }
    override func keyDown(with event: NSEvent) {
        if let action = event.browserShortcut(windowsFriendly: windowsFriendly) { onShortcut?(action); return }
        super.keyDown(with: event)
    }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func paste(_ sender: Any?) { onPaste?() }
}

@MainActor private final class FileListMessage: NSTextField {
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension BrowserTable: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)) { return canPaste?() ?? false }
        return numberOfSelectedRows > 0 && isEnabled
    }
}

@MainActor
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private let table = BrowserTable()
    private let message = FileListMessage(wrappingLabelWithString: "正在读取目录…")
    private var items: [FileItem] = []
    private var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    private var applying = false
    private var directoryReference: FileReference?
    private var cutURLs: Set<URL> = []
    private var renaming: FileReference?
    private var cancellingRename = false
    private var changingRenameFocus = false
    private weak var renamingField: NSTextField?
    private let icons = FileIconCache()
    var onColumnsChanged: (() -> Void)?
    var onEditingEnded: (() -> Void)?
    var onViewportChanged: (() -> Void)?
    private var nameColumn: Int { table.column(withIdentifier: .init("name")) }
    var keyboardView: NSView { table }
    var iconCacheCount: Int { icons.count }
    var windowsFriendly: Bool { get { table.windowsFriendly } set { table.windowsFriendly = newValue } }
    var compact: Bool = false { didSet { table.rowHeight = compact ? 24 : 30; table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows)) } }
    var onWriteCopy: (([FileReference], Bool) -> Void)?
    var onWritePaste: ((FileReference?) -> Void)?
    var onWriteCreate: ((FileOperationKind, FileReference?) -> Void)?
    var onWriteRename: (([FileReference]) -> Void)?
    var onCommitRename: ((FileReference, String) -> Void)?
    var onWriteTrash: (([FileReference]) -> Void)?
    var hasClipboardFiles: (() -> Bool)?
    var onOpen: ((FileItem) -> Void)?
    var onCopyPaths: (([URL]) -> Void)?
    var onReveal: (([URL]) -> Void)?
    var onPin: ((URL) -> Void)?
    var onRefresh: (() -> Void)?
    var onBack: (() -> Void)?
    var onSort: ((FileSort) -> Void)?
    var onSelection: ((Set<URL>, URL?) -> Void)?
    var onOpenWith: ((URL) -> Void)?
    var onTerminal: ((URL) -> Void)?
    var onVSCode: (([URL]) -> Void)?
    var hasVSCode: (() -> Bool)?
    var onShortcut: ((BrowserShortcut) -> Void)?
    var onPreview: (([URL]) -> Void)?
    var onProperties: (([URL]) -> Void)?
    var onOpenPage: ((URL, Bool) -> Void)?

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        table.style = .plain; table.rowHeight = compact ? 24 : 30
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true
        table.setAccessibilityIdentifier("PathDeck.FileList")
        table.setAccessibilityLabel("文件列表")
        table.setAccessibilityHelp("使用方向键选择文件，Enter 打开，F2 重命名；可通过列标题排序。")
        table.target = self; table.doubleAction = #selector(openSelected)
        table.openSelection = { [weak self] in self?.openSelected() }
        table.onBack = { [weak self] in self?.onBack?() }
        table.onCopy = { [weak self] in guard let self else { return }; self.onWriteCopy?(self.selectedReferences, false) }
        table.onCut = { [weak self] in guard let self else { return }; self.onWriteCopy?(self.selectedReferences, true) }
        table.onPaste = { [weak self] in self?.onWritePaste?(nil) }
        table.onRename = { [weak self] in guard let self else { return }; self.onWriteRename?(self.selectedReferences) }
        table.onTrash = { [weak self] in guard let self else { return }; self.onWriteTrash?(self.selectedReferences) }
        table.canPaste = { [weak self] in guard let self else { return false }; return self.table.isEnabled && self.hasClipboardFiles?() == true }
        table.buildMenu = { [weak self] in self?.contextMenu(row: $0) }
        table.onShortcut = { [weak self] in self?.onShortcut?($0) }
        for (id, title, width) in [("name", "名称", 360.0), ("modified", "修改日期", 170.0), ("kind", "类型", 130.0), ("size", "大小", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        scroll.documentView = table
        let headerMenu = NSMenu(); headerMenu.autoenablesItems = false; headerMenu.delegate = self; table.headerView?.menu = headerMenu
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        message.font = .systemFont(ofSize: 15); message.textColor = .secondaryLabelColor; message.alignment = .center
        message.setAccessibilityIdentifier("PathDeck.ListState")
        message.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(message)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor), message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])
    }

    func display(_ session: BrowserSession) {
        loadViewIfNeeded()
        applying = true
        let changed = items != session.visibleItems || currentDirectory.path != session.currentDirectory.path
        if !changed && isRenaming { applying = false; return }
        items = session.visibleItems; currentDirectory = session.currentDirectory
        directoryReference = session.directoryReference
        table.sortDescriptors = [NSSortDescriptor(key: session.sort.column.rawValue, ascending: session.sort.ascending)]
        if changed { table.reloadData() }
        let selection = IndexSet(items.indices.filter { session.selection.contains(items[$0].url) })
        table.selectRowIndexes(selection, byExtendingSelection: false)
        if let anchor = session.scrollAnchor, let index = items.firstIndex(where: { $0.url == anchor }), let clip = table.enclosingScrollView?.contentView {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: index).minY)); table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        else if let index = selection.first { table.scrollRowToVisible(index) }
        switch session.contentState {
        case .notLoaded: message.stringValue = "目录尚未读取"
        case .loading(let target): message.stringValue = items.isEmpty ? "正在读取 \(target.lastPathComponent)…" : ""
        case .loaded: message.stringValue = items.isEmpty ? (session.filterQuery.isEmpty ? "这个文件夹是空的" : "当前目录没有匹配的项目") : ""
        case .failed(let error): message.stringValue = items.isEmpty ? error : ""
        }
        table.isEnabled = session.contentState == .loaded
        applying = false
    }
    func focus() { view.window?.makeFirstResponder(table) }
    func performShortcut(_ action: BrowserShortcut) {
        switch action {
        case .copy: table.onCopy?(); case .cut: table.onCut?(); case .paste: table.onPaste?()
        case .selectAll: table.selectAll(nil); case .open: openSelected()
        case .rename: table.onRename?(); case .trash: table.onTrash?()
        default: break
        }
    }
    func columnPreferences() -> [ColumnPreference] { table.tableColumns.map { ColumnPreference(id: $0.identifier.rawValue, width: $0.width, hidden: $0.isHidden) } }
    func restoreColumns(_ preferences: [ColumnPreference]) {
        loadViewIfNeeded(); applying = true
        for (index, value) in preferences.enumerated() {
            guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == value.id }) else { continue }
            table.moveColumn(table.column(withIdentifier: column.identifier), toColumn: index)
            column.width = value.width; column.isHidden = value.id == "name" ? false : value.hidden
        }
        applying = false
    }
    func tableViewColumnDidResize(_ notification: Notification) { if !applying { onColumnsChanged?() } }
    func tableViewColumnDidMove(_ notification: Notification) { if !applying { onColumnsChanged?() } }
    @objc private func viewportChanged() { if !applying { onViewportChanged?() } }
    var visibleFileURLs: [URL] {
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return [] }
        return Array((range.location..<NSMaxRange(range)).filter { items.indices.contains($0) && items[$0].kind != .directory }.prefix(32).map { items[$0].url })
    }
    var rowCount: Int { table.numberOfRows }
    var isRenaming: Bool { renaming != nil }
    func cancelRename() {
        guard renaming != nil else { return }
        cancellingRename = true
        if let renaming { renamingField?.stringValue = renaming.url.lastPathComponent }
        renamingField?.isEditable = false
        if renamingField?.currentEditor() != nil { view.window?.makeFirstResponder(table) }
        renaming = nil; renamingField = nil; cancellingRename = false
    }
    func contextMenu(at row: Int) -> NSMenu? { table.contextMenu(at: row) }
    var selectedURLs: Set<URL> { Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].url : nil }) }
    var selectedReferences: [FileReference] { table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].reference : nil } }
    func setCutURLs(_ urls: Set<URL>) {
        cutURLs = urls
        for row in table.rows(in: table.visibleRect).location..<NSMaxRange(table.rows(in: table.visibleRect)) where items.indices.contains(row) {
            table.view(atColumn: nameColumn, row: row, makeIfNecessary: false)?.alphaValue = urls.contains(items[row].url) ? 0.45 : 1
            if let cell = table.view(atColumn: nameColumn, row: row, makeIfNecessary: false) as? NSTableCellView { cell.textField?.setAccessibilityValue(items[row].displayName + (urls.contains(items[row].url) ? "，待移动" : "")) }
        }
    }
    func beginRename(_ reference: FileReference) {
        guard let row = items.firstIndex(where: { $0.url == reference.url && $0.identity == reference.identity }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView, let field = cell.textField else { return }
        view.window?.makeFirstResponder(table)
        changingRenameFocus = true
        defer { changingRenameFocus = false }
        renaming = reference; renamingField = field; field.stringValue = items[row].realName; field.isEditable = true; field.isSelectable = true
        view.window?.makeFirstResponder(field); field.selectText(nil)
        if let editor = field.currentEditor() as? NSTextView {
            let name = items[row].realName as NSString
            let ext = name.pathExtension
            let length = ext.isEmpty || name.length == ext.count + 1 ? name.length : name.length - (ext as NSString).length - 1
            editor.setSelectedRange(NSRange(location: 0, length: length))
        }
    }
    var viewportAnchor: URL? {
        let row = table.row(at: table.visibleRect.origin)
        return items.indices.contains(row) ? items[row].url : nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let column = tableColumn else { return nil }
        let item = items[row]
        let identifier = NSUserInterfaceItemIdentifier("cell." + column.identifier.rawValue)
        let cell: NSTableCellView
        if let reused = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView(); cell.identifier = identifier
            let field = NSTextField(labelWithString: ""); field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field); cell.textField = field
            let isName = column.identifier.rawValue == "name"
            if isName {
                let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(image); cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18)])
            }
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: isName ? 31 : 5), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        guard let text = cell.textField else { return cell }
        text.isEditable = false; text.isSelectable = false; text.alignment = .left
        text.setAccessibilityLabel(column.title)
        cell.alphaValue = 1
        switch column.identifier.rawValue {
        case "name":
            text.stringValue = item.displayName + (item.kind == .symbolicLink ? " ↗" : "")
            cell.imageView?.image = icons.image(for: item)
            text.delegate = self; cell.alphaValue = cutURLs.contains(item.url) ? 0.45 : 1
        case "modified": text.stringValue = item.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—"
        case "kind": text.stringValue = item.typeDescription
        default: text.stringValue = item.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"; text.alignment = .right
        }
        text.toolTip = item.url.path
        text.setAccessibilityValue(text.stringValue + (column.identifier.rawValue == "name" && cutURLs.contains(item.url) ? "，待移动" : ""))
        text.setAccessibilityHelp(column.identifier.rawValue == "name" ? "\(item.typeDescription)，\(item.url.path)" : "")
        return cell
    }
    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        let firstVisible = table.row(at: table.visibleRect.origin)
        onSelection?(selectedURLs, items.indices.contains(firstVisible) ? items[firstVisible].url : nil)
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applying, let descriptor = table.sortDescriptors.first else { return }
        onSort?(FileSort(column: FileSort.Column(rawValue: descriptor.key ?? "name") ?? .name, ascending: descriptor.ascending))
    }
    @objc private func openSelected() {
        guard table.selectedRow >= 0, items.indices.contains(table.selectedRow) else { return }; onOpen?(items[table.selectedRow])
    }
    private func contextMenu(row: Int) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let chosen = row < 0 ? [] : table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
        func add(_ title: String, _ action: Selector, _ urls: [URL]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = urls; menu.addItem(item)
        }
        func write(_ title: String, _ action: Selector, _ object: Any?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = object
            item.isEnabled = table.isEnabled && directoryReference != nil
            if title.hasPrefix("粘贴") { item.isEnabled = item.isEnabled && hasClipboardFiles?() == true }
            menu.addItem(item)
        }
        let references = chosen.map(\.reference)
        let urls = chosen.isEmpty ? [currentDirectory] : chosen.map(\.url)
        let folder = chosen.isEmpty ? currentDirectory : chosen.count == 1 && chosen[0].kind == .directory ? chosen[0].url : nil
        if chosen.count == 1, let item = chosen.first {
            add("打开", #selector(openContext(_:)), [item.url])
            if item.kind != .directory { add("打开方式…", #selector(openWithContext(_:)), [item.url]) }
        }
        if let folder { add("在新标签页打开", #selector(newTabContext(_:)), [folder]); add("在新窗口打开", #selector(newWindowContext(_:)), [folder]) }
        let editorAvailable = hasVSCode?() == true
        let editor = NSMenuItem(title: editorAvailable ? "用 VS Code 打开" : "用 VS Code 打开（未安装）", action: #selector(vscodeContext(_:)), keyEquivalent: "")
        editor.target = self; editor.representedObject = urls; editor.isEnabled = editorAvailable; menu.addItem(editor)
        if let folder { add("在终端中打开", #selector(terminalContext(_:)), [folder]) }
        if !chosen.isEmpty { add("快速预览", #selector(previewContext(_:)), urls) }
        menu.addItem(.separator())
        if chosen.isEmpty {
            write("新建文件夹", #selector(newFolderContext(_:)), directoryReference)
            write("新建文本文件", #selector(newTextContext(_:)), directoryReference)
            write("粘贴", #selector(pasteContext(_:)), directoryReference)
        }
        if !chosen.isEmpty {
            write("剪切", #selector(cutContext(_:)), references); write("复制", #selector(copyFilesContext(_:)), references)
            if chosen.count == 1 { write("重命名", #selector(renameContext(_:)), references) }
            if folder != nil { write("粘贴到此文件夹", #selector(pasteContext(_:)), references.first) }
            write("移入废纸篓", #selector(trashContext(_:)), references)
        }
        menu.addItem(.separator())
        add(chosen.isEmpty ? "复制当前路径" : "复制完整路径", #selector(copyContext(_:)), urls)
        add("在访达中显示", #selector(revealContext(_:)), urls)
        if chosen.isEmpty || (chosen.count == 1 && chosen[0].kind == .directory) {
            add("固定到常用目录", #selector(pinContext(_:)), urls)
        }
        add("属性…", #selector(propertiesContext(_:)), urls)
        if chosen.isEmpty { menu.addItem(.separator()); add("刷新", #selector(refreshContext), urls) }
        return menu
    }
    @objc private func copyContext(_ item: NSMenuItem) { if let urls = item.representedObject as? [URL] { onCopyPaths?(urls) } }
    @objc private func revealContext(_ item: NSMenuItem) { if let urls = item.representedObject as? [URL] { onReveal?(urls) } }
    @objc private func pinContext(_ item: NSMenuItem) { if let url = (item.representedObject as? [URL])?.first { onPin?(url) } }
    @objc private func terminalContext(_ item: NSMenuItem) { if let url = (item.representedObject as? [URL])?.first { onTerminal?(url) } }
    @objc private func vscodeContext(_ item: NSMenuItem) { if let urls = item.representedObject as? [URL] { onVSCode?(urls) } }
    @objc private func previewContext(_ item: NSMenuItem) { if let urls = item.representedObject as? [URL] { onPreview?(urls) } }
    @objc private func propertiesContext(_ item: NSMenuItem) { if let urls = item.representedObject as? [URL] { onProperties?(urls) } }
    @objc private func newTabContext(_ item: NSMenuItem) { if let url = (item.representedObject as? [URL])?.first { onOpenPage?(url, true) } }
    @objc private func newWindowContext(_ item: NSMenuItem) { if let url = (item.representedObject as? [URL])?.first { onOpenPage?(url, false) } }
    @objc private func openContext(_ menu: NSMenuItem) { if let url = (menu.representedObject as? [URL])?.first, let item = items.first(where: { $0.url == url }) { onOpen?(item) } }
    @objc private func openWithContext(_ menu: NSMenuItem) { if let url = (menu.representedObject as? [URL])?.first { onOpenWith?(url) } }
    @objc private func refreshContext() { onRefresh?() }
    @objc private func newFolderContext(_ item: NSMenuItem) { onWriteCreate?(.newFolder, item.representedObject as? FileReference) }
    @objc private func newTextContext(_ item: NSMenuItem) { onWriteCreate?(.newTextFile, item.representedObject as? FileReference) }
    @objc private func pasteContext(_ item: NSMenuItem) { onWritePaste?(item.representedObject as? FileReference) }
    @objc private func cutContext(_ item: NSMenuItem) { if let refs = item.representedObject as? [FileReference] { onWriteCopy?(refs, true) } }
    @objc private func copyFilesContext(_ item: NSMenuItem) { if let refs = item.representedObject as? [FileReference] { onWriteCopy?(refs, false) } }
    @objc private func renameContext(_ item: NSMenuItem) { if let refs = item.representedObject as? [FileReference] { onWriteRename?(refs) } }
    @objc private func trashContext(_ item: NSMenuItem) { if let refs = item.representedObject as? [FileReference] { onWriteTrash?(refs) } }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard !changingRenameFocus, let field = notification.object as? NSTextField, field === renamingField, let reference = renaming else { return }
        renaming = nil; renamingField = nil; field.isEditable = false
        if !cancellingRename && field.stringValue != reference.url.lastPathComponent { onCommitRename?(reference, field.stringValue) }
        onEditingEnded?()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.cancelOperation(_:)) {
            cancellingRename = true
            if let reference = renaming { (control as? NSTextField)?.stringValue = reference.url.lastPathComponent }
            view.window?.makeFirstResponder(table); renaming = nil; cancellingRename = false; return true
        }
        if command == #selector(NSResponder.insertNewline(_:)) { view.window?.makeFirstResponder(table); return true }
        return false
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in table.tableColumns {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = column.identifier.rawValue; item.state = column.isHidden ? .off : .on
            item.isEnabled = column.identifier.rawValue != "name"; menu.addItem(item)
        }
    }
    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let column = table.tableColumns.first(where: { $0.identifier.rawValue == id }), id != "name" else { return }
        column.isHidden.toggle(); onColumnsChanged?()
    }
}
