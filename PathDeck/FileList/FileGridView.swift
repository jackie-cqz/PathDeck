import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class FileCollectionView: NSCollectionView, FileDragSource {
    var fileDragState = FileDragState()
    var windowsFriendly = true
    var buildMenu: ((Int) -> NSMenu?)?
    var onShortcut: ((BrowserShortcut) -> Void)?
    var onOpen: (() -> Void)?
    var validate: ((any NSDraggingInfo, Int) -> NSDragOperation)?
    var accept: ((any NSDraggingInfo, Int) -> Bool)?
    var highlight: ((Int?) -> Void)?
    override func mouseDown(with event: NSEvent) {
        var translated = event
        if windowsFriendly && event.modifierFlags.contains(.control) {
            var flags = event.modifierFlags; flags.remove(.control); flags.insert(.command)
            translated = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: flags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) ?? event
        }
        super.mouseDown(with: translated)
        if event.clickCount == 2 { onOpen?() }
    }
    override func keyDown(with event: NSEvent) {
        if let action = event.browserShortcut(windowsFriendly: windowsFriendly) { onShortcut?(action) }
        else { super.keyDown(with: event) }
    }
    @objc func copy(_ sender: Any?) { onShortcut?(.copy) }
    @objc func cut(_ sender: Any?) { onShortcut?(.cut) }
    @objc func paste(_ sender: Any?) { onShortcut?(.paste) }
    override func menu(for event: NSEvent) -> NSMenu? { buildMenu?(indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item ?? -1) }
    private func row(_ info: any NSDraggingInfo) -> Int { indexPathForItem(at: convert(info.draggingLocation, from: nil))?.item ?? -1 }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let index = row(sender), result = validate?(sender, index) ?? []
        highlight?(result.isEmpty ? nil : index); return result
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !draggingUpdated(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { defer { highlight?(nil) }; return accept?(sender, row(sender)) ?? false }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlight?(nil) }
}

@MainActor
private final class TileBackground: NSView {
    var onPress: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool { onPress?() ?? false }
    var selected = false { didSet { needsDisplay = true } }
    var dropTarget = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard selected || dropTarget else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
        (dropTarget ? BrowserAppearance.mint : NSColor.controlAccentColor).withAlphaComponent(0.15).setFill(); shape.fill()
        (dropTarget ? BrowserAppearance.mint : NSColor.controlAccentColor).setStroke(); shape.lineWidth = 1.5; shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class FileTileItem: NSCollectionViewItem {
    let thumbnail = NSImageView()
    let name = NSTextField(labelWithString: "")
    var key = ""
    var operation: BlockOperation?
    private(set) var hasThumbnail = false
    override var isSelected: Bool { didSet { (view as? TileBackground)?.selected = isSelected } }
    override func loadView() {
        view = TileBackground(); thumbnail.imageScaling = .scaleProportionallyUpOrDown
        name.alignment = .center; name.maximumNumberOfLines = 2; name.lineBreakMode = .byTruncatingMiddle; name.font = .systemFont(ofSize: 12)
        for sub in [thumbnail, name] { sub.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(sub) }
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: view.topAnchor, constant: 10), thumbnail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), thumbnail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), thumbnail.heightAnchor.constraint(equalToConstant: 100),
            name.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 8), name.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5), name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5), name.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -6),
        ])
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
    }
    func configure(_ item: FileItem, fallback: NSImage, cut: Bool) {
        loadViewIfNeeded(); operation?.cancel(); operation = nil
        key = FileThumbnailCache.key(item); hasThumbnail = false; thumbnail.image = fallback
        thumbnail.contentTintColor = item.kind == .directory ? BrowserAppearance.mint : nil
        name.stringValue = item.displayName; name.toolTip = item.url.path; view.alphaValue = cut ? 0.45 : 1
        view.setAccessibilityLabel(item.displayName); view.setAccessibilityHelp("\(item.typeDescription)，\(item.url.path)")
        view.setAccessibilityValue(cut ? "待移动" : "")
    }
    func show(_ image: NSImage?) { if let image { thumbnail.image = image; hasThumbnail = true } }
    func markDrop(_ value: Bool) { (view as? TileBackground)?.dropTarget = value }
    override func prepareForReuse() { super.prepareForReuse(); operation?.cancel(); operation = nil; key = ""; thumbnail.image = nil; hasThumbnail = false; markDrop(false); (view as? TileBackground)?.onPress = nil }
}

