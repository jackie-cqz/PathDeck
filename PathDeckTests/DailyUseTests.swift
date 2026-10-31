import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct DailyUseTests {
    @Test func favoriteEditsChangePreferencesOnly() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let a = try f.folder("alpha"), b = try f.folder("beta")
        var favorites = FavoriteLocations(urls: [a, b])
        favorites.setName("工作 👋", for: a); favorites.move(a, by: 1)
        #expect(favorites.urls == [b, a]); #expect(favorites.title(for: a) == "工作 👋")
        #expect(FileManager.default.fileExists(atPath: a.path)); #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("工作 👋").path))
        var preferences = AppPreferences(); preferences.favorites = favorites.urls.map(\.path); preferences.favoriteNames = favorites.names
        let store = PreferencesStore(url: f.root.appendingPathComponent("preferences.json")); try await store.save(preferences)
        let restored = await store.load().preferences
        #expect(restored.favorites == [b.path, a.path]); #expect(restored.favoriteNames?[a.path] == "工作 👋")
        let duplicate = favorites.relink(a, to: b), relinked = favorites.relink(a, to: f.root)
        #expect(!duplicate); #expect(relinked)
        #expect(favorites.urls == [b, f.root]); #expect(favorites.title(for: f.root) == "工作 👋")
        favorites.remove(f.root); #expect(favorites.names.isEmpty); #expect(FileManager.default.fileExists(atPath: a.path))
    }
    @Test func oldPreferencesRemainReadableAndTitlesAreBounded() throws {
        let encoded = try JSONEncoder().encode(AppPreferences())
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "favoriteNames")
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.favoriteNames == nil)
        let url = URL(fileURLWithPath: "/tmp/example", isDirectory: true)
        var favorites = FavoriteLocations(urls: [url, url])
        favorites.setName(" \n" + String(repeating: "界", count: 200), for: url)
        #expect(favorites.urls.count == 1); #expect(favorites.title(for: url).count == 120)
        favorites.setName("   ", for: url); #expect(favorites.title(for: url) == "example")
        favorites.move(url, by: -1); #expect(favorites.urls == [url])
    }
    @Test @MainActor func filterMatchesNamesAndDropsHiddenSelection() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let a = try f.file("Café.TXT"), b = try f.file("中文 👋.txt"), literal = try f.file("[draft].md")
        let session = BrowserSession(initialDirectory: f.root)
        let navigation = NavigationCoordinator(session: session)
        #expect(await navigation.navigate(to: f.root))
        session.selection = [a, b]; session.scrollAnchor = b
        session.setFilter("CAFE")
        #expect(session.visibleItems.map(\.url) == [a]); #expect(session.selection == [a]); #expect(session.scrollAnchor == nil)
        session.setFilter("👋"); #expect(session.visibleItems.map(\.url) == [b]); #expect(session.selection.isEmpty)
        session.setFilter("[draft]"); #expect(session.visibleItems.map(\.url) == [literal])
        session.setFilter("no match"); #expect(session.visibleItems.isEmpty); #expect(session.items.count == 3)
        session.setFilter(""); #expect(session.visibleItems.count == 3); #expect(session.selection.isEmpty)
    }
    @Test @MainActor func filterSurvivesRefreshButResetsOnNavigationAndFileLocation() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        _ = try f.file("one.txt"); let other = try f.folder("other")
        let session = BrowserSession(initialDirectory: f.root), reader = DirectoryReader()
        let navigation = NavigationCoordinator(session: session, reader: reader)
        #expect(await navigation.navigate(to: f.root)); session.setFilter(".txt")
        let two = try f.file("two.txt")
        #expect(await navigation.refresh()); #expect(session.filterQuery == ".txt"); #expect(session.visibleItems.count == 2)
        session.changeSort(.init(ascending: false)); #expect(session.visibleItems.first?.url == two)
        session.setFilter("unmatched")
        #expect(await navigation.navigate(to: two)); #expect(session.filterQuery.isEmpty); #expect(session.selection == [two])
        session.setFilter(".txt"); #expect(await navigation.navigate(to: other)); #expect(session.filterQuery.isEmpty)
        #expect(session.items.isEmpty)
    }
}
