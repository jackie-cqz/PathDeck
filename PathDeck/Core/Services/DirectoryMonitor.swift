import Foundation
import Dispatch
import Darwin

public struct DirectoryChange: Sendable {
    public let url: URL
    public let relocatedURL: URL?
    public let unavailable: Bool
}

/// Bounded vnode subscriptions. Opens, debounce and closes happen off the main thread.
public final class DirectoryMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.pathdeck.directory-monitor", qos: .utility)
    private var sources: [URL: any DispatchSourceFileSystemObject] = [:]
    private var pending: [URL: DirectoryChange] = [:]
    private var delivery: DispatchWorkItem?
    private var handler: (@Sendable ([DirectoryChange]) -> Void)?
    public let limit: Int
    public init(limit: Int = 64) { self.limit = max(1, min(limit, 256)) }
    deinit { delivery?.cancel(); for source in sources.values { source.cancel() } }

    public func setURLs(_ urls: [URL], handler: @escaping @Sendable ([DirectoryChange]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handler = handler
            var seen: Set<URL> = []
            let wanted = Set(urls.filter { $0.isFileURL && seen.insert($0).inserted }.prefix(self.limit))
            for url in Array(self.sources.keys) where !wanted.contains(url) { self.sources.removeValue(forKey: url)?.cancel() }
            for url in wanted where self.sources[url] == nil { self.add(url) }
        }
    }
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.delivery?.cancel(); self.delivery = nil; self.pending = [:]; self.handler = nil
            for source in self.sources.values { source.cancel() }; self.sources = [:]
        }
    }
    public func activeCount() async -> Int {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.sources.count) } }
    }
    public func isWatching(_ url: URL) async -> Bool {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.sources[url] != nil) } }
    }
    private func add(_ url: URL) {
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let identity = try? FileIdentity.read(url)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke, .attrib, .extend, .link], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            var relocated: URL?
            if flags.contains(.rename) {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                if fcntl(fd, F_GETPATH, &path) == 0 {
                    let candidate = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                    if (try? FileIdentity.read(candidate)) == identity { relocated = candidate }
                }
            }
            let unavailable = flags.contains(.delete) || flags.contains(.revoke)
            self.pending[url] = DirectoryChange(url: url, relocatedURL: relocated, unavailable: unavailable)
            self.delivery?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }; let changes = Array(self.pending.values); self.pending = [:]; self.handler?(changes)
            }
            self.delivery = work; self.queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
            if unavailable || flags.contains(.rename) { self.sources.removeValue(forKey: url)?.cancel() }
        }
        sources[url] = source; source.resume()
    }
}
