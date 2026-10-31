import AppKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class FileIconCache {
    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    let limit = 128
    var count: Int { images.count }
    func image(for item: FileItem) -> NSImage {
        let key = item.kind == .directory ? "folder" : item.kind == .package ? "package" : "ext:" + item.url.pathExtension.lowercased()
        if let image = images[key] { return image }
        let image: NSImage
        if item.kind == .directory { image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage() }
        else { image = NSWorkspace.shared.icon(for: item.kind == .package ? .applicationBundle : UTType(filenameExtension: item.url.pathExtension) ?? .data) }
        images[key] = image; order.append(key)
        if order.count > limit { images[order.removeFirst()] = nil }
        return image
    }
}
