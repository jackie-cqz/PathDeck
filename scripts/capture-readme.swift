import AppKit

/// Builds with the real application sources; exports only this process's views.
@MainActor
private final class ReadmeCapture: NSObject, NSApplicationDelegate {
    private var windows: [MainWindowController] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await capture(); fflush(stdout); exit(0) }
            catch { fputs("README capture: \(error)\n", stderr); exit(1) }
        }
    }
    private func capture() async throws {
        guard RuntimeContext.isTesting, let output = ProcessInfo.processInfo.environment["PATHDECK_README_OUTPUT"] else { throw CocoaError(.fileWriteNoPermission) }
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("PathDeck-Demo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: fixture) }
        let workspace = fixture.appendingPathComponent("Workspace", isDirectory: true)
        let projects = workspace.appendingPathComponent("Projects", isDirectory: true)
        let outputDirectory = URL(fileURLWithPath: output, isDirectory: true)
        for path in [projects, outputDirectory] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        for name in ["Archive", "Assets", "Documents", "Examples", "Screenshots"] { try fm.createDirectory(at: projects.appendingPathComponent(name), withIntermediateDirectories: true) }
        let files = ["README.md": "# PathDeck\nA native file manager for macOS.\n", "Package.swift": "// A sample Swift package manifest.\n", "Design notes.md": "# Design notes\nClear paths. Familiar controls.\n", "Getting started.txt": "Press Command-L to enter a folder path.\n", "Project brief.md": "# Project brief\nA small workspace for screenshot examples.\n", "Release checklist.md": "# Release checklist\nReview files before moving them.\n", "meeting-notes.txt": "Sample notes for this demonstration workspace.\n", "tasks.csv": "Task,Status\nReview screenshots,Done\nUpdate documentation,Done\n"]
        for (name, contents) in files { try Data(contents.utf8).write(to: projects.appendingPathComponent(name)) }
        let preferences = PreferencesController(store: PreferencesStore(url: fixture.appendingPathComponent("settings.json")))
        preferences.value.favorites = [workspace.path, projects.path, projects.appendingPathComponent("Documents").path, projects.appendingPathComponent("Assets").path]
        preferences.value.favoriteNames = [workspace.path: "Workspace", projects.path: "Projects", projects.appendingPathComponent("Documents").path: "Documents", projects.appendingPathComponent("Assets").path: "Assets"]
        let context = FileActionContext()
        let main = MainWindowController(session: BrowserSession(initialDirectory: projects), preferences: preferences, actionContext: context)
        windows.append(main); main.showWindow(nil); main.window?.makeKeyAndOrderFront(nil); main.window?.makeMain()
        NSApp.activate()
        await main.browser.waitForNavigation(); await main.browser.waitForSidebar()
        guard let window = main.window else { throw CocoaError(.fileReadUnknown) }
        window.setContentSize(NSSize(width: 1100, height: 650))
        _ = await ReliabilityCheck.eventually { window.isKeyWindow }
        main.browser.fileList.focus()
        try await export(window, name: "overview-light", appearance: .aqua, to: outputDirectory)
        try await export(window, name: "overview-dark", appearance: .darkAqua, to: outputDirectory)

        window.appearance = NSAppearance(named: .aqua)
        main.browser.addressBar.beginEditing()
        try await export(window, name: "path-entry", appearance: .aqua, to: outputDirectory)
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        main.browser.fileList.focus()

        main.browser.session.setFilter("notes")
        try await export(window, name: "name-filter", appearance: .aqua, to: outputDirectory)
        main.browser.session.setFilter("")
        let reference = try FileReference.capture(projects.appendingPathComponent("Project brief.md"))
        await main.browser.waitForNavigation()
        main.browser.actions.beginRename([reference])
        guard main.browser.fileList.isRenaming else { throw CocoaError(.fileWriteUnknown) }
        try await export(window, name: "inline-rename", appearance: .aqua, to: outputDirectory)
        main.browser.fileList.cancelRename(); main.browser.fileList.focus()

        let properties = FilePropertiesWindowController(urls: [projects.appendingPathComponent("README.md")])
        properties.showWindow(nil); await properties.waitForLoad()
        if let propertyWindow = properties.window { try await export(propertyWindow, name: "file-properties", appearance: .aqua, to: outputDirectory) }
        properties.window?.close()
        for controller in windows { controller.browser.stopMonitoring(); controller.window?.close() }
        await preferences.flush()
        print("Exported six native AppKit screenshots to \(outputDirectory.path)")
    }
    private func export(_ window: NSWindow, name: String, appearance: NSAppearance.Name, to directory: URL) async throws {
        // Selection vibrancy is composed outside cacheDisplay; leave the tree unselected.
        for controller in windows { (controller.browser.sidebar.keyboardView as? NSOutlineView)?.deselectAll(nil) }
        window.appearance = NSAppearance(named: appearance)
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

@main
private enum ReadmeCaptureApplication {
    @MainActor static func main() {
        let app = NSApplication.shared, delegate = ReadmeCapture()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
