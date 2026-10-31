import Foundation

public enum PathInputError: Error, LocalizedError, Equatable {
    case empty, invalid, windowsPath, unsupportedURL, unsupportedHome, trailingNewline
    public var errorDescription: String? {
        switch self {
        case .empty: "请输入文件夹路径。"
        case .invalid: "路径包含无效字符，或 file URL 格式不正确。"
        case .windowsPath: "这是 Windows 路径，请使用对应的 Mac 路径。"
        case .unsupportedURL: "仅支持本地路径、file URL 和已挂载目录。"
        case .unsupportedHome: "暂不支持 ~其他用户，请使用绝对路径。"
        case .trailingNewline: "路径末尾含换行，请移除末尾换行后重试。"
        }
    }
}

/// Syntax only. Never expands shell commands, environment variables or wildcards.
public struct PathInputParser: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func parse(_ input: String, relativeTo base: URL) throws -> URL {
        guard !input.isEmpty else { throw PathInputError.empty }
        guard !input.contains("\0") else { throw PathInputError.invalid }
        if input.hasSuffix("\n") || input.hasSuffix("\r") { throw PathInputError.trailingNewline }
        if input.range(of: #"^[A-Za-z]:[\\/]|^\\\\"#, options: .regularExpression) != nil {
            throw PathInputError.windowsPath
        }
        if input.lowercased().hasPrefix("file:/") {
            guard let url = URL(string: input), url.isFileURL,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  !url.path.isEmpty, url.path.hasPrefix("/"), !url.path.contains("\0") else {
                throw PathInputError.invalid
            }
            return URL(fileURLWithPath: url.path)
        }
        if input.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            throw PathInputError.unsupportedURL
        }
        if input == "~" || input == "～" { return home }
        if input.hasPrefix("~/") || input.hasPrefix("～/") { return home.appendingPathComponent(String(input.dropFirst(2))) }
        if input.hasPrefix("~") { throw PathInputError.unsupportedHome }
        return URL(fileURLWithPath: input, isDirectory: false, relativeTo: URL(fileURLWithPath: base.path, isDirectory: true)).absoluteURL
    }

    public func completionParent(_ input: String, relativeTo base: URL) throws -> (URL, String) {
        let url = try parse(input, relativeTo: base)
        if input.hasSuffix("/") || input == "~" || input == "～" { return (url, "") }
        return (url.deletingLastPathComponent(), url.lastPathComponent)
    }
}
