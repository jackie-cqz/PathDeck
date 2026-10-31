import Foundation

public struct FileSort: Codable, Equatable, Sendable {
    public enum Column: String, Codable, Sendable { case name, modified, kind, size }
    public var column: Column
    public var ascending: Bool
    public init(column: Column = .name, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    public func apply(to items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if (a.kind == .directory) != (b.kind == .directory) { return a.kind == .directory }
            let order: ComparisonResult
            switch column {
            case .name: order = a.displayName.localizedStandardCompare(b.displayName)
            case .kind: order = a.typeDescription.localizedStandardCompare(b.typeDescription)
            case .modified: order = compare(a.modificationDate ?? .distantPast, b.modificationDate ?? .distantPast)
            case .size: order = compare(a.byteCount ?? -1, b.byteCount ?? -1)
            }
            if order == .orderedSame { return a.url.path < b.url.path }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
}
