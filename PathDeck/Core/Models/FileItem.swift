import Foundation

/// A metadata snapshot, with no file-system access in its initializer.
public struct FileItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case directory, regularFile, package, symbolicLink, other
    }

    // URL identifies a row; the captured identity reconciles external renames
    // and detects path replacement before writing.
    public var id: URL { url }
    public let url: URL
    public var realName: String { url.lastPathComponent }
    public let displayName: String
    public let kind: Kind
    public let modificationDate: Date?
    public let byteCount: Int64?
    public let typeDescription: String
    public let isHidden: Bool
    public let identity: FileIdentity?
    public var reference: FileReference { FileReference(url: url, identity: identity) }

    public init(
        url: URL,
        displayName: String,
        kind: Kind,
        modificationDate: Date? = nil,
        byteCount: Int64? = nil,
        typeDescription: String = "",
        isHidden: Bool = false,
        identity: FileIdentity? = nil
    ) {
        self.url = url
        self.displayName = displayName
        self.kind = kind
        self.modificationDate = modificationDate
        self.byteCount = byteCount
        self.typeDescription = typeDescription
        self.isHidden = isHidden
        self.identity = identity
    }
}

