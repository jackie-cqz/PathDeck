import Foundation

public struct FileCreationStamp: Codable, Equatable, Sendable {
    public let modified: Date?
    public let bytes: UInt64
    public static func capture(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Self(modified: attributes[.modificationDate] as? Date, bytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
    }
}
public struct FileUndoStep: Codable, Equatable, Sendable {
    public let current: FileReference
    public let originalParent: FileReference?
    public let originalName: String?
    public let creation: FileCreationStamp?
    public init(current: FileReference, originalParent: FileReference? = nil, originalName: String? = nil, creation: FileCreationStamp? = nil) {
        self.current = current; self.originalParent = originalParent; self.originalName = originalName; self.creation = creation
    }
}

@MainActor
public final class FileUndoHistory {
    public struct Entry: Sendable {
        public let id: UUID
        public let title: String
        public var steps: [FileUndoStep]
    }
    public private(set) var entries: [Entry] = []
    public var latest: Entry? { entries.last }
    public init() {}
    public func consume(_ record: FileOperationRecord) {
        if let original = record.request.undoOf {
            guard let index = entries.firstIndex(where: { $0.id == original }) else { return }
            let restored = Set(record.results.filter { $0.outcome == .succeeded }.compactMap(\.source))
            entries[index].steps.removeAll { restored.contains($0.current.url) }
            if entries[index].steps.isEmpty { entries.remove(at: index) }
        } else {
            let steps = record.results.filter { $0.outcome == .succeeded }.compactMap(\.undoStep).reversed()
            guard !steps.isEmpty, !entries.contains(where: { $0.id == record.id }) else { return }
            let name = steps.count == 1 ? "“\(steps.first!.current.url.lastPathComponent)”" : "（\(steps.count) 项）"
            entries.append(Entry(id: record.id, title: record.request.kind.title + name, steps: Array(steps)))
            if entries.count > 50 { entries.removeFirst(entries.count - 50) }
        }
    }
    public func recover(_ records: [FileOperationRecord]) {
        entries = []
        for record in records.sorted(by: { $0.createdAt < $1.createdAt }) { consume(record) }
    }
    public func request() -> FileOperationRequest? {
        guard let latest else { return nil }
        return FileOperationRequest(kind: .undo, sources: latest.steps.map(\.current), undoSteps: latest.steps, undoOf: latest.id)
    }
}
