import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

struct ClipboardSnapshot {
    let sources: [FileReference]
    let kind: FileOperationKind
    let token: String?
    let changeCount: Int
}

@MainActor
final class ClipboardService {
    private static let cutType = NSPasteboard.PasteboardType("local.pathdeck.pending-move")
    let pasteboard: NSPasteboard
    private var cutReferences: [FileReference] = []
    private var copiedReferences: [FileReference] = []
    private var copiedCount = -1
    private var token: String?
    private var count = -1
    private var timer: Timer?
    var onChange: (() -> Void)?
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        startMonitoring()
    }
    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor [weak self] in self?.synchronize() }
        }
    }
    func stopMonitoring() { timer?.invalidate(); timer = nil }
    var cutURLs: Set<URL> { synchronize(); return Set(cutReferences.map(\.url)) }
    var hasFileURLs: Bool { !urls().isEmpty }
    func synchronize() {
        guard token != nil, pasteboard.changeCount != count || pasteboard.string(forType: Self.cutType) != token else { return }
        token = nil; cutReferences = []; onChange?()
    }
    func write(_ sources: [FileReference], cut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(sources.map { $0.url as NSURL })
        cutReferences = cut ? sources : []
        copiedReferences = cut ? [] : sources
        token = cut ? UUID().uuidString : nil
        if let token { pasteboard.setString(token, forType: Self.cutType) }
        count = pasteboard.changeCount; copiedCount = count; onChange?()
    }
    func snapshot(using engine: FileOperationEngine) async throws -> ClipboardSnapshot {
        synchronize()
        let count = pasteboard.changeCount
        let urls = urls()
        guard !urls.isEmpty else { throw FileOperationError.unsupported }
        let activeToken = token
        let sources: [FileReference]
        if activeToken != nil { sources = cutReferences }
        else if copiedCount == count && copiedReferences.map(\.url) == urls { sources = copiedReferences }
        else { sources = await engine.capture(urls) }
        guard count == pasteboard.changeCount else { throw NSError(domain: "PathDeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "剪贴板已改变，请重新粘贴。 "]) }
        return ClipboardSnapshot(sources: sources, kind: activeToken == nil ? .copy : .move, token: activeToken, changeCount: count)
    }
    func complete(_ snapshot: ClipboardSnapshot, record: FileOperationRecord) {
        synchronize()
        guard snapshot.kind == .move, token == snapshot.token, count == snapshot.changeCount else { return }
        let completed = Set(record.results.filter { $0.outcome == .succeeded }.compactMap(\.source))
        let remaining = cutReferences.filter { !completed.contains($0.url) }
        if remaining.isEmpty {
            pasteboard.clearContents(); cutReferences = []; token = nil; count = pasteboard.changeCount; onChange?()
        } else { write(remaining, cut: true) }
    }
    private func urls() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
