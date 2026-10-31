import Foundation
import Darwin
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct FileDropTests {
    @Test func sameVolumeAndExternalDefaultsRespectSourcePermissions() throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try FileReference.capture(f.file("source.txt")), destination = try FileReference.capture(f.folder("target"))
        #expect(FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: true, permitsCopy: true, permitsMove: true, intent: .automatic) == .move)
        #expect(FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: false, permitsCopy: true, permitsMove: true, intent: .automatic) == .copy)
        #expect(FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: true, permitsCopy: true, permitsMove: false, intent: .automatic) == .copy)
        #expect(FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: true, permitsCopy: false, permitsMove: true, intent: .copy) == nil)
        #expect(FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: true, permitsCopy: false, permitsMove: false, intent: .automatic) == nil)
    }
    @Test func crossVolumeDefaultsToCopyAndRejectsForcedMove() throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try FileReference.capture(f.file("source.txt")), destination = try FileReference.capture(f.folder("target"))
        let id = try #require(source.identity)
        let different = FileIdentity(device: id.device &+ 1, inode: id.inode, birthSeconds: id.birthSeconds, birthNanoseconds: id.birthNanoseconds, mode: id.mode)
        let otherVolume = FileReference(url: source.url, identity: different)
        #expect(FileDropPolicy.operation(sources: [otherVolume], destination: destination, internalDrag: true, permitsCopy: true, permitsMove: true, intent: .automatic) == .copy)
        #expect(FileDropPolicy.operation(sources: [otherVolume], destination: destination, internalDrag: true, permitsCopy: true, permitsMove: true, intent: .move) == nil)
    }
    @Test func sameFolderMoveIsNoOpButCopyRemainsAvailable() throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let source = try FileReference.capture(f.file("source.txt")), destination = try FileReference.capture(f.root)
        #expect(FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: true, permitsCopy: true, permitsMove: true, intent: .automatic) == nil)
        #expect(FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: true, permitsCopy: true, permitsMove: true, intent: .copy) == .copy)
    }
    @Test func selfDescendantsNonDirectoriesAndNonFileURLsAreRejected() throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let parent = try FileReference.capture(f.folder("parent")), child = try FileReference.capture(f.folder("parent/child"))
        let lookalike = try FileReference.capture(f.folder("parent-other")), file = try FileReference.capture(f.file("file.txt"))
        func plan(_ source: FileReference, _ destination: FileReference) -> FileOperationKind? {
            FileDropPolicy.operation(sources: [source], destination: destination, internalDrag: true, permitsCopy: true, permitsMove: true, intent: .automatic)
        }
        #expect(plan(parent, parent) == nil); #expect(plan(parent, child) == nil)
        #expect(plan(parent, lookalike) == .move); #expect(plan(parent, file) == nil)
        #expect(plan(FileReference(url: URL(string: "https://example.com/file")!, identity: nil), child) == nil)
        #expect(plan(FileReference(url: URL(string: "file://remote-host/tmp/file")!, identity: nil), child) == nil)
        #expect(plan(FileReference(url: URL(string: "file:///tmp/file%00suffix")!, identity: nil), child) == nil)
    }
}
