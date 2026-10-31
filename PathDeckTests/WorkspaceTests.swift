import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct WorkspaceTests {
    @Test func viewModesPreserveLegacySettingsAndPerPageChoices() throws {
        let legacy = try JSONDecoder().decode(AppPreferences.self, from: Data("{\"schemaVersion\":1,\"sidebarWidth\":240,\"columns\":[],\"sort\":{\"column\":\"name\",\"ascending\":true},\"showHidden\":false,\"windowsFriendly\":true,\"expandedDirectories\":[],\"recentDirectories\":[]}".utf8))
        #expect(legacy.fileViewMode == nil)
        var preferences = legacy
        preferences.fileViewMode = .tiles
        preferences.workspace = .init(groups: [.init(pages: [.init(directory: "/images", fileViewMode: .tiles), .init(directory: "/documents", fileViewMode: .details)])])
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).sanitized()
        #expect(restored.fileViewMode == .tiles)
        #expect(restored.workspace?.groups.first?.pages.map(\.fileViewMode) == [.tiles, .details])
    }
    @Test func preferencesRoundTripWindowGroupsAndPageState() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }; let file = try FileReference.capture(f.file("selected.txt"))
        var preferences = AppPreferences()
        let page = BrowserPageSnapshot(directory: f.root.path, selection: [file], anchor: file, filter: "selected", sort: .init(column: .size, ascending: false), showHidden: true)
        preferences.workspace = WorkspaceSnapshot(groups: [.init(pages: [page, page], selectedIndex: 1, frame: .init(x: 10, y: 20, width: 1000, height: 650)), .init(pages: [page])], activeGroup: 1)
        let store = PreferencesStore(url: f.root.appendingPathComponent("preferences.json")); try await store.save(preferences)
        let loaded = await PreferencesStore(url: store.url).load()
        #expect(loaded.preferences == preferences); #expect(loaded.notice == nil)
    }
    @Test @MainActor func restoredSelectionFollowsIdentityAndSkipsReplacement() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let a = try FileReference.capture(f.file("a.txt")), b = try FileReference.capture(f.file("b.txt"))
        let renamed = f.root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: a.url, to: renamed)
        try FileManager.default.moveItem(at: b.url, to: f.root.appendingPathComponent("kept.txt")); try Data().write(to: b.url)
        let session = BrowserSession(initialDirectory: f.root), reader = DirectoryReader()
        let result = try await reader.read(f.root, showHidden: true), request = session.beginNavigation(to: f.root)
        session.completeNavigation(request, items: result.items, reference: result.reference)
        session.restoreViewState(.init(directory: f.root.path, selection: [a, b], anchor: a, filter: "renamed"))
        #expect(session.selection == [renamed]); #expect(session.scrollAnchor == renamed); #expect(session.visibleItems.count == 1)
    }
    @Test func malformedWorkspaceIndicesPathsAndFramesAreSanitized() {
        let valid = BrowserPageSnapshot(directory: "/valid"), invalid = BrowserPageSnapshot(directory: "relative")
        var workspace = WorkspaceSnapshot(groups: [.init(pages: [invalid, valid], selectedIndex: 99, frame: .init(x: .nan, y: 0, width: -1, height: 0))], activeGroup: 99)
        let clean = workspace.sanitized()
        #expect(clean?.groups.count == 1); #expect(clean?.groups.first?.pages.count == 1); #expect(clean?.groups.first?.selectedIndex == 0); #expect(clean?.groups.first?.frame == nil); #expect(clean?.activeGroup == 0)
        workspace.schemaVersion = 99; #expect(workspace.sanitized() == nil)
    }
}
