import AppKit
import QuickLookUI

@MainActor
final class FilePreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        var previewItemTitle: String? { previewItemURL?.lastPathComponent }
        init(_ url: URL) { previewItemURL = url }
    }
    private var items: [Item] = []
    weak var owner: BrowserViewController?
    var urls: [URL] { items.compactMap(\.previewItemURL) }
    var controlsPanel: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let owner, let controller = QLPreviewPanel.shared()?.currentController as AnyObject? else { return false }
        return controller === owner || controller === owner.viewIfLoaded?.window?.windowController
    }
    func setSelection(_ urls: [URL]) {
        items = urls.map(Item.init)
        if controlsPanel {
            if items.isEmpty { dismiss() } else { QLPreviewPanel.shared()?.reloadData() }
        }
    }
    func toggle(_ urls: [URL]) {
        if controlsPanel, QLPreviewPanel.shared()?.isVisible == true { dismiss(); return }
        setSelection(urls); guard !items.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        owner?.fileList.focus()
        // Quick Look establishes its controller when the panel enters the key-window chain.
        panel.makeKeyAndOrderFront(nil); panel.updateController()
        if controlsPanel { panel.reloadData(); panel.currentPreviewItemIndex = 0 }
    }
    func dismiss(restoreFocus: Bool = true) {
        if controlsPanel {
            QLPreviewPanel.shared()?.orderOut(nil)
            if restoreFocus { owner?.viewIfLoaded?.window?.makeKeyAndOrderFront(nil); owner?.fileList.focus() }
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items.indices.contains(index) ? items[index] : nil }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown && (event.keyCode == 49 || event.keyCode == 53) { dismiss(); return true }
        return false
    }
}
