import AppKit
import Darwin

/// Opt-in test: verifies Terminal's real shell cwd, then signals only that fixture's shell.
@MainActor
enum TerminalCheck {
    static func run(browser: BrowserViewController, fixture: URL) async {
        var checks: [String: Bool] = [:]
        let cases = ["中文 quote' \" ;$(touch PATHDECK_INJECTED); & 👋", "line\nbreak é"]
        do {
            for (index, name) in cases.enumerated() {
                let directory = fixture.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let application = try await browser.terminal.open(directory: directory)
                let terminalPID = application.processIdentifier
                var matched: pid_t?
                for _ in 0..<40 {
                    matched = await Task.detached { shell(at: directory.path, terminal: terminalPID) }.value
                    if matched != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                checks["realCWD.case\(index)"] = matched != nil
                // Never signal other Terminal sessions or terminate the shared Terminal app.
                if let matched, shell(at: directory.path, terminal: terminalPID) == matched { kill(matched, SIGHUP) }
            }
            checks["pathsNotExecuted"] = !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("PATHDECK_INJECTED").path)
            do { try await browser.terminal.open(directory: fixture.appendingPathComponent("missing")); checks["missingDirectoryRejected"] = false }
            catch { checks["missingDirectoryRejected"] = true }
            do { try await browser.terminal.open(directory: fixture.appendingPathComponent(".hidden")); checks["fileRejected"] = false }
            catch { checks["fileRejected"] = true }
        } catch { checks["terminalLaunchSucceeded"] = false; fputs("Terminal check: \(error)\n", stderr) }
        browser.stopMonitoring(); await browser.preferences.flush()
        let passed = checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["passed": passed, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
        fflush(stdout); try? FileManager.default.removeItem(at: fixture); exit(passed ? 0 : 1)
    }
    nonisolated private static func shell(at path: String, terminal: pid_t) -> pid_t? {
        let capacity = min(32768, max(128, Int(proc_listallpids(nil, 0)) + 128))
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(max(0, min(Int(count), capacity))) where pid > 1 && pid != terminal {
            guard isDescendant(pid, of: terminal) else { continue }
            // libproc's PROC_PIDPATHINFO_MAXSIZE macro is 4 * MAXPATHLEN.
            var binary = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &binary, UInt32(binary.count)) > 0 else { continue }
            let executable = String(decoding: binary.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard ["zsh", "bash", "sh", "fish", "tcsh", "csh"].contains(URL(fileURLWithPath: executable).lastPathComponent) else { continue }
            var info = proc_vnodepathinfo()
            let size = MemoryLayout<proc_vnodepathinfo>.size
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { continue }
            let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            if cwd == path { return pid }
        }
        return nil
    }
    nonisolated private static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var cursor = pid
        for _ in 0..<10 {
            if cursor == ancestor { return true }
            var info = proc_bsdinfo(); let size = MemoryLayout<proc_bsdinfo>.size
            if proc_pidinfo(cursor, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size {
                cursor = pid_t(info.pbi_ppid)
            } else {
                // login is privileged: libproc may deny its details, while KERN_PROC_PID
                // still exposes the parent PID needed to verify the Terminal ancestor.
                var process = kinfo_proc(); var bytes = MemoryLayout<kinfo_proc>.stride
                var mib = [Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_PID), cursor]
                let result = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), &process, &bytes, nil, 0) }
                guard result == 0, bytes > 0 else { return false }
                cursor = process.kp_eproc.e_ppid
            }
            guard cursor > 1 else { return false }
        }
        return false
    }
}
