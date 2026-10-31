import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite
struct BrowserSessionTests {
    @Test @MainActor
    func testInitialStateIsNotAnEmptyDirectoryResult() {
        let session = BrowserSession(initialDirectory: url("/initial"))
        #expect(session.contentState == .notLoaded)
        #expect(session.items.isEmpty)
    }

    @Test @MainActor
    func testOutOfOrderResultsCannotReplaceTheLatestLocation() {
        let session = BrowserSession(initialDirectory: url("/initial"))
        let a = session.beginNavigation(to: url("/a"))
        let b = session.beginNavigation(to: url("/b"))
        let c = session.beginNavigation(to: url("/c"))
        #expect(session.currentDirectory == url("/initial"))
        #expect(!(session.completeNavigation(b, items: [])))
        #expect(session.completeNavigation(c, items: []))
        #expect(!(session.completeNavigation(a, items: [])))
        #expect(session.currentDirectory == url("/c"))
        #expect(session.contentState == .loaded)
    }

    @Test @MainActor
    func testFailurePreservesLastCommittedRowsAndLocation() {
        let session = BrowserSession(initialDirectory: url("/initial"))
        let item = FileItem(url: url("/a/note.txt"), displayName: "note.txt", kind: .regularFile)
        let first = session.beginNavigation(to: url("/a"))
        session.completeNavigation(first, items: [item])
        let failed = session.beginNavigation(to: url("/unavailable"))
        #expect(session.failNavigation(failed, message: "无权限"))
        #expect(session.currentDirectory == url("/a"))
        #expect(session.items == [item])
        #expect(session.contentState == .failed("无权限"))
    }

    @Test @MainActor
    func testStaleFailureDoesNotOverrideNewerSuccess() {
        let session = BrowserSession(initialDirectory: url("/initial"))
        let old = session.beginNavigation(to: url("/old"))
        let latest = session.beginNavigation(to: url("/latest"))
        session.completeNavigation(latest, items: [])
        #expect(!(session.failNavigation(old, message: "过期错误")))
        #expect(session.contentState == .loaded)
    }

    @Test @MainActor
    func testRequestCannotBeCommittedTwiceOrByAnotherSession() {
        let first = BrowserSession(initialDirectory: url("/initial"))
        let second = BrowserSession(initialDirectory: url("/initial"))
        let request = first.beginNavigation(to: url("/target"))
        _ = second.beginNavigation(to: url("/target"))
        #expect(!(second.completeNavigation(request, items: [])))
        #expect(first.completeNavigation(request, items: []))
        #expect(!(first.completeNavigation(request, items: [])))
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test @MainActor
    func cancelledQueuedNavigationCannotReplaceCurrentRequest() async {
        let session = BrowserSession(initialDirectory: url("/initial"))
        let coordinator = NavigationCoordinator(session: session)
        let task = Task { await coordinator.navigate(to: url("/cancelled")) }
        task.cancel()
        #expect(await task.value == false)
        #expect(session.contentState == .notLoaded)
        #expect(session.generation == 0)
    }

    @Test @MainActor
    func refreshTracksRenamesAndDoesNotSelectReplacements() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let first = try f.file("first.txt")
        let reader = DirectoryReader(), session = BrowserSession(initialDirectory: f.root)
        let coordinator = NavigationCoordinator(session: session, reader: reader)
        #expect(await coordinator.navigate(to: f.root))
        session.selection = [first]; session.scrollAnchor = first
        let moved = f.root.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: first, to: moved)
        _ = try f.file("first.txt")
        #expect(await coordinator.refresh())
        #expect(session.selection == [moved]); #expect(session.scrollAnchor == moved)
        try FileManager.default.moveItem(at: moved, to: f.root.appendingPathComponent("kept-original"))
        _ = try f.file("moved.txt")
        #expect(await coordinator.refresh())
        #expect(!session.selection.contains(moved))
    }

    @Test @MainActor
    func historyStaysBoundedAndCanBeCleared() {
        let session = BrowserSession(initialDirectory: url("/"))
        for index in 0..<100 {
            let request = session.beginNavigation(to: url("/folder\(index)"))
            session.completeNavigation(request, items: [])
        }
        #expect(session.history.count == 50); #expect(session.historyIndex == 49)
        session.clearHistory()
        #expect(session.history.count == 1); #expect(!session.canGoBack && !session.canGoForward)
        #expect(session.history.first?.directory == url("/folder99"))
    }
}

