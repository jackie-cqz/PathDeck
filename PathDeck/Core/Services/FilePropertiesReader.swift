import Foundation
import Darwin

public struct FileProperties: Sendable {
    public let url: URL
    public let kind: String
    public let bytes: Int64?
    public let created: Date?
    public let modified: Date?
    public let permissions: String
    public let owner: String
    public let writable: Bool
    public let symbolicLink: String?
    public let error: String?
}

/// Direct metadata only: never recursively scans folders or follows links for sizes.
public final class FilePropertiesReader: @unchecked Sendable {
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .userInitiated; return q }()
    public init() {}
    public func read(_ urls: [URL]) async -> [FileProperties] {
        await withCheckedContinuation { continuation in queue.addOperation {
            let fm = FileManager.default
            let values = urls.map { url -> FileProperties in
                do {
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    let type = attributes[.type] as? FileAttributeType
                    let kind = type == .typeSymbolicLink ? "符号链接" : (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? (type == .typeDirectory ? "文件夹" : "文件")
                    let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                    return FileProperties(url: url, kind: kind, bytes: type == .typeDirectory ? nil : (attributes[.size] as? NSNumber)?.int64Value,
                        created: attributes[.creationDate] as? Date, modified: attributes[.modificationDate] as? Date,
                        permissions: String(format: "%04o", Int(mode)), owner: attributes[.ownerAccountName] as? String ?? "—",
                        writable: fm.isWritableFile(atPath: url.path), symbolicLink: type == .typeSymbolicLink ? try fm.destinationOfSymbolicLink(atPath: url.path) : nil, error: nil)
                } catch {
                    return FileProperties(url: url, kind: "不可用", bytes: nil, created: nil, modified: nil, permissions: "—", owner: "—", writable: false, symbolicLink: nil, error: error.localizedDescription)
                }
            }
            continuation.resume(returning: values)
        } }
    }
}
