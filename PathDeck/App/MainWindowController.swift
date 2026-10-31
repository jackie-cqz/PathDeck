import AppKit
import QuickLookUI
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
private final class BrowserWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let browser = contentViewController as? BrowserViewController, firstResponder === browser.fileList.keyboardView,
           let action = event.browserShortcut(windowsFriendly: browser.fileList.windowsFriendly) {
            browser.handleShortcut(action); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension NSEvent {
    func browserShortcut(windowsFriendly: Bool) -> BrowserShortcut? {
        var flags: BrowserShortcut.Modifiers = []
        if modifierFlags.contains(.command) { flags.insert(.command) }; if modifierFlags.contains(.control) { flags.insert(.control) }
        if modifierFlags.contains(.option) { flags.insert(.option) }; if modifierFlags.contains(.shift) { flags.insert(.shift) }
        return BrowserShortcut.resolve(keyCode: keyCode, characters: charactersIgnoringModifiers, modifiers: flags, windowsFriendly: windowsFriendly, editingText: false)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let preferences: PreferencesController
    private(set) var isClosed = false
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onNewTab: (() -> Void)?
    var browser: BrowserViewController { window!.contentViewController as! BrowserViewController }
    init(session: BrowserSession, preferences: PreferencesController, actionContext: FileActionContext? = nil, pageState: BrowserPageSnapshot? = nil) {
        self.preferences = preferences
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PathDeck"
        window.subtitle = "文件管理"
        window.identifier = NSUserInterfaceItemIdentifier("PathDeck.MainWindow")
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.tabbingIdentifier = "PathDeck.Browser"; window.tabbingMode = .preferred
        window.contentViewController = BrowserViewController(session: session, preferences: preferences, actionContext: actionContext, pageState: pageState)
        // Assigning a zero-frame programmatic view controller can shrink the
        // window to its minimum size. Set the intended content size afterwards.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
        window.setContentSize(NSSize(
            width: min(1180, max(820, screen.width - 80)),
            height: min(760, max(492, screen.height - 100))
        ))
        window.center()
        if let saved = preferences.value.window {
            let rect = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            let screens = NSScreen.screens.map(\.visibleFrame)
            let available = screens.first(where: { $0.intersects(rect) }) ?? NSScreen.main?.visibleFrame ?? rect
            let width = min(rect.width, available.width), height = min(rect.height, available.height)
            window.setFrame(NSRect(x: max(available.minX, min(rect.minX, available.maxX - width)), y: max(available.minY, min(rect.minY, available.maxY - height)), width: width, height: height), display: false)
        }
        super.init(window: window)
        window.delegate = self
        window.tab.accessoryView = TabDropView(browser: browser, window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(session:)") }
    override func showWindow(_ sender: Any?) { isClosed = false; super.showWindow(sender) }
    override func newWindowForTab(_ sender: Any?) { onNewTab?() }
    // Quick Look's legacy hooks run on AppKit's UI thread but lack actor annotations.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { MainActor.assumeIsolated { !browser.preview.urls.isEmpty } }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = browser.preview; panel.delegate = browser.preview } }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = nil; panel.delegate = nil } }
    func windowDidBecomeMain(_ notification: Notification) { onActivate?(); browser.resumeMonitoring() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if !isClosed, window?.isVisible == true { browser.resumeMonitoring() }
    }
    func captureWindow() {
        guard let window else { return }
        preferences.value.window = WindowPlacement(x: window.frame.minX, y: window.frame.minY, width: window.frame.width, height: window.frame.height)
        (window.contentViewController as? BrowserViewController)?.capturePreferences()
        preferences.changed()
    }
    func windowDidResize(_ notification: Notification) { captureWindow() }
    func windowDidMove(_ notification: Notification) { captureWindow() }
    func windowWillClose(_ notification: Notification) { captureWindow(); isClosed = true; browser.stopMonitoring(); browser.closeAuxiliaryWindows(); onClose?() }
    func persistAndFlush() async { captureWindow(); await preferences.flush() }
    func applyPlacement(_ saved: WindowPlacement) {
        guard let window else { return }
        let rect = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        let available = NSScreen.screens.map(\.visibleFrame).first { $0.intersects(rect) } ?? NSScreen.main?.visibleFrame ?? rect
        let width = min(saved.width, available.width), height = min(saved.height, available.height)
        window.setFrame(NSRect(x: max(available.minX, min(saved.x, available.maxX - width)), y: max(available.minY, min(saved.y, available.maxY - height)), width: width, height: height), display: true)
    }
}

