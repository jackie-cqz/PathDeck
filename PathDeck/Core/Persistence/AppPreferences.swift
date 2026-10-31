import Foundation

public struct WindowPlacement: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct ColumnPreference: Codable, Equatable, Sendable {
    public var id: String
    public var width: Double
    public var hidden: Bool
    public init(id: String, width: Double, hidden: Bool = false) { self.id = id; self.width = width; self.hidden = hidden }
}
public struct AppPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var window: WindowPlacement?
    public var sidebarWidth: Double = 240
    public var lastDirectory: String?
    public var columns = [ColumnPreference(id: "name", width: 360), ColumnPreference(id: "modified", width: 170), ColumnPreference(id: "kind", width: 130), ColumnPreference(id: "size", width: 90)]
    public var sort = FileSort()
    public var showHidden = false
    public var windowsFriendly = true
    public var compactList: Bool?
    public var favorites: [String]?
    public var favoriteNames: [String: String]?
    public var expandedDirectories: [String] = []
    public var recentDirectories: [String] = []
    public init() {}

    public func sanitized() -> AppPreferences {
        var result = self
        result.schemaVersion = 1
        result.sidebarWidth = sidebarWidth.isFinite ? min(360, max(180, sidebarWidth)) : 240
        if let window, [window.x, window.y, window.width, window.height].allSatisfy(\.isFinite) {
            result.window = WindowPlacement(x: window.x, y: window.y, width: min(5000, max(820, window.width)), height: min(5000, max(520, window.height)))
        } else { result.window = nil }
        var seen: Set<String> = []
        result.columns = columns.filter { ["name", "modified", "kind", "size"].contains($0.id) && seen.insert($0.id).inserted }.map {
            ColumnPreference(id: $0.id, width: $0.width.isFinite ? min(1200, max(70, $0.width)) : 120, hidden: $0.id == "name" ? false : $0.hidden)
        }
        for column in AppPreferences().columns where !seen.contains(column.id) { result.columns.append(column) }
        func paths(_ values: [String], limit: Int) -> [String] {
            var seen: Set<String> = []
            return Array(values.filter { $0.hasPrefix("/") && !$0.contains("\0") && seen.insert($0).inserted }.prefix(limit))
        }
        result.lastDirectory = lastDirectory.flatMap { paths([$0], limit: 1).first }
        result.favorites = favorites.map { paths($0, limit: 100) }
        if let favoriteNames {
            result.favoriteNames = FavoriteLocations(urls: (result.favorites ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }, names: favoriteNames).names
        }
        result.expandedDirectories = paths(expandedDirectories, limit: 128)
        result.recentDirectories = paths(recentDirectories, limit: 50)
        return result
    }
    public mutating func remember(_ url: URL) {
        lastDirectory = url.path
        recentDirectories.removeAll { $0 == url.path }
        recentDirectories.insert(url.path, at: 0)
        recentDirectories = Array(recentDirectories.prefix(50))
    }
}

public struct PreferencesLoadResult: Sendable {
    public let preferences: AppPreferences
    public let notice: String?
    public let missing: Bool
}

public final class PreferencesStore: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "local.pathdeck.preferences", qos: .utility)
    public init(url: URL) { self.url = url }
    public func load() async -> PreferencesLoadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                guard FileManager.default.fileExists(atPath: self.url.path) else {
                    continuation.resume(returning: PreferencesLoadResult(preferences: AppPreferences(), notice: nil, missing: true)); return
                }
                do {
                    let data = try Data(contentsOf: self.url)
                    guard data.count <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
                    let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
                    guard preferences.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
                    continuation.resume(returning: PreferencesLoadResult(preferences: preferences.sanitized(), notice: nil, missing: false))
                } catch {
                    let backup = self.url.deletingLastPathComponent().appendingPathComponent("preferences-corrupt-\(UUID().uuidString).json")
                    let backedUp = (try? FileManager.default.copyItem(at: self.url, to: backup)) != nil
                    continuation.resume(returning: PreferencesLoadResult(preferences: AppPreferences(), notice: backedUp ? "设置无法读取，已保留备份并恢复默认设置。" : "设置无法读取，正在使用默认设置。", missing: false))
                }
            }
        }
    }
    public func save(_ preferences: AppPreferences) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    try encoder.encode(preferences.sanitized()).write(to: self.url, options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
