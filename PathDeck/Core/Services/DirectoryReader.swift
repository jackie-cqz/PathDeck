import Foundation
import Darwin

public struct DirectoryListing: Sendable {
    public let directory: URL
    public let items: [FileItem]
    public let selectedURL: URL?
    public let reference: FileReference?
    public init(directory: URL, items: [FileItem], selectedURL: URL? = nil, reference: FileReference? = nil) {
        self.directory = directory; self.items = items; self.selectedURL = selectedURL; self.reference = reference
    }
}

public protocol DirectoryReading: Sendable {
    func read(_ target: URL, showHidden: Bool) async throws -> DirectoryListing
}

/// Blocking Foundation calls run on a bounded IO queue, never on MainActor.
public final class DirectoryReader: DirectoryReading, @unchecked Sendable {
    private let queue: OperationQueue
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .localizedNameKey,
        .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey, .isHiddenKey,
    ]

    public init() {
        queue = OperationQueue()
        queue.name = "local.pathdeck.directory-io"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }

    public func read(_ target: URL, showHidden: Bool) async throws -> DirectoryListing {
        try await perform {
            guard target.isFileURL else { throw PathInputError.unsupportedURL }
            let resolved = target.resolvingSymlinksInPath()
            let resolvedValues = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDirectory = resolvedValues.isDirectory == true && resolvedValues.isPackage != true
            let parent = isDirectory ? resolved : target.deletingLastPathComponent().resolvingSymlinksInPath()
            let directory = try Self.canonicalDirectory(parent)
            let items = try Self.enumerate(directory, showHidden: showHidden || !isDirectory)
            let selection = isDirectory ? nil : items.first(where: { $0.realName == target.lastPathComponent })?.url
            return DirectoryListing(directory: directory, items: items, selectedURL: selection, reference: try FileReference.capture(directory))
        }
    }

    /// Enumerates direct child directories only; symlinks and packages aren't tree branches.
    public func childDirectories(_ parent: URL, showHidden: Bool) async throws -> [FileItem] {
        try await perform { try Self.enumerate(parent, showHidden: showHidden).filter { $0.kind == .directory } }
    }

    public func mountedVolumes() async throws -> [URL] {
        try await perform { FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] }
    }

    public func isBrowsableDirectory(_ target: URL) async throws -> Bool {
        try await perform {
            let values = try target.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values.isDirectory == true && values.isPackage != true
        }
    }

    private static func enumerate(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        let canonical = try canonicalDirectory(directory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: canonical, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return FileSort().apply(to: urls.map { url in
            // Metadata failure for an individual item must not discard the directory.
            let values = try? url.resourceValues(forKeys: keys)
            let kind: FileItem.Kind
            if values?.isSymbolicLink == true { kind = .symbolicLink }
            else if values?.isPackage == true { kind = .package }
            else if values?.isDirectory == true { kind = .directory }
            else { kind = .regularFile }
            return FileItem(
                url: URL(fileURLWithPath: url.path, isDirectory: kind == .directory), displayName: values?.localizedName ?? url.lastPathComponent, kind: kind,
                modificationDate: values?.contentModificationDate,
                byteCount: kind == .directory ? nil : values?.fileSize.map(Int64.init),
                typeDescription: values?.localizedTypeDescription ?? (kind == .directory ? "文件夹" : "文件"),
                isHidden: values?.isHidden ?? url.lastPathComponent.hasPrefix("."),
                identity: try? FileIdentity.read(url)
            )
        })
    }

    private static func canonicalDirectory(_ url: URL) throws -> URL {
        guard let pointer = url.withUnsafeFileSystemRepresentation({ path in path.flatMap { realpath($0, nil) } }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancellation = OperationCancellation()
        let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    do { continuation.resume(returning: try work()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return result
    }
}
