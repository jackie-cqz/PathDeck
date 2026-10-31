import AppKit

enum BrowserAppearance {
    static let mint = NSColor(name: "PathDeck.Mint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.43, green: 0.82, blue: 0.68, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.43, blue: 0.34, alpha: 1)
    }
}
