import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class TerminalService {
    private let reader = DirectoryReader()
    /// Directory URLs are data passed to Launch Services; no shell command is assembled.
    @discardableResult func open(directory: URL) async throws -> NSRunningApplication {
        guard directory.isFileURL, try await reader.isBrowsableDirectory(directory) else {
            throw NSError(domain: "PathDeck.Terminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "终端目标必须是可访问的普通目录。"])
        }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw NSError(domain: "PathDeck.Terminal", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有找到系统 Terminal。可以先复制目录路径。"])
        }
        return try await NSWorkspace.shared.open([directory], withApplicationAt: application, configuration: .init())
    }
}
