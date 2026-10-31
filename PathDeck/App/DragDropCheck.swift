import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

/// Actual AppKit data-source callbacks, pasteboards and queued filesystem operations.
/// Only the dragging info is supplied by the harness; no global mouse input is required.
@MainActor
enum DragDropCheck {
    @MainActor final class Info: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingSource: Any?
        let draggingSequenceNumber: Int
        var draggingSourceOperationMask: NSDragOperation
        var draggingDestinationWindow: NSWindow?
        var draggingLocation = NSPoint.zero
        var draggedImageLocation = NSPoint.zero
        nonisolated var draggedImage: NSImage? { nil }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        init(board: NSPasteboard, source: Any?, mask: NSDragOperation, window: NSWindow?) {
            draggingPasteboard = board; draggingSource = source; draggingSourceOperationMask = mask
            draggingDestinationWindow = window; draggingSequenceNumber = Self.nextSequence; Self.nextSequence += 1
        }
        private static var nextSequence = 100_000
    }
    static func run(browser original: BrowserViewController, fixture: URL) async -> [String: Bool] {
        var checks: [String: Bool] = [:], windows: [MainWindowController] = []
        let previousResolver = original.actions.operations.resolveConflict
        defer {
            windows.forEach { $0.window?.close() }
            original.actions.operations.resolveConflict = previousResolver
            original.view.window?.makeKeyAndOrderFront(nil)
        }
        do {
            let root = fixture.appendingPathComponent("Drag Drop", isDirectory: true), a = root.appendingPathComponent("Source", isDirectory: true), b = root.appendingPathComponent("Target", isDirectory: true), tree = root.appendingPathComponent("Tree", isDirectory: true)
            for url in [a, b, tree] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            let file = a.appendingPathComponent("中文 👋.txt"), folder = a.appendingPathComponent("Folder", isDirectory: true)
            try Data("payload".utf8).write(to: file); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("nested".utf8).write(to: folder.appendingPathComponent("leaf.txt"))
            for url in [a, b] {
                let window = MainWindowController(session: BrowserSession(initialDirectory: url), preferences: original.preferences, actionContext: original.actionContext)
                windows.append(window); window.showWindow(nil)
            }
            let source = windows[0].browser, target = windows[1].browser
            source.navigate(to: a); target.navigate(to: b); await source.waitForNavigation(); await target.waitForNavigation()
            source.fileList.windowsFriendly = true; target.fileList.windowsFriendly = true
            source.drops.modifierFlags = { [] }; target.drops.modifierFlags = { [] }
            let clipboard = source.actions.clipboard.pasteboard.changeCount
            let info = try sourceInfo(source, urls: [file, folder], target: target)
            let refs = source.fileList.fileDragState.references, before = target.actions.operations.records.count
            checks["dragWritesStandardFileURLs"] = Set(FileDragState.urls(in: info.draggingPasteboard)) == [file, folder]
            checks["dragHoverDoesNotWrite"] = validate(target, info) == .move && target.actions.operations.records.count == before && text(file) == "payload" && !FileManager.default.fileExists(atPath: b.appendingPathComponent(file.lastPathComponent).path)
            checks["emptyListRegistersFileDrops"] = (target.fileList.keyboardView as? NSTableView)?.registeredDraggedTypes.contains(.fileURL) == true
            checks["multiItemDropAccepted"] = accept(target, info); source.fileList.fileDragState.end()
            if let result = await finish(target) {
                checks["dropMovesFileAndFolder"] = result.successCount == 2 && text(b.appendingPathComponent(file.lastPathComponent)) == "payload" && text(b.appendingPathComponent("Folder/leaf.txt")) == "nested" && !FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: folder.path)
                checks["dropMovePreservesIdentities"] = refs.allSatisfy { (try? FileIdentity.read(b.appendingPathComponent($0.url.lastPathComponent))) == $0.identity }
            }
            let copy = a.appendingPathComponent("Copy.txt"); try Data("copy".utf8).write(to: copy)
            source.navigate(to: a); await source.waitForNavigation()
            let option = try sourceInfo(source, urls: [copy], target: target, mask: .copy)
            target.drops.modifierFlags = { [.option] }
            checks["optionDragCopies"] = validate(target, option) == .copy && accept(target, option); source.fileList.fileDragState.end()
            if let result = await finish(target) { checks["optionCopyKeepsSource"] = result.successCount == 1 && text(copy) == "copy" && text(b.appendingPathComponent("Copy.txt")) == "copy" }
            original.actions.operations.resolveConflict = { _ in ConflictDecision(.keepBoth) }
            let control = try sourceInfo(source, urls: [copy], target: target)
            target.drops.modifierFlags = { [.control] }
            checks["controlDragCopiesInWindowsMode"] = validate(target, control) == .copy && accept(target, control); source.fileList.fileDragState.end()
            if let result = await finish(target) { checks["dropConflictKeepsBoth"] = result.successCount == 1 && text(copy) == "copy" && text(b.appendingPathComponent("Copy (2).txt")) == "copy" }
            let inside = b.appendingPathComponent("Inside", isDirectory: true); try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
            target.navigate(to: b); await target.waitForNavigation(); target.drops.modifierFlags = { [] }
            let row = try Self.row(target, url: inside), intoFolder = try sourceInfo(source, urls: [copy], target: target)
            checks["folderRowAcceptsDrop"] = validate(target, intoFolder, row: row) == .move && accept(target, intoFolder, row: row)
            source.fileList.fileDragState.end(); target.navigate(to: tree); await target.waitForNavigation()
            if let result = await finish(target) { checks["dropTargetSurvivesNavigation"] = result.successCount == 1 && text(inside.appendingPathComponent("Copy.txt")) == "copy" && target.session.currentDirectory == tree && !FileManager.default.fileExists(atPath: tree.appendingPathComponent("Copy.txt").path) }
            let treeFile = a.appendingPathComponent("Tree.txt"); try Data("tree".utf8).write(to: treeFile)
            source.navigate(to: a); await source.waitForNavigation()
            target.sidebar.pin(b); await target.sidebar.waitForAvailability(); target.sidebar.synchronize(to: b, showHidden: false); await target.waitForSidebar()
            _ = await ReliabilityCheck.eventually { await target.waitForNavigation(); return target.drops.canStart }
            let outline = try require(target.sidebar.keyboardView as? NSOutlineView)
            let item = try require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) }.first {
                (target.sidebar.outlineView(outline, pasteboardWriterForItem: $0) as? NSURL)?.path == b.path
            })
            let toTree = try sourceInfo(source, urls: [treeFile], target: target)
            checks["treeDirectoryAcceptsDrop"] = target.sidebar.outlineView(outline, validateDrop: toTree, proposedItem: item, proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move && target.sidebar.outlineView(outline, acceptDrop: toTree, item: item, childIndex: NSOutlineViewDropOnItemIndex)
            source.fileList.fileDragState.end()
            if let result = await finish(target) { checks["treeDropUsesHighlightedFolder"] = result.successCount == 1 && text(b.appendingPathComponent("Tree.txt")) == "tree" && !FileManager.default.fileExists(atPath: treeFile.path) }
            let writer = try require(target.sidebar.outlineView(outline, pasteboardWriterForItem: item)), treeBoard = board()
            treeBoard.writeObjects([writer]); target.sidebar.fileDragState.begin(pasteboard: treeBoard)
            let treeExport = Info(board: treeBoard, source: outline, mask: .copy, window: source.view.window)
            source.drops.modifierFlags = { [.option] }
            checks["treeExportsStandardDirectoryURL"] = FileDragState.urls(in: treeBoard) == [b] && validate(source, treeExport) == .copy
            target.sidebar.fileDragState.end(); source.drops.modifierFlags = { [] }; target.sidebar.removeFavorite(b)
            let external = root.appendingPathComponent("External.txt"); try Data("external".utf8).write(to: external)
            let externalBoard = board(); externalBoard.writeObjects([external as NSURL])
            let incoming = Info(board: externalBoard, source: nil, mask: [.copy, .move], window: target.view.window)
            checks["externalDragDefaultsToCopy"] = validate(target, incoming) == .copy && accept(target, incoming)
            checks["dropPreparationCountsAsBusy"] = target.actions.context.isBusy
            if let result = await finish(target) { checks["externalDropCopiesRealContents"] = result.successCount == 1 && text(external) == "external" && text(tree.appendingPathComponent("External.txt")) == "external" }
            let cancel = Info(board: externalBoard, source: nil, mask: [.copy, .move], window: target.view.window), jobs = target.actions.operations.records.count
            _ = validate(target, cancel); _ = accept(target, cancel); target.actions.context.cancelAll()
            let cancelled = await target.drops.waitForPreparation()
            checks["cancelPreparingDropPreservesFiles"] = cancelled == nil && target.actions.operations.records.count == jobs && !target.actions.context.isBusy && text(external) == "external"
            let replaced = a.appendingPathComponent("Replaced.txt"); try Data("original".utf8).write(to: replaced)
            source.navigate(to: a); await source.waitForNavigation()
            let stale = try sourceInfo(source, urls: [replaced], target: target); _ = validate(target, stale)
            let kept = root.appendingPathComponent("Kept.txt"); try FileManager.default.moveItem(at: replaced, to: kept); try Data("replacement".utf8).write(to: replaced)
            _ = accept(target, stale); source.fileList.fileDragState.end()
            if let result = await finish(target) { checks["replacedDragSourceIsProtected"] = result.failureCount == 1 && text(replaced) == "replacement" && text(kept) == "original" && !FileManager.default.fileExists(atPath: tree.appendingPathComponent("Replaced.txt").path) }
            let changing = tree.appendingPathComponent("Changing", isDirectory: true)
            try FileManager.default.createDirectory(at: changing, withIntermediateDirectories: false)
            source.navigate(to: a); target.navigate(to: tree); await source.waitForNavigation(); await target.waitForNavigation()
            let changingRow = try Self.row(target, url: changing), staleTarget = try sourceInfo(source, urls: [replaced], target: target)
            _ = validate(target, staleTarget, row: changingRow)
            try FileManager.default.moveItem(at: changing, to: root.appendingPathComponent("Kept target", isDirectory: true))
            try FileManager.default.createDirectory(at: changing, withIntermediateDirectories: false)
            _ = accept(target, staleTarget, row: changingRow); source.fileList.fileDragState.end()
            if let result = await finish(target) { checks["replacedDropTargetIsProtected"] = result.failureCount == 1 && text(replaced) == "replacement" && !FileManager.default.fileExists(atPath: changing.appendingPathComponent("Replaced.txt").path) }
            try FileManager.default.createDirectory(at: tree.appendingPathComponent("ZZZ", isDirectory: true), withIntermediateDirectories: false)
            source.navigate(to: a); target.navigate(to: tree); await source.waitForNavigation(); await target.waitForNavigation()
            target.session.changeSort(FileSort(column: .name, ascending: true))
            let oldRow = try Self.row(target, url: changing), reordered = try sourceInfo(source, urls: [replaced], target: target)
            _ = validate(target, reordered, row: oldRow)
            let jobsBeforeSort = target.actions.operations.records.count
            target.session.changeSort(FileSort(column: .name, ascending: false))
            checks["reorderedRowsCannotChangeDropTarget"] = !accept(target, reordered, row: oldRow) && jobsBeforeSort == target.actions.operations.records.count && text(replaced) == "replacement"
            source.fileList.fileDragState.end()
            let closingFile = root.appendingPathComponent("Close window.txt"); try Data("close payload".utf8).write(to: closingFile)
            var closingWindow: MainWindowController? = MainWindowController(session: BrowserSession(initialDirectory: tree), preferences: original.preferences, actionContext: original.actionContext)
            closingWindow?.showWindow(nil); closingWindow?.browser.navigate(to: tree); await closingWindow?.browser.waitForNavigation()
            let closingDrops = try require(closingWindow?.browser.drops)
            let closingBoard = board(); closingBoard.writeObjects([closingFile as NSURL])
            let closingInfo = Info(board: closingBoard, source: nil, mask: .copy, window: closingWindow?.window)
            let closingBrowser = try require(closingWindow?.browser)
            _ = validate(closingBrowser, closingInfo); checks["closingWindowDropIsAccepted"] = accept(closingBrowser, closingInfo)
            closingWindow?.window?.close(); closingWindow = nil; closingInfo.draggingDestinationWindow = nil
            if let id = await closingDrops.waitForPreparation() {
                let result = await original.actions.operations.wait(for: id)
                checks["acceptedDropSurvivesWindowClose"] = result.successCount == 1 && text(closingFile) == "close payload" && text(tree.appendingPathComponent("Close window.txt")) == "close payload"
            } else { checks["acceptedDropSurvivesWindowClose"] = false }
            source.navigate(to: a); await source.waitForNavigation()
            let noOp = try sourceInfo(source, urls: [replaced], target: source)
            checks["sameDirectoryMoveIsRejected"] = validate(source, noOp).isEmpty && !accept(source, noOp); source.fileList.fileDragState.end()
            let child = a.appendingPathComponent("Parent/Child", isDirectory: true); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            source.navigate(to: a); await source.waitForNavigation(); target.navigate(to: child); await target.waitForNavigation()
            let unsafe = try sourceInfo(source, urls: [a.appendingPathComponent("Parent", isDirectory: true)], target: target)
            checks["descendantDropIsRejected"] = validate(target, unsafe).isEmpty && !accept(target, unsafe); source.fileList.fileDragState.end()
            let count = target.actions.operations.records.count, escaped = try sourceInfo(source, urls: [replaced], target: target)
            _ = validate(target, escaped); source.fileList.fileDragState.end()
            checks["endingDragWithoutDropDoesNotWrite"] = count == target.actions.operations.records.count && text(replaced) == "replacement"
            checks["dragLeavesClipboardUntouched"] = source.actions.clipboard.pasteboard.changeCount == clipboard
            checks["dragQueueFinishesIdle"] = !target.actions.context.isBusy
            target.actions.panel.window?.close()
        } catch { checks["dragFixtureAndCallbacks"] = false; fputs("Drag/drop check: \(error)\n", stderr) }
        return checks
    }
    private static func row(_ browser: BrowserViewController, url: URL) throws -> Int { try require(browser.session.visibleItems.firstIndex { $0.url.path == url.path }) }
    static func sourceInfo(_ source: BrowserViewController, urls: [URL], target: BrowserViewController, mask: NSDragOperation = [.copy, .move]) throws -> Info {
        let table = try require(source.fileList.keyboardView as? NSTableView), pasteboard = board()
        let writers = try urls.map { try require(source.fileList.tableView(table, pasteboardWriterForRow: row(source, url: $0))) }
        pasteboard.writeObjects(writers); source.fileList.fileDragState.begin(pasteboard: pasteboard)
        return Info(board: pasteboard, source: table, mask: mask, window: target.view.window)
    }
    private static func validate(_ target: BrowserViewController, _ info: Info, row: Int = -1) -> NSDragOperation { target.fileList.tableView(target.fileList.keyboardView as! NSTableView, validateDrop: info, proposedRow: row, proposedDropOperation: .on) }
    private static func accept(_ target: BrowserViewController, _ info: Info, row: Int = -1) -> Bool { target.fileList.tableView(target.fileList.keyboardView as! NSTableView, acceptDrop: info, row: row, dropOperation: .on) }
    private static func finish(_ target: BrowserViewController) async -> FileOperationRecord? {
        guard let id = await target.drops.waitForPreparation() else { return nil }
        let result = await target.actions.wait(for: id); await target.waitForNavigation(); return result
    }
    private static func board() -> NSPasteboard { NSPasteboard(name: .init("PathDeck-drag-test-\(UUID().uuidString)")) }
    private static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private static func require<T>(_ value: T?, line: UInt = #line) throws -> T { guard let value else { throw NSError(domain: "PathDeck.DragCheck", code: Int(line), userInfo: [NSLocalizedDescriptionKey: "缺少测试值，行号 \(line)"]) }; return value }
}
