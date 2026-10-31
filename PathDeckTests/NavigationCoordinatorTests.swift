import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

private struct RejectingReader: DirectoryReading {
    func read(_ target: URL, showHidden: Bool) async throws -> DirectoryListing { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
}
private actor HeldReader: DirectoryReading {
    private var pending: CheckedContinuation<DirectoryListing, any Error>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    func read(_ target: URL, showHidden: Bool) async throws -> DirectoryListing {
        if target.lastPathComponent == "slow" {
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation; heldWaiter?.resume(); heldWaiter = nil
            }
        }
        return DirectoryListing(directory: target, items: [])
    }
    func waitUntilHeld() async {
        if pending != nil { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }
    func release(_ url: URL) { pending?.resume(returning: DirectoryListing(directory: url, items: [])); pending = nil }
}
@Suite struct NavigationCoordinatorTests {
    @Test @MainActor func historyRefreshBranchAndFailure() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let a = try f.folder("a"); let b = try f.folder("b"); let c = try f.folder("c")
        let s = BrowserSession(initialDirectory: f.root)
        let n = NavigationCoordinator(session: s)
        #expect(await n.navigate(to: a)); #expect(await n.navigate(to: b)); #expect(s.canGoBack)
        #expect(await n.refresh()); #expect(s.history.count == 2)
        #expect(await n.back()); #expect(s.currentDirectory.path == a.path); #expect(s.canGoForward)
        #expect(await n.navigate(to: c)); #expect(!s.canGoForward); #expect(s.history.count == 2)
        #expect(!(await n.navigate(to: f.root.appendingPathComponent("missing"))))
        #expect(s.currentDirectory.path == c.path); #expect(s.history.count == 2)
    }
    @Test @MainActor func deniedReadPreservesCommittedLocation() async {
        let home = URL(fileURLWithPath: "/initial")
        let s = BrowserSession(initialDirectory: home)
        let n = NavigationCoordinator(session: s, reader: RejectingReader())
        #expect(!(await n.navigate(to: URL(fileURLWithPath: "/denied"))))
        #expect(s.currentDirectory == home); #expect(s.history.isEmpty)
        if case .failed(let message) = s.contentState { #expect(message.contains("权限")) } else { Issue.record("Expected an explicit permission error") }
    }
    @Test @MainActor func parserErrorDoesNotCreateHistory() async {
        let s = BrowserSession(initialDirectory: URL(fileURLWithPath: "/initial"))
        #expect(!(await NavigationCoordinator(session: s).navigate(input: "smb://server/share")))
        #expect(s.history.isEmpty)
    }
    @Test @MainActor func slowIOCannotOverwriteNewerNavigation() async {
        let reader = HeldReader()
        let s = BrowserSession(initialDirectory: URL(fileURLWithPath: "/initial"))
        let n = NavigationCoordinator(session: s, reader: reader)
        let slowURL = URL(fileURLWithPath: "/slow")
        let slow = Task { await n.navigate(to: slowURL) }
        await reader.waitUntilHeld()
        #expect(await n.navigate(to: URL(fileURLWithPath: "/fast")))
        await reader.release(slowURL)
        #expect(!(await slow.value)); #expect(s.currentDirectory.path == "/fast")
        #expect(s.history.count == 1)
    }
    @Test @MainActor func historyRestoresSelectionSortAndScrollAnchor() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let file = try f.file("remember.txt"); let other = try f.folder("other")
        let s = BrowserSession(initialDirectory: f.root); let n = NavigationCoordinator(session: s)
        #expect(await n.navigate(to: f.root))
        s.selection = [file]; s.scrollAnchor = file; s.sort = FileSort(ascending: false)
        #expect(await n.navigate(to: other)); #expect(await n.back())
        #expect(s.selection == [file]); #expect(s.scrollAnchor == file); #expect(!s.sort.ascending)
    }
}
