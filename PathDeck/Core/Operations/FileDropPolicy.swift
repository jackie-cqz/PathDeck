import Foundation
import Darwin

/// No filesystem access during hover. The operation engine revalidates identities at execution.
public enum FileDropPolicy {
    public enum Intent: Sendable { case automatic, copy, move }
    public static func operation(sources: [FileReference], destination: FileReference, internalDrag: Bool,
                                 permitsCopy: Bool, permitsMove: Bool, intent: Intent) -> FileOperationKind? {
        guard !sources.isEmpty, localFileURL(destination.url), destination.url.path != "/", destination.identity?.mode == S_IFDIR,
              sources.allSatisfy({ localFileURL($0.url) && $0.url.path != "/" }) else { return nil }
        let target = destination.url.standardizedFileURL.pathComponents
        // A file cannot contain a directory either; this check also works for unknown external types.
        guard !sources.contains(where: { target.starts(with: $0.url.standardizedFileURL.pathComponents) }) else { return nil }
        let sameVolume = sources.allSatisfy { $0.identity?.device == destination.identity?.device }
        let kind: FileOperationKind
        switch intent {
        case .copy: guard permitsCopy else { return nil }; kind = .copy
        case .move: guard permitsMove else { return nil }; kind = .move
        case .automatic:
            if internalDrag && sameVolume && permitsMove { kind = .move }
            else if permitsCopy { kind = .copy }
            else if permitsMove { kind = .move }
            else { return nil }
        }
        if kind == .move {
            if sources.allSatisfy({ $0.identity != nil }), !sameVolume { return nil }
            if sources.allSatisfy({ $0.url.standardizedFileURL.deletingLastPathComponent().pathComponents == target }) { return nil }
        }
        return kind
    }
    private static func localFileURL(_ url: URL) -> Bool {
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0") && !encodedPath.contains("%00") && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
    }
}
