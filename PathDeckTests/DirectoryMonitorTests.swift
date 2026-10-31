import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import PathDeckCore
#else
@testable import PathDeck
#endif

@Suite struct DirectoryMonitorTests {
    @Test func externalEntryChangeIsDeliveredAndStopReleasesSubscriptions() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let monitor = DirectoryMonitor()
        let (stream, continuation) = AsyncStream<[DirectoryChange]>.makeStream()
        monitor.setURLs([f.root]) { continuation.yield($0) }
        #expect(await monitor.activeCount() == 1)
        _ = try f.file("external")
        let changed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await event in stream { return event.contains { $0.url == f.root } }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
            let result = await group.next() ?? false; group.cancelAll(); return result
        }
        #expect(changed)
        monitor.stop(); #expect(await monitor.activeCount() == 0); continuation.finish()
    }
    @Test func subscriptionSetIsDeduplicatedAndBounded() async throws {
        let f = try DirectoryFixture(); defer { f.remove() }
        let folders = try (0..<20).map { try f.folder("folder\($0)") }
        let monitor = DirectoryMonitor(limit: 5)
        monitor.setURLs(folders + folders) { _ in }
        #expect(await monitor.activeCount() == 5)
        monitor.setURLs([f.root]) { _ in }; #expect(await monitor.activeCount() == 1)
        monitor.stop(); #expect(await monitor.activeCount() == 0)
    }
}
