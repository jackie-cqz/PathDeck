import Foundation

/// Preferences only: never renames or moves a filesystem object.
public struct FavoriteLocations: Equatable, Sendable {
    public private(set) var urls: [URL]
    public private(set) var names: [String: String]
    public init(urls: [URL] = [], names: [String: String] = [:]) {
        var seen: Set<String> = []
        self.urls = Array(urls.filter { $0.isFileURL && seen.insert($0.path).inserted }.prefix(100))
        self.names = [:]
        for url in self.urls { if let name = names[url.path] { setName(name, for: url) } }
    }
    public func title(for url: URL) -> String {
        names[url.path] ?? (url == FileManager.default.homeDirectoryForCurrentUser ? "个人文件夹" : url.path == "/" ? "/" : url.lastPathComponent)
    }
    public mutating func pin(_ url: URL) {
        guard url.isFileURL, urls.count < 100, !urls.contains(where: { $0.path == url.path }) else { return }
        urls.append(url)
    }
    public mutating func remove(_ url: URL) { urls.removeAll { $0.path == url.path }; names[url.path] = nil }
    public mutating func setName(_ name: String, for url: URL) {
        guard urls.contains(where: { $0.path == url.path }) else { return }
        let cleaned = String(name.replacingOccurrences(of: "\0", with: "").components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        names[url.path] = cleaned.isEmpty ? nil : cleaned
    }
    public mutating func move(_ url: URL, by offset: Int) {
        guard let index = urls.firstIndex(where: { $0.path == url.path }), urls.indices.contains(index + offset) else { return }
        urls.swapAt(index, index + offset)
    }
    @discardableResult public mutating func relink(_ url: URL, to replacement: URL) -> Bool {
        guard replacement.isFileURL, let index = urls.firstIndex(where: { $0.path == url.path }), !urls.contains(where: { $0.path == replacement.path && $0.path != url.path }) else { return false }
        let name = names.removeValue(forKey: url.path)
        urls[index] = replacement; names[replacement.path] = name
        return true
    }
}