@MainActor
final class FileGridView: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collection = FileCollectionView()
    let scroll = FileDropScrollView()
    let thumbnails = FileThumbnailCache()
    private let icons = FileIconCache()
    private var items: [FileItem] = []
    private var applying = false
    private var enabled = false
    var cutURLs: Set<URL> = [] { didSet { updateCuts() } }
    var onSelection: (() -> Void)?
    var onViewport: (() -> Void)?
    var writer: ((Int) -> (any NSPasteboardWriting)?)?
    private static let identifier = NSUserInterfaceItemIdentifier("PathDeck.FileTile")
    override init() {
        super.init()
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = NSSize(width: 144, height: 158); layout.minimumInteritemSpacing = 10; layout.minimumLineSpacing = 10; layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collection.collectionViewLayout = layout; collection.dataSource = self; collection.delegate = self
        collection.frame = NSRect(x: 0, y: 0, width: 600, height: 0); collection.autoresizingMask = [.width]
        collection.isSelectable = true; collection.allowsMultipleSelection = true; collection.backgroundColors = [.controlBackgroundColor]
        collection.register(FileTileItem.self, forItemWithIdentifier: Self.identifier)
        collection.registerForDraggedTypes([.fileURL]); scroll.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true); collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setAccessibilityLabel("文件平铺视图"); collection.setAccessibilityIdentifier("PathDeck.FileTiles")
        collection.setAccessibilityHelp("方向键选择，Enter 打开，F2 重命名，空格预览。图片按需加载缩略图。")
        collection.highlight = { [weak self] row in
            guard let self else { return }
            for item in self.collection.visibleItems() { (item as? FileTileItem)?.markDrop(self.collection.indexPath(for: item)?.item == row) }
        }
        scroll.documentView = collection; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    func display(_ values: [FileItem], selection: Set<URL>, anchor: URL?, enabled: Bool) {
        applying = true
        self.enabled = enabled; collection.isSelectable = enabled
        if values != items { items = values; collection.reloadData() }
        collection.selectionIndexPaths = Set(items.indices.filter { selection.contains(items[$0].url) }.map { IndexPath(item: $0, section: 0) })
        if let anchor, let index = items.firstIndex(where: { $0.url == anchor }) { collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .top) }
        applying = false
    }
    var selectedIndexes: IndexSet { IndexSet(collection.selectionIndexPaths.map(\.item).sorted()) }
    func select(_ indexes: IndexSet) { collection.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) }); onSelection?() }
    var visibleIndexes: [Int] { collection.indexPathsForVisibleItems().map(\.item).sorted().filter { items.indices.contains($0) } }
    var anchor: URL? { visibleIndexes.first.map { items[$0].url } }
    func stop() { thumbnails.cancelPending(); for item in collection.visibleItems() { (item as? FileTileItem)?.operation?.cancel() } }
    func resume() {
        for item in collection.visibleItems() {
            guard let tile = item as? FileTileItem, !tile.hasThumbnail, tile.operation == nil || tile.operation?.isCancelled == true || tile.operation?.isFinished == true, let index = collection.indexPath(for: tile) else { continue }
            collectionView(collection, willDisplay: tile, forRepresentedObjectAt: index)
        }
    }
    func reload() { collection.reloadData() }
    func field(at index: Int) -> NSTextField? {
        collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .top)
        collection.layoutSubtreeIfNeeded()
        return (collection.item(at: IndexPath(item: index, section: 0)) as? FileTileItem)?.name
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collection.makeItem(withIdentifier: Self.identifier, for: indexPath) as! FileTileItem
        let value = items[indexPath.item]; tile.configure(value, fallback: icons.image(for: value), cut: cutURLs.contains(value.url))
        (tile.view as? TileBackground)?.onPress = { [weak self, weak tile] in
            guard let self, self.enabled, tile?.key == FileThumbnailCache.key(value), self.items.indices.contains(indexPath.item), self.items[indexPath.item].reference == value.reference else { return false }
            self.select(IndexSet(integer: indexPath.item)); self.collection.onOpen?(); return true
        }
        return tile
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let tile = item as? FileTileItem, items.indices.contains(indexPath.item) else { return }
        tile.operation?.cancel()
        let value = items[indexPath.item], key = tile.key
        tile.operation = thumbnails.request(value) { [weak tile] image in guard tile?.key == key else { return }; tile?.show(image) }
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) { (item as? FileTileItem)?.operation?.cancel() }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { if !applying { onSelection?() } }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { if !applying { onSelection?() } }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? { enabled ? writer?(indexPath.item) : nil }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) { session.draggingFormation = .pile; collection.fileDragState.begin(pasteboard: session.draggingPasteboard) }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) { collection.fileDragState.end() }
    private func updateCuts() { for tile in collection.visibleItems() { if let index = collection.indexPath(for: tile)?.item, items.indices.contains(index) { tile.view.alphaValue = cutURLs.contains(items[index].url) ? 0.45 : 1; tile.view.setAccessibilityValue(cutURLs.contains(items[index].url) ? "待移动" : "") } } }
    @objc private func viewportChanged() { if !applying { onViewport?() } }
}
