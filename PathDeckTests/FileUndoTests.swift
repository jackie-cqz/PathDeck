import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite @MainActor struct FileUndoTests {
    private func make(_ root: URL, journal: URL? = nil) throws -> (FileOperationService, FileUndoHistory) {
        let sink = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: sink, withIntermediateDirectories: true)
        let engine = FileOperationEngine(journalDirectory: journal, trash: { url in
            let target = sink.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target); return target
        })
        let service = FileOperationService(engine: engine), history = FileUndoHistory()
        service.onComplete = { history.consume($0) }; return (service, history)
    }
    @Test func creationRenameAndMoveCanBeUndoneInOrder() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let (service, history) = try make(f.root)
        let parent = try FileReference.capture(f.folder("source")), target = try FileReference.capture(f.folder("target"))
        let create = await service.wait(for: service.submit(.init(kind: .newTextFile, destination: parent, name: "New.txt")))
        let created = try #require(create.results.first?.undoStep?.current)
        let renamed = await service.wait(for: service.submit(.init(kind: .rename, sources: [created], destination: parent, name: "Renamed.txt")))
        let moved = await service.wait(for: service.submit(.init(kind: .move, sources: [try #require(renamed.results.first?.undoStep?.current)], destination: target)))
        #expect(moved.successCount == 1); #expect(history.entries.count == 3)
        for expected in ["Renamed.txt", "New.txt"] {
            let undone = await service.wait(for: service.submit(try #require(history.request())))
            #expect(undone.successCount == 1); #expect(FileManager.default.fileExists(atPath: parent.url.appendingPathComponent(expected).path))
        }
        let removed = await service.wait(for: service.submit(try #require(history.request())))
        #expect(removed.successCount == 1); #expect(history.latest == nil)
        #expect(!FileManager.default.fileExists(atPath: parent.url.appendingPathComponent("New.txt").path))
        #expect(FileManager.default.fileExists(atPath: try #require(removed.results.first?.destination).path))
    }
    @Test(arguments: [FileOperationKind.newFolder, .newTextFile]) func modifiedCreationsAreKept(_ kind: FileOperationKind) async throws {
        let f = try DirectoryFixture(); defer { f.remove() }; let (service, history) = try make(f.root)
        let created = await service.wait(for: service.submit(.init(kind: kind, destination: try .capture(f.root), name: "Created")))
        let url = try #require(created.results.first?.destination)
        let content = kind == .newFolder ? url.appendingPathComponent("user.txt") : url
        try Data("keep user changes".utf8).write(to: content)
        let undo = await service.wait(for: service.submit(try #require(history.request())))
        #expect(undo.failureCount == 1); #expect(history.latest != nil)
        #expect(try String(contentsOf: content, encoding: .utf8) == "keep user changes")
    }
    @Test func originalNameCollisionDoesNotOverwriteOrInventNewName() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }; let (service, history) = try make(f.root)
        let source = try FileReference.capture(f.file("file.txt")), target = try FileReference.capture(f.folder("target"))
        _ = await service.wait(for: service.submit(.init(kind: .move, sources: [source], destination: target)))
        try Data("occupant".utf8).write(to: source.url)
        var conflicts = 0; service.resolveConflict = { _ in conflicts += 1; return ConflictDecision(.keepBoth) }
        let undone = await service.wait(for: service.submit(try #require(history.request())))
        #expect(undone.failureCount == 1); #expect(conflicts == 0); #expect(history.latest != nil)
        #expect(try String(contentsOf: source.url, encoding: .utf8) == "occupant")
        #expect(try String(contentsOf: target.url.appendingPathComponent("file.txt"), encoding: .utf8) == "real file")
    }
    @Test func partialUndoCanRetryOnlyRemainingSteps() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }; let (service, history) = try make(f.root)
        let a = try FileReference.capture(f.file("a.txt")), b = try FileReference.capture(f.file("b.txt")), target = try FileReference.capture(f.folder("target"))
        _ = await service.wait(for: service.submit(.init(kind: .move, sources: [a, b], destination: target)))
        try Data("occupied".utf8).write(to: a.url)
        let first = await service.wait(for: service.submit(try #require(history.request())))
        #expect(first.successCount == 1); #expect(first.failureCount == 1); #expect(history.latest?.steps.count == 1)
        try FileManager.default.removeItem(at: a.url)
        let retry = await service.wait(for: service.submit(try #require(history.request())))
        #expect(retry.successCount == 1); #expect(history.latest == nil)
        #expect(try FileIdentity.read(a.url) == a.identity); #expect(try FileIdentity.read(b.url) == b.identity)
    }
    @Test func movedReplacementIsNotUndoneAndHistorySurvivesFreshJournalRead() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }; let journal = f.root.appendingPathComponent("journal")
        let (service, _) = try make(f.root, journal: journal)
        let source = try FileReference.capture(f.file("file.txt")), target = try FileReference.capture(f.folder("target"))
        let record = await service.wait(for: service.submit(.init(kind: .move, sources: [source], destination: target)))
        let current = try #require(record.results.first?.destination)
        let fresh = FileOperationService(engine: FileOperationEngine(journalDirectory: journal)); try await fresh.recover()
        let history = FileUndoHistory(); history.recover(fresh.records); #expect(history.latest != nil)
        try FileManager.default.moveItem(at: current, to: target.url.appendingPathComponent("kept.txt")); try Data("replacement".utf8).write(to: current)
        let undo = await fresh.wait(for: fresh.submit(try #require(history.request())))
        #expect(undo.failureCount == 1); #expect(try String(contentsOf: current, encoding: .utf8) == "replacement")
        #expect(!FileManager.default.fileExists(atPath: source.url.path))
    }
    @Test func caseOnlyRenameUndoUsesOneJournalRecordPerTask() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }; let journal = f.root.appendingPathComponent("journal")
        let (service, history) = try make(f.root, journal: journal), source = try FileReference.capture(f.file("Case.txt"))
        _ = await service.wait(for: service.submit(.init(kind: .rename, sources: [source], destination: try .capture(f.root), name: "case.txt")))
        let undone = await service.wait(for: service.submit(try #require(history.request())))
        #expect(undone.successCount == 1); #expect(try FileIdentity.read(source.url) == source.identity)
        let records = try await FileOperationEngine(journalDirectory: journal).recover()
        #expect(records.count == 2); #expect(records.allSatisfy { $0.state == .completed })
    }
}
