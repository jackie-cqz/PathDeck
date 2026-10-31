import Foundation

public enum BrowserShortcut: Equatable, Sendable {
    case copy, cut, paste, selectAll, newFolder, newWindow, newTab, closeTab, nextTab, previousTab
    case back, forward, up, refresh, open, rename, trash, blockedDelete, preview, properties, filter
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Self(rawValue: 1), control = Self(rawValue: 2), option = Self(rawValue: 4), shift = Self(rawValue: 8)
    }
    public static func resolve(keyCode: UInt16, characters: String?, modifiers m: Modifiers, windowsFriendly: Bool, editingText: Bool) -> Self? {
        guard !editingText else { return nil }
        if m == .command, keyCode == 125 { return .open }
        if m.isEmpty, keyCode == 49 { return .preview }
        if m == .option, keyCode == 36 { return .properties }
        if m.isEmpty, keyCode == 36 { return windowsFriendly ? .open : .rename }
        if m.isEmpty, keyCode == 120 { return .rename }
        if m == .command, keyCode == 51 { return .trash }
        if m == .shift, keyCode == 117 { return .blockedDelete }
        guard windowsFriendly else { return nil }
        if m.isEmpty {
            switch keyCode { case 96: return .refresh; case 51: return .back; case 117: return .trash; default: break }
        }
        if m == .option {
            switch keyCode { case 123: return .back; case 124: return .forward; case 126: return .up; default: break }
        }
        if keyCode == 48, m == .control { return .nextTab }
        if keyCode == 48, m == [.control, .shift] { return .previousTab }
        let character = characters?.lowercased()
        if m == [.control, .shift], character == "n" { return .newFolder }
        if m == .control {
            switch character {
            case "c": return .copy; case "x": return .cut; case "v": return .paste; case "a": return .selectAll
            case "f": return .filter; case "n": return .newWindow; case "t": return .newTab; case "w": return .closeTab
            default: break
            }
        }
        return nil
    }
}
