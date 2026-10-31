import Foundation
import Darwin
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct FileOperationTests {
    @MainActor private func run(_ request: FileOperationRequest, service: FileOperationService = FileOperationService()) async -> FileOperationRecord { await service.wait(for: service.submit(request)) }
    private func ref(_ url: URL) throws -> FileReference { try FileReference.capture(url) }

    @Test @MainActor func createRenameAndDuplicateNameDoNotOverwrite() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let target = try ref(f.root)
        let service = FileOperationService()
        let folder = await run(.init(kind: .newFolder, destination: target, name: "新建目录"), service: service)
        #expect(folder.successCount == 1)
        let file = await run(.init(kind: .newTextFile, destination: target, name: "note.txt"), service: service)
        let source = try #require(file.results.first?.destination)
        #expect(try Data(contentsOf: source).isEmpty)
        let duplicate = await run(.init(kind: .newTextFile, destination: target, name: "note.txt"), service: service)
        #expect(duplicate.results.first?.destination?.lastPathComponent == "note (2).txt")
        let renamed = await run(.init(kind: .rename, sources: [try ref(source)], destination: target, name: "renamed.txt"), service: service)
        #expect(renamed.successCount == 1); #expect(!FileManager.default.fileExists(atPath: source.path))
        let blocked = await run(.init(kind: .rename, sources: [try ref(renamed.results[0].destination!)], destination: target, name: "note (2).txt"), service: service)
        #expect(blocked.failureCount == 1); #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("renamed.txt").path))
    }
    @Test(arguments: ["", ".", "..", "../escape", "a/b", "bad\0name"])
    @MainActor func invalidCreationNameLeavesDirectoryUntouched(_ name: String) async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let record = await run(.init(kind: .newTextFile, destination: try ref(f.root), name: name))
        #expect(record.failureCount == 1); #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }
    @Test @MainActor func copyPreservesContentsMetadataAndLinks() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let destination = try f.folder("destination"); let source = try f.file("source.txt")
        let attribute = Data("pathdeck-metadata".utf8)
        let set = attribute.withUnsafeBytes { setxattr(source.path, "com.pathdeck.test", $0.baseAddress, $0.count, 0, 0) }
        #expect(set == 0)
        let service = FileOperationService()
        let copied = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(destination)), service: service)
        #expect(copied.successCount == 1)
        let output = try #require(copied.results.first?.destination)
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = getxattr(output.path, "com.pathdeck.test", &bytes, bytes.count, 0, 0)
        #expect(count == attribute.count); #expect(Data(bytes.prefix(max(count, 0))) == attribute)
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let linkCopy = await run(.init(kind: .copy, sources: [try ref(link)], destination: try ref(destination)), service: service)
        #expect(linkCopy.successCount == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("link").path) == source.path)
        #expect(copied.artifacts.isEmpty)
    }
    @Test @MainActor func conflictsSkipKeepBothAndNeverMerge() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("same.txt"); let destination = try f.folder("target")
        try Data("existing".utf8).write(to: destination.appendingPathComponent("same.txt"))
        let service = FileOperationService()
        let skip = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(destination)), service: service)
        #expect(skip.skippedCount == 1)
        service.resolveConflict = { _ in ConflictDecision(.keepBoth, applyToRemaining: true) }
        let copy = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(destination)), service: service)
        #expect(copy.results.first?.destination?.lastPathComponent == "same (2).txt")
        #expect(try String(contentsOf: destination.appendingPathComponent("same.txt"), encoding: .utf8) == "existing")
        let folder = try f.folder("Folder"); try Data().write(to: folder.appendingPathComponent("inside"))
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        service.resolveConflict = { _ in ConflictDecision(.skip) }
        let dir = await run(.init(kind: .copy, sources: [try ref(folder)], destination: try ref(destination)), service: service)
        #expect(dir.skippedCount == 1); #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Folder").path).isEmpty)
    }
    @Test @MainActor func moveSameVolumeAndSameDirectoryNoOp() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("move.txt"); let destination = try f.folder("target")
        let reference = try ref(source)
        let noOp = await run(.init(kind: .move, sources: [reference], destination: try ref(f.root)))
        #expect(noOp.successCount == 1); #expect(try FileIdentity.read(source) == reference.identity)
        let moved = await run(.init(kind: .move, sources: [reference], destination: try ref(destination)))
        #expect(moved.successCount == 1); #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try FileIdentity.read(destination.appendingPathComponent("move.txt")) == reference.identity)
    }
    @Test @MainActor func descendantTargetsAndReplacedSourceAreRejected() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.folder("folder"); let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let descendant = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(nested)))
        #expect(descendant.failureCount == 1)
        let file = try f.file("item"); let captured = try ref(file)
        // Keep the old inode alive so this is deterministically a different object.
        try FileManager.default.moveItem(at: file, to: f.root.appendingPathComponent("old"))
        try Data("replacement".utf8).write(to: file)
        let renamed = await run(.init(kind: .rename, sources: [captured], destination: try ref(f.root), name: "wrong"))
        #expect(renamed.failureCount == 1); #expect(try String(contentsOf: file, encoding: .utf8) == "replacement")
    }
    @Test @MainActor func lateConflictCannotOverwriteAndKeepsStagingInspectable() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("source"); let destination = try f.folder("target")
        let engine = FileOperationEngine(beforeCommit: { url in try Data("arrived later".utf8).write(to: url, options: .withoutOverwriting) })
        let record = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(destination)), service: FileOperationService(engine: engine))
        #expect(record.skippedCount == 1); #expect(!record.artifacts.isEmpty)
        #expect(try String(contentsOf: destination.appendingPathComponent("source"), encoding: .utf8) == "arrived later")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
    @Test @MainActor func queuedCancellationAndTrashFailurePreserveSource() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let file = try f.file("keep")
        let service = FileOperationService(engine: FileOperationEngine(trash: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }))
        let request = FileOperationRequest(kind: .trash, sources: [try ref(file)])
        let id = service.submit(request); service.cancel(id)
        #expect(await service.wait(for: id).state == .cancelled)
        let failed = await run(.init(kind: .trash, sources: [try ref(file)]), service: service)
        #expect(failed.failureCount == 1); #expect(FileManager.default.fileExists(atPath: file.path))
    }
    @Test @MainActor func cancellationAfterCopyDoesNotDeleteSourceOrCommitPayload() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("keep"); let target = try f.folder("target"); let token = OperationCancellation()
        let engine = FileOperationEngine(beforeCommit: { _ in token.cancel() })
        // beforeCommit cancellation is checked immediately before the exclusive commit.
        let record = FileOperationRecord(request: .init(kind: .copy, sources: [try ref(source)], destination: try ref(target)))
        let step = await engine.execute(record, source: try ref(source), name: "keep", cancellation: token)
        #expect(step.result?.outcome == .cancelled); #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("keep").path))
    }
    @Test @MainActor func caseOnlyRenamePreservesIdentity() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("case.txt"); let reference = try ref(source)
        let result = await run(.init(kind: .rename, sources: [reference], destination: try ref(f.root), name: "CASE.txt"))
        #expect(result.successCount == 1); #expect(result.artifacts.isEmpty)
        #expect(try FileIdentity.read(f.root.appendingPathComponent("CASE.txt")) == reference.identity)
    }
    @Test @MainActor func recoveryMarksInterruptedRecordsAndDoesNotReplay() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let journal = try f.folder("journal"); let engine = FileOperationEngine(journalDirectory: journal)
        var record = FileOperationRecord(request: .init(kind: .newTextFile, destination: try ref(f.root), name: "never-replay"))
        record.state = .running; try await engine.persist(record)
        let recovered = try await engine.recover()
        #expect(recovered.first?.state == .interruptedUnknown)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("never-replay").path))
    }
    @Test @MainActor func directoryPackageCopiesAreWholeAndDoNotFollowLinks() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.folder("Sample.app/Contents").deletingLastPathComponent()
        let inside = source.appendingPathComponent("Contents/Info.txt")
        try Data("package data".utf8).write(to: inside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("loop"), withDestinationURL: source)
        let target = try f.folder("target")
        let result = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(target)))
        #expect(result.successCount == 1)
        #expect(try Data(contentsOf: target.appendingPathComponent("Sample.app/Contents/Info.txt")) == Data(contentsOf: inside))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("Sample.app/loop").path) == source.path)
    }
    @Test @MainActor func partialBatchContinuesAndReportsEachResult() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let good = try f.file("good"); let missing = try f.file("missing"); let stale = try ref(missing)
        try FileManager.default.removeItem(at: missing)
        let target = try f.folder("target")
        let result = await run(.init(kind: .copy, sources: [stale, try ref(good)], destination: try ref(target)))
        #expect(result.state == .completedWithErrors); #expect(result.failureCount == 1); #expect(result.successCount == 1)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("good").path))
        #expect(FileManager.default.fileExists(atPath: good.path))
    }
    @Test @MainActor func destinationReplacedAfterCaptureIsNotUsed() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let target = try f.folder("target"); let captured = try ref(target)
        try FileManager.default.moveItem(at: target, to: f.root.appendingPathComponent("old-target"))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let result = await run(.init(kind: .newTextFile, destination: captured, name: "must-not-create"))
        #expect(result.failureCount == 1); #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @Test @MainActor func diskFullAtCommitLeavesOriginalAndInspectablePartialCopy() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("source"); let target = try f.folder("target")
        let engine = FileOperationEngine(beforeCommit: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
        let result = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(target)), service: FileOperationService(engine: engine))
        #expect(result.failureCount == 1); #expect(!result.artifacts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path)); #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("source").path))
    }
    @Test @MainActor func renameCannotBecomeAMoveByChangingDestination() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("source"); let target = try f.folder("other")
        let result = await run(.init(kind: .rename, sources: [try ref(source)], destination: try ref(target), name: "renamed"))
        #expect(result.failureCount == 1); #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @Test func systemDeviceIdentityAcceptsSignedDeviceNumbers() throws {
        let reference = try FileReference.capture(URL(fileURLWithPath: "/dev", isDirectory: true))
        #expect(reference.identity != nil)
    }
    @Test @MainActor func crossVolumeMoveIsRejectedBeforeAnyMutation() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("keep")
        let target = URL(fileURLWithPath: "/dev", isDirectory: true)
        let a = try ref(source); let b = try ref(target)
        #expect(a.identity?.device != b.identity?.device)
        let result = await run(.init(kind: .move, sources: [a], destination: b))
        #expect(result.failureCount == 1)
        #expect(result.results.first?.message.contains("同卷") == true)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
    @Test @MainActor func movingAndTrashingLinksNeverMutatesTheirTarget() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let target = try f.file("target"); let directory = try f.folder("destination")
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let moved = await run(.init(kind: .move, sources: [try ref(link)], destination: try ref(directory)))
        let movedLink = try #require(moved.results.first?.destination)
        let fakeTrash = f.root.appendingPathComponent("trashed-link")
        let service = FileOperationService(engine: FileOperationEngine(trash: { url in
            try FileManager.default.moveItem(at: url, to: fakeTrash); return fakeTrash
        }))
        let trashed = await run(.init(kind: .trash, sources: [try ref(movedLink)]), service: service)
        #expect(trashed.successCount == 1); #expect(try Data(contentsOf: target) == Data("real file".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fakeTrash.path) == target.path)
    }
    @Test @MainActor func dotInDirectoryNameIsNotTreatedAsAnExtension() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.folder("Folder.v1"); let target = try f.folder("target")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Folder.v1"), withIntermediateDirectories: false)
        let service = FileOperationService(); service.resolveConflict = { _ in ConflictDecision(.keepBoth) }
        let result = await run(.init(kind: .copy, sources: [try ref(source)], destination: try ref(target)), service: service)
        #expect(result.results.first?.destination?.lastPathComponent == "Folder.v1 (2)")
    }
    @Test @MainActor func existingHardLinkNameDoesNotOverwriteAndRollbackIsClean() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try f.file("source"); let other = f.root.appendingPathComponent("other")
        try FileManager.default.linkItem(at: source, to: other)
        let result = await run(.init(kind: .rename, sources: [try ref(source)], destination: try ref(f.root), name: "other"))
        #expect(result.failureCount == 1); #expect(result.artifacts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path)); #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(try Data(contentsOf: source) == Data(contentsOf: other))
    }
}
