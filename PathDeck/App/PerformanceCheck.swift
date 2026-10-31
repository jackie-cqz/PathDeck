import AppKit
import Darwin
#if SWIFT_PACKAGE
import PathDeckCore
#endif

/// Release-only benchmark of the real window and table, using local temporary files.
@MainActor
enum PerformanceCheck {
    static func run(window: NSWindow, fixture: URL) async {
        guard let browser = window.contentViewController as? BrowserViewController else { exit(1) }
        await browser.waitForNavigation(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let startup = (ProcessInfo.processInfo.systemUptime - RuntimeContext.startedAt) * 1000
        var heartbeat = ProcessInfo.processInfo.systemUptime, largestGap = 0.0
        let pulse = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ProcessInfo.processInfo.systemUptime
                largestGap = max(largestGap, (now - heartbeat) * 1000); heartbeat = now
            }
        }
        do {
            let generationStart = ProcessInfo.processInfo.systemUptime
            let directories = try await Task.detached(priority: .utility) {
                try [1000, 10000].map { count -> URL in
                    let directory = fixture.appendingPathComponent("Files-\(count)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    for index in 0..<count { try Data().write(to: directory.appendingPathComponent(String(format: "item-%05d.txt", index))) }
                    return directory
                }
            }.value
            let generationMS = (ProcessInfo.processInfo.systemUptime - generationStart) * 1000
            var measurements: [String: [Double]] = [:], correct = true
            var results: [[String: Any]] = []
            for (index, directory) in directories.enumerated() {
                var samples: [Double] = []
                for _ in 0..<3 {
                    browser.navigate(to: fixture); await browser.waitForNavigation()
                    let start = ProcessInfo.processInfo.systemUptime
                    browser.navigate(to: directory); await browser.waitForNavigation()
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    correct = correct && browser.session.contentState == .loaded && browser.fileList.rowCount == (index == 0 ? 1000 : 10000)
                    results.append(["expectedRows": index == 0 ? 1000 : 10000, "actualRows": browser.fileList.rowCount, "loaded": browser.session.contentState == .loaded])
                }
                measurements[index == 0 ? "1000" : "10000"] = samples
            }
            let memoryBefore = footprintMB()
            for index in 0..<50 { browser.navigate(to: directories[index % 2]) }
            await browser.waitForNavigation()
            let rapidCorrect = browser.session.currentDirectory.path == directories[1].path && browser.session.contentState == .loaded && browser.fileList.rowCount == 10000
            correct = correct && rapidCorrect
            let filterStart = ProcessInfo.processInfo.systemUptime
            browser.session.setFilter("item-0999")
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let filterMS = (ProcessInfo.processInfo.systemUptime - filterStart) * 1000
            let filterCorrect = browser.fileList.rowCount == 10 && browser.session.items.count == 10000
            browser.session.setFilter("")
            // Exercise completed loads/scrolling as well as obsolete requests.
            for index in 0..<10 {
                browser.navigate(to: directories[index % 2]); await browser.waitForNavigation()
                (browser.fileList.keyboardView as? NSTableView)?.scrollRowToVisible(index * 80)
                window.contentView?.layoutSubtreeIfNeeded()
            }
            try? await Task.sleep(for: .milliseconds(400))
            let watches = await browser.monitorCount(), memoryAfter = footprintMB()
            browser.stopMonitoring()
            let stopped = await browser.monitorCount()
            pulse.cancel()
            let small = measurements["1000"]!.sorted()[1], large = measurements["10000"]!.sorted()[1]
            let passed = correct && filterCorrect && filterMS < 500 && small < 500 && large < 2000 && watches <= 64 && stopped == 0 && browser.fileList.iconCacheCount <= 128
            let report: [String: Any] = [
                "passed": passed, "configuration": "Release", "cacheCondition": "freshly generated local fixture; OS caches warm; three visits each",
                "startupToVisibleListMS": startup, "fixtureGenerationMS": generationMS, "directoryToDisplayedRowsMS": measurements,
                "median1000MS": small, "median10000MS": large, "largestMainActorHeartbeatGapMS": largestGap,
                "filter10000MS": filterMS, "filterCorrect": filterCorrect,
                "physicalFootprintBeforeChurnMB": memoryBefore, "physicalFootprintAfterChurnMB": memoryAfter,
                "watchersAfterChurn": watches, "watchersAfterStop": stopped, "iconCacheEntries": browser.fileList.iconCacheCount,
                "rapid50NavigationCorrect": rapidCorrect, "visitResults": results, "system": ProcessInfo.processInfo.operatingSystemVersionString,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
            try? FileManager.default.removeItem(at: fixture)
            exit(passed ? 0 : 1)
        } catch {
            pulse.cancel(); browser.stopMonitoring(); try? FileManager.default.removeItem(at: fixture)
            fputs("Performance benchmark failed: \(error)\n", stderr); exit(1)
        }
    }
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return code == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
    }
}
