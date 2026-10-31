import Foundation

/// Per-window UI state. Only the newest matching request may commit a directory.
@MainActor
public final class BrowserSession {
    public enum ContentState: Equatable, Sendable {
        case notLoaded
        case loading(URL)
        case loaded
        case failed(String)
    }

    public struct NavigationRequest: Equatable, Sendable {
        public let id: UUID
        public let generation: UInt64
        public let directory: URL
        public let mode: NavigationMode
    }

    public enum NavigationMode: Equatable, Sendable { case visit, refresh, history(Int) }
    public struct Location: Sendable {
        public var directory: URL
        public var selection: Set<URL> = []
        public var scrollAnchor: URL?
        public var sort = FileSort()
    }

    public private(set) var currentDirectory: URL
    public private(set) var directoryReference: FileReference?
    public private(set) var items: [FileItem] = []
    public private(set) var visibleItems: [FileItem] = []
    public private(set) var filterQuery = ""
    public private(set) var contentState: ContentState = .notLoaded
    public private(set) var generation: UInt64 = 0
    public private(set) var history: [Location] = []
    public private(set) var historyIndex = -1
    public var sort = FileSort()
    public var selection: Set<URL> = []
    public var scrollAnchor: URL?
    public var showHidden = false
    public var onChange: (() -> Void)?
    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex + 1 < history.count }
    public var isLoading: Bool { if case .loading = contentState { true } else { false } }
    private var pendingRequest: NavigationRequest?

    public init(initialDirectory: URL) {
        currentDirectory = initialDirectory
    }

    /// Preparing navigation does not change the committed location or its rows.
    public func beginNavigation(to directory: URL, mode: NavigationMode = .visit) -> NavigationRequest {
        if history.indices.contains(historyIndex) {
            history[historyIndex] = Location(directory: currentDirectory, selection: selection, scrollAnchor: scrollAnchor, sort: sort)
        }
        generation += 1
        let request = NavigationRequest(id: UUID(), generation: generation, directory: directory, mode: mode)
        pendingRequest = request
        contentState = .loading(directory)
        onChange?()
        return request
    }

    /// Return false for a result belonging to an older request or another window.
    @discardableResult
    public func completeNavigation(_ request: NavigationRequest, directory: URL? = nil, items: [FileItem], selectedURL: URL? = nil, reference: FileReference? = nil) -> Bool {
        guard pendingRequest == request else { return false }
        let destination = directory ?? request.directory
        if (request.mode != .refresh && destination.path != currentDirectory.path) || selectedURL != nil { filterQuery = "" }
        switch request.mode {
        case .history(let index) where history.indices.contains(index):
            historyIndex = index
            selection = history[index].selection
            scrollAnchor = history[index].scrollAnchor
            sort = history[index].sort
        case .refresh:
            let identities = Set(self.items.filter { selection.contains($0.url) }.compactMap(\.identity))
            let anchorIdentity = self.items.first(where: { $0.url == scrollAnchor })?.identity
            selection = Set(items.filter { item in
                if let identity = item.identity { return identities.contains(identity) }
                return selection.contains(item.url)
            }.map(\.url))
            if let anchorIdentity { scrollAnchor = items.first(where: { $0.identity == anchorIdentity })?.url }
            break
        default:
            if historyIndex < 0 || destination.path != currentDirectory.path {
                history = Array(history.prefix(historyIndex + 1))
                history.append(Location(directory: destination))
                if history.count > 50 { history.removeFirst(history.count - 50) }
                historyIndex = history.count - 1
                selection = []; scrollAnchor = nil
            }
        }
        currentDirectory = destination
        directoryReference = reference
        self.items = sort.apply(to: items)
        if history.indices.contains(historyIndex) { history[historyIndex].directory = destination }
        selection.formIntersection(Set(items.map(\.url)))
        if let selectedURL { selection = [selectedURL] }
        applyFilter()
        contentState = .loaded
        pendingRequest = nil
        onChange?()
        return true
    }

    /// Failure keeps the last committed directory and data intact.
    @discardableResult
    public func failNavigation(_ request: NavigationRequest, message: String) -> Bool {
        guard pendingRequest == request else { return false }
        contentState = .failed(message)
        pendingRequest = nil
        onChange?()
        return true
    }

    public func changeSort(_ value: FileSort) {
        sort = value
        items = sort.apply(to: items)
        applyFilter()
        onChange?()
    }
    public func setFilter(_ query: String) {
        guard query != filterQuery else { return }
        filterQuery = query; applyFilter(); onChange?()
    }
    private func applyFilter() {
        visibleItems = filterQuery.isEmpty ? items : items.filter {
            $0.realName.range(of: filterQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil || $0.displayName.range(of: filterQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let visible = Set(visibleItems.map(\.url)); selection.formIntersection(visible)
        if let scrollAnchor, !visible.contains(scrollAnchor) { self.scrollAnchor = nil }
    }
    public func clearHistory() {
        history = [Location(directory: currentDirectory, selection: selection, scrollAnchor: scrollAnchor, sort: sort)]; historyIndex = 0
    }
    public func restoreViewState(_ state: BrowserPageSnapshot) {
        guard contentState == .loaded, currentDirectory.path == state.directory else { return }
        sort = state.sort; items = sort.apply(to: items); filterQuery = state.filter
        let identities = Set(state.selection.compactMap(\.identity))
        selection = Set(items.filter { $0.identity.map(identities.contains) == true }.map(\.url))
        scrollAnchor = state.anchor?.identity.flatMap { identity in items.first { $0.identity == identity }?.url }
        applyFilter(); onChange?()
    }
}

