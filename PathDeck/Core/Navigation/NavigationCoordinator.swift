import Foundation

@MainActor
public final class NavigationCoordinator {
    public let session: BrowserSession
    private let reader: any DirectoryReading
    private let parser: PathInputParser

    public init(session: BrowserSession, reader: any DirectoryReading = DirectoryReader(), parser: PathInputParser = PathInputParser()) {
        self.session = session; self.reader = reader; self.parser = parser
    }

    @discardableResult
    public func navigate(input: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        do { return await navigate(to: try parser.parse(input, relativeTo: session.currentDirectory)) }
        catch {
            let request = session.beginNavigation(to: session.currentDirectory)
            session.failNavigation(request, message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    public func navigate(to target: URL, mode: BrowserSession.NavigationMode = .visit) async -> Bool {
        guard !Task.isCancelled else { return false }
        let request = session.beginNavigation(to: target, mode: mode)
        do {
            let result = try await reader.read(target, showHidden: session.showHidden)
            return session.completeNavigation(request, directory: result.directory, items: result.items, selectedURL: result.selectedURL, reference: result.reference)
        } catch {
            return report(error, for: request)
        }
    }

    @discardableResult
    public func back() async -> Bool {
        guard session.canGoBack else { return false }
        let index = session.historyIndex - 1
        return await navigate(to: session.history[index].directory, mode: .history(index))
    }

    @discardableResult
    public func forward() async -> Bool {
        guard session.canGoForward else { return false }
        let index = session.historyIndex + 1
        return await navigate(to: session.history[index].directory, mode: .history(index))
    }

    @discardableResult
    public func refresh() async -> Bool { await navigate(to: session.currentDirectory, mode: .refresh) }

    private func report(_ error: Error, for request: BrowserSession.NavigationRequest) -> Bool {
        let ns = error as NSError
        let message: String
        if error is CancellationError { message = "读取已取消，请重试。" }
        else if ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(ns.code) {
            message = ns.code == NSFileReadNoPermissionError ? "无法访问此目录。请检查系统设置中的文件与文件夹权限。" : "没有找到这个位置，路径可能已更改或磁盘已移除。"
        } else { message = error.localizedDescription }
        session.failNavigation(request, message: message)
        return false
    }
}
