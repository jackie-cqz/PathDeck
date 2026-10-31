import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct PathInputParserTests {
    let base = URL(fileURLWithPath: "/example/current", isDirectory: true)
    let parser = PathInputParser(home: URL(fileURLWithPath: "/example/home", isDirectory: true))

    @Test(arguments: ["/tmp/a", "~/Downloads", "~/Desktop", "~", "～/Desktop", "～", "../Assets", "./src", "child"])
    func supportedForms(_ input: String) throws {
        let expected = ["/tmp/a": "/tmp/a", "~/Downloads": "/example/home/Downloads", "~/Desktop": "/example/home/Desktop", "~": "/example/home", "～/Desktop": "/example/home/Desktop", "～": "/example/home", "../Assets": "/example/Assets", "./src": "/example/current/src", "child": "/example/current/child"]
        #expect(try parser.parse(input, relativeTo: base).standardizedFileURL.path == expected[input])
    }
    @Test(arguments: ["中文 文件😀", "a'\";$(touch nope)`id`", "a%20b#c?d", " leading trailing ", "name:part", "file:notes", "a\\b"])
    func treatsNamesLiterally(_ input: String) throws {
        #expect(try parser.parse(input, relativeTo: base).lastPathComponent == input)
    }
    @Test func fileURLDecodesOnlyOnce() throws {
        #expect(try parser.parse("file:///tmp/a%2520b", relativeTo: base).path == "/tmp/a%20b")
        #expect(try parser.parse("file://localhost/tmp/hello%20world", relativeTo: base).path == "/tmp/hello world")
    }
    @Test(arguments: ["", "C:\\Users\\alex", "\\\\server\\share", "https://example.com", "smb://server/share", "file://remote/tmp/a", "~otheruser/a", "bad\0name", "/tmp/a\n", "file:///tmp/a?query"])
    func rejectsUnsupportedInputs(_ input: String) {
        #expect(throws: (any Error).self) { try parser.parse(input, relativeTo: base) }
    }
    @Test func completionHasCorrectParentAndPrefix() throws {
        let (parent, prefix) = try parser.completionParent("~/Down", relativeTo: base)
        #expect(parent.path == "/example/home"); #expect(prefix == "Down")
        let (directory, empty) = try parser.completionParent("~/Downloads/", relativeTo: base)
        #expect(directory.path == "/example/home/Downloads"); #expect(empty.isEmpty)
        let (wideParent, widePrefix) = try parser.completionParent("～/Des", relativeTo: base)
        #expect(wideParent.path == "/example/home"); #expect(widePrefix == "Des")
        let (wideHome, wideEmpty) = try parser.completionParent("～", relativeTo: base)
        #expect(wideHome.path == "/example/home"); #expect(wideEmpty.isEmpty)
    }
    @Test func fullWidthTildeElsewhereIsLiteral() throws {
        #expect(try parser.parse("./～/Desktop", relativeTo: base).standardizedFileURL.path == "/example/current/～/Desktop")
        #expect(try parser.parse("/tmp/～/Desktop", relativeTo: base).path == "/tmp/～/Desktop")
        #expect(try parser.parse("~/～/Desktop", relativeTo: base).path == "/example/home/～/Desktop")
        #expect(try parser.parse("～notes", relativeTo: base).lastPathComponent == "～notes")
    }
    @Test @MainActor func bothHomeFormsNavigateToRealDesktopFixture() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let desktop = try f.folder("Desktop"); let file = try f.file("Desktop/note.txt")
        let session = BrowserSession(initialDirectory: f.root)
        let navigation = NavigationCoordinator(session: session, parser: PathInputParser(home: f.root))
        for input in ["~/Desktop", "～/Desktop"] {
            #expect(await navigation.navigate(input: input))
            #expect(session.currentDirectory.path == desktop.path)
            #expect(session.items.map(\.url) == [file])
        }
    }
}
