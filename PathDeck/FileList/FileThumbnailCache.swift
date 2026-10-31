import AppKit
import ImageIO
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class FileThumbnailCache {
    private final class Entry: NSObject { let image: NSImage?; init(_ image: NSImage?) { self.image = image } }
    private let cache = NSCache<NSString, Entry>()
    private let queue: OperationQueue = { let q = OperationQueue(); q.name = "PathDeck.Thumbnails"; q.maxConcurrentOperationCount = 2; q.qualityOfService = .utility; return q }()
    init() { cache.countLimit = 128; cache.totalCostLimit = 32 * 1024 * 1024 }
    static func key(_ item: FileItem) -> String { "\(item.url.path)|\(String(describing: item.identity))|\(item.modificationDate?.timeIntervalSince1970 ?? 0)|\(item.byteCount ?? 0)" }
    @discardableResult func request(_ item: FileItem, completion: @escaping @MainActor @Sendable (NSImage?) -> Void) -> BlockOperation? {
        guard item.kind == .regularFile, item.identity != nil, UTType(filenameExtension: item.url.pathExtension.lowercased())?.conforms(to: .image) == true else { completion(nil); return nil }
        let key = Self.key(item)
        if let value = cache.object(forKey: key as NSString) { completion(value.image); return nil }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let operation, !operation.isCancelled else { return }
            var thumbnail: CGImage?
            if (try? FileIdentity.read(item.url)) == item.identity,
               let source = CGImageSourceCreateWithURL(item.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            guard !operation.isCancelled, (try? FileIdentity.read(item.url)) == item.identity else { return }
            let result = thumbnail
            Task { @MainActor [weak self] in
                guard !operation.isCancelled, let self else { return }
                let image = result.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                self.cache.setObject(Entry(image), forKey: key as NSString, cost: result.map { $0.bytesPerRow * $0.height } ?? 1)
                completion(image)
            }
        }
        queue.addOperation(operation); return operation
    }
    func cancelPending() { queue.cancelAllOperations() }
}
