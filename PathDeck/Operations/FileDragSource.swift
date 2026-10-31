import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
protocol FileDragSource: AnyObject {
    var fileDragState: FileDragState { get }
}

/// References come from the exact rows offered to AppKit, never from a later row index.
@MainActor
final class FileDragState {
    private var offered: [URL: FileReference] = [:]
    private(set) var references: [FileReference] = []
    private(set) var isActive = false
    var onActivity: ((Bool) -> Void)?
    func invalidateOffers() { if !isActive { offered = [:] } }
    func writer(for reference: FileReference) -> NSPasteboardWriting? {
        guard reference.identity != nil, reference.url.path != "/" else { return nil }
        offered[reference.url.standardizedFileURL] = reference
        return reference.url as NSURL
    }
    func begin(pasteboard: NSPasteboard) {
        let urls = Self.urls(in: pasteboard)
        references = urls.compactMap { offered[$0.standardizedFileURL] }
        if references.count != urls.count { references = [] }
        offered = [:]; isActive = !references.isEmpty; onActivity?(isActive)
    }
    func end() { offered = [:]; references = []; isActive = false; onActivity?(false) }
    static func urls(in pasteboard: NSPasteboard) -> [URL] {
        var seen: Set<URL> = []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }
    }
}
