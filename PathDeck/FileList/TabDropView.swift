import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

/// Public NSWindowTab accessory: spring-select and drop into this page's directory.
@MainActor
final class TabDropView: NSView {
    private weak var browser: BrowserViewController?
    private weak var ownerWindow: NSWindow?
    private var destination: FileReference?
    init(browser: BrowserViewController, window: NSWindow) {
        self.browser = browser; ownerWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 20))
        registerForDraggedTypes([.fileURL]); toolTip = "拖到此图标打开标签页，松手放入该目录"
        setAccessibilityLabel("标签页文件拖放目标")
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = BrowserAppearance.mint; icon.frame = NSRect(x: 3, y: 3, width: 16, height: 14); addSubview(icon)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(browser:window:)") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { validate(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { validate(sender) }
    private func validate(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.fileURL) == true, let browser, let ownerWindow else { return [] }
        if ownerWindow.tabGroup?.selectedWindow !== ownerWindow { ownerWindow.tabGroup?.selectedWindow = ownerWindow; ownerWindow.makeKeyAndOrderFront(nil); ownerWindow.makeMain() }
        destination = browser.session.directoryReference
        return destination.map { browser.drops.validate(sender, destination: $0) } ?? []
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !validate(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let browser, let destination, destination == browser.session.directoryReference else { return false }
        return browser.drops.accept(sender, destination: destination)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { destination = nil }
}
