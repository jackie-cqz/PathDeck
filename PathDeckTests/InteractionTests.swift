import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct InteractionTests {
    @Test func windowsShortcutsRespectModeAndTextFocus() {
        typealias M = BrowserShortcut.Modifiers
        #expect(BrowserShortcut.resolve(keyCode: 96, characters: nil, modifiers: [], windowsFriendly: true, editingText: false) == .refresh)
        #expect(BrowserShortcut.resolve(keyCode: 123, characters: nil, modifiers: .option, windowsFriendly: true, editingText: false) == .back)
        #expect(BrowserShortcut.resolve(keyCode: 45, characters: "N", modifiers: [.control, .shift], windowsFriendly: true, editingText: false) == .newFolder)
        #expect(BrowserShortcut.resolve(keyCode: 48, characters: nil, modifiers: [.control, .shift], windowsFriendly: true, editingText: false) == .previousTab)
        for key: UInt16 in [49, 51, 96, 117, 120, 123] {
            #expect(BrowserShortcut.resolve(keyCode: key, characters: "n", modifiers: [], windowsFriendly: true, editingText: true) == nil)
        }
        #expect(BrowserShortcut.resolve(keyCode: 96, characters: nil, modifiers: [], windowsFriendly: false, editingText: false) == nil)
        #expect(BrowserShortcut.resolve(keyCode: 36, characters: nil, modifiers: [], windowsFriendly: false, editingText: false) == .rename)
        #expect(BrowserShortcut.resolve(keyCode: 36, characters: nil, modifiers: M.option, windowsFriendly: false, editingText: false) == .properties)
    }
    @Test func propertiesReportRealMetadataAndMissingItems() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let file = try f.file("note.txt"), folder = try f.folder("folder")
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let values = await FilePropertiesReader().read([file, folder, link, f.root.appendingPathComponent("gone")])
        #expect(values[0].bytes == 9); #expect(values[0].permissions == "0600")
        #expect(values[0].modified != nil); #expect(values[0].created != nil)
        #expect(values[1].bytes == nil); #expect(values[2].symbolicLink == file.path)
        #expect(values[3].error != nil); #expect(values[3].bytes == nil)
    }
}
