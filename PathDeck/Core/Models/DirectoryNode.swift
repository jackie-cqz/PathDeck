import Foundation

/// A location in a sidebar branch, distinct from the identity of a disk object.
public struct DirectoryNode: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let branch: String
        public let url: URL

        public init(branch: String, url: URL) {
            self.branch = branch
            self.url = url
        }
    }

    public enum LoadState: Equatable, Sendable {
        case notLoaded
        case loading
        case loaded
        case failed(String)
    }

    public var id: ID { ID(branch: branch, url: url) }
    public let branch: String
    public let url: URL
    public let displayName: String
    public var loadState: LoadState
    public var children: [DirectoryNode]

    public init(
        branch: String,
        url: URL,
        displayName: String,
        loadState: LoadState = .notLoaded,
        children: [DirectoryNode] = []
    ) {
        self.branch = branch
        self.url = url
        self.displayName = displayName
        self.loadState = loadState
        self.children = children
    }
}

