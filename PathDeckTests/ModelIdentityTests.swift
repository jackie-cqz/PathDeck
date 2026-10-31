import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite
struct ModelIdentityTests {
    @Test
    func testSameFolderInTwoSidebarBranchesHasDistinctRowIdentity() {
        let url = URL(fileURLWithPath: "/home/Downloads")
        let favorite = DirectoryNode(branch: "favorites", url: url, displayName: "下载")
        let tree = DirectoryNode(branch: "locations", url: url, displayName: "Downloads")
        #expect(favorite.id != tree.id)
        #expect(favorite.url == tree.url)
        #expect(favorite.loadState == .notLoaded)
    }

    @Test
    func testLocalizedDisplayNameDoesNotChangeRealPath() {
        let file = FileItem(
            url: URL(fileURLWithPath: "/home/Downloads"),
            displayName: "下载",
            kind: .directory
        )
        #expect(file.realName == "Downloads")
        #expect(file.displayName == "下载")
        #expect(file.url.path == "/home/Downloads")
    }
}

