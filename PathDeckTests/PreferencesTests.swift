import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct PreferencesTests {
    @Test func roundTripAndFreshStoreRestoreAllSettings() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("settings/preferences.json")
        var value = AppPreferences()
        value.window = WindowPlacement(x: 100, y: 80, width: 1100, height: 700)
        value.sidebarWidth = 300; value.showHidden = true; value.windowsFriendly = false
        value.sort = FileSort(column: .size, ascending: false)
        value.columns = [.init(id: "name", width: 410), .init(id: "size", width: 100), .init(id: "modified", width: 180, hidden: true), .init(id: "kind", width: 120)]
        value.favorites = [f.root.path]; value.expandedDirectories = [f.root.path]; value.remember(f.root)
        try await PreferencesStore(url: url).save(value)
        let restored = await PreferencesStore(url: url).load()
        #expect(restored.preferences == value); #expect(restored.notice == nil)
    }
    @Test func corruptAndUnknownVersionAreBackedUp() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let url = f.root.appendingPathComponent("preferences.json")
        let bytes = Data("invalid-json".utf8); try bytes.write(to: url)
        let store = PreferencesStore(url: url)
        let result = await store.load()
        #expect(result.preferences == AppPreferences()); #expect(result.notice != nil)
        let backups = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("preferences-corrupt-") }
        #expect(backups.count == 1); #expect(try Data(contentsOf: backups[0]) == bytes)
        var future = AppPreferences(); future.schemaVersion = 999
        try JSONEncoder().encode(future).write(to: url)
        #expect(await store.load().notice != nil)
    }
    @Test func invalidSizesColumnsAndHistoryAreBounded() {
        var value = AppPreferences(); value.sidebarWidth = .infinity
        value.window = .init(x: .nan, y: 0, width: 1, height: 1)
        value.columns = [.init(id: "name", width: -10, hidden: true), .init(id: "name", width: 500), .init(id: "unknown", width: 10)]
        value.recentDirectories = (0..<90).map { "/folder/\($0)" }
        value.expandedDirectories = (0..<300).map { "/folder/\($0)" }
        value.lastDirectory = "https://example.com"
        let clean = value.sanitized()
        #expect(clean.window == nil); #expect(clean.sidebarWidth == 240)
        #expect(clean.columns.count == 4); #expect(clean.columns.first?.width == 70); #expect(clean.columns.first?.hidden == false)
        #expect(clean.recentDirectories.count == 50); #expect(clean.expandedDirectories.count == 128); #expect(clean.lastDirectory == nil)
    }
}
