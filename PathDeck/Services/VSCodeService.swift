import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class VSCodeService {
    private let reader = DirectoryReader()
    var applicationURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") }
    /// Uses file URLs directly, without requiring the `code` CLI or assembling a command.
    @discardableResult func open(_ urls: [URL]) async throws -> NSRunningApplication {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
            throw NSError(domain: "PathDeck.VSCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择本地文件或目录。"])
        }
        guard let applicationURL else {
            throw NSError(domain: "PathDeck.VSCode", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到 Visual Studio Code。也可以通过“打开方式…”选择编辑器。"])
        }
        for url in urls {
            // The result may be false for regular files; the read still verifies existence/access.
            _ = try await reader.isBrowsableDirectory(url)
        }
        return try await NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: .init())
    }
}
