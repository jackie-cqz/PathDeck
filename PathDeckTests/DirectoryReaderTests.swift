import Foundation
import Darwin
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

/// All mutations are confined to a unique disposable test directory.
struct DirectoryFixture {
    let root: URL
    init() throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("PathDeck-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        let physical = candidate.withUnsafeFileSystemRepresentation { realpath($0!, nil)! }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name); try Data("real file".utf8).write(to: url); return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct DirectoryReaderTests {
    @Test func realDirectoryHasMetadataAndHidesDotfiles() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        _ = try f.folder("Folder"); _ = try f.file("a10.txt"); _ = try f.file("a2.txt"); _ = try f.file(".secret")
        let reader = DirectoryReader()
        let listing = try await reader.read(f.root, showHidden: false)
        #expect(listing.items.map(\.realName) == ["Folder", "a2.txt", "a10.txt"])
        #expect(listing.items.first?.kind == .directory)
        #expect(listing.items[1].byteCount == 9)
        #expect(listing.items[1].modificationDate != nil)
        #expect(try await reader.read(f.root, showHidden: true).items.count == 4)
    }
    @Test func filePathSelectsItemAndDoesNotOpenIt() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let file = try f.file("文件 %#?.txt")
        let result = try await DirectoryReader().read(file, showHidden: false)
        #expect(result.directory.path == f.root.path)
        #expect(result.selectedURL?.path == file.path)
        #expect(result.items.contains { $0.url == result.selectedURL })
        #expect(result.items.map(\.realName) == [file.lastPathComponent])
    }
    @Test func linksRemainObjectsAndTreeDoesNotFollowThem() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let directory = try f.folder("real")
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let broken = f.root.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: f.root.appendingPathComponent("absent"))
        let reader = DirectoryReader()
        let listing = try await reader.read(f.root, showHidden: false)
        #expect(listing.items.first(where: { $0.realName == "link" })?.kind == .symbolicLink)
        #expect(listing.items.contains { $0.realName == "broken" })
        #expect(try await reader.childDirectories(f.root, showHidden: false).map(\.realName) == ["real"])
        #expect(try await reader.read(link, showHidden: false).directory.path == directory.path)
    }
    @Test func packageIsNotTraversedAsAnOrdinaryDirectory() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let package = try f.folder("Example.app")
        let listing = try await DirectoryReader().read(package, showHidden: false)
        #expect(listing.selectedURL?.lastPathComponent == "Example.app")
        #expect(listing.items.first?.kind == .package)
    }
    @Test func missingDirectoryFailsInsteadOfPretendingEmpty() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        await #expect(throws: (any Error).self) { try await DirectoryReader().read(f.root.appendingPathComponent("missing"), showHidden: false) }
    }
    @Test func descendingKeepsDirectoriesFirst() {
        let items = [FileItem(url: URL(fileURLWithPath: "/z.txt"), displayName: "z.txt", kind: .regularFile), FileItem(url: URL(fileURLWithPath: "/a"), displayName: "a", kind: .directory)]
        #expect(FileSort(ascending: false).apply(to: items).first?.kind == .directory)
    }
}
