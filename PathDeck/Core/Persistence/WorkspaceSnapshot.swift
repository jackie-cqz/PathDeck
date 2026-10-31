import Foundation

public struct BrowserPageSnapshot: Codable, Equatable, Sendable {
    public var directory: String
    public var selection: [FileReference]
    public var anchor: FileReference?
    public var filter: String
    public var sort: FileSort
    public var showHidden: Bool
    public var columns: [ColumnPreference]
    public var sidebarWidth: Double
    public var fileViewMode: FileViewMode?
    public init(directory: String, selection: [FileReference] = [], anchor: FileReference? = nil, filter: String = "", sort: FileSort = FileSort(), showHidden: Bool = false, columns: [ColumnPreference] = AppPreferences().columns, sidebarWidth: Double = 240, fileViewMode: FileViewMode? = nil) {
        self.directory = directory; self.selection = selection; self.anchor = anchor; self.filter = filter; self.sort = sort; self.showHidden = showHidden; self.columns = columns; self.sidebarWidth = sidebarWidth
        self.fileViewMode = fileViewMode
    }
    public func sanitized() -> Self? {
        guard directory.hasPrefix("/"), !directory.contains("\0") else { return nil }
        var result = self, preferences = AppPreferences()
        preferences.columns = columns; preferences.sidebarWidth = sidebarWidth
        result.columns = preferences.sanitized().columns; result.sidebarWidth = preferences.sanitized().sidebarWidth
        result.filter = String(filter.prefix(4096))
        result.selection = Array(selection.filter { $0.url.isFileURL && $0.identity != nil && !$0.url.path.contains("\0") }.prefix(10_000))
        return result
    }
}
public struct WindowGroupSnapshot: Codable, Equatable, Sendable {
    public var pages: [BrowserPageSnapshot]
    public var selectedIndex: Int
    public var frame: WindowPlacement?
    public init(pages: [BrowserPageSnapshot], selectedIndex: Int = 0, frame: WindowPlacement? = nil) { self.pages = pages; self.selectedIndex = selectedIndex; self.frame = frame }
}
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var groups: [WindowGroupSnapshot]
    public var activeGroup: Int
    public init(groups: [WindowGroupSnapshot], activeGroup: Int = 0) { self.groups = groups; self.activeGroup = activeGroup }
    public func sanitized() -> Self? {
        guard schemaVersion == 1 else { return nil }
        var result = self, remaining = 512
        result.groups = groups.prefix(64).compactMap { group in
            var group = group
            group.pages = Array(group.pages.compactMap { $0.sanitized() }.prefix(remaining)); remaining -= group.pages.count
            guard !group.pages.isEmpty else { return nil }
            group.selectedIndex = min(max(0, group.selectedIndex), group.pages.count - 1)
            var p = AppPreferences(); p.window = group.frame; group.frame = p.sanitized().window
            return group
        }
        result.activeGroup = min(max(0, activeGroup), max(0, result.groups.count - 1))
        return result
    }
}
