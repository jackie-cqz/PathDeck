import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class FileActionController {
    private(set) weak var browser: BrowserViewController?
    let context: FileActionContext
    var operations: FileOperationService { context.operations }
    var clipboard: ClipboardService { context.clipboard }
    var panel: OperationsWindowController { context.panel }
    var onStatusChange: (() -> Void)?
    var onIdle: (() -> Void)?
    var confirmTrash: (([FileReference]) async -> Bool)?
    private var pasteSnapshots: [UUID: ClipboardSnapshot] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var renameParent: FileReference?
    private var conflictSheet: NSWindow?
    private var conflictID: UUID?
    var lastMessage = ""

    init(browser: BrowserViewController, context: FileActionContext) {
        self.browser = browser
        self.context = context; context.register(self)
    }
    func clipboardChanged() { browser?.fileList.setCutURLs(clipboard.cutURLs); onStatusChange?() }
    func receive(_ record: FileOperationRecord) {
        if let snapshot = pasteSnapshots.removeValue(forKey: record.id) { clipboard.complete(snapshot, record: record) }
        refreshTasks[record.id] = Task { [weak self] in await self?.completed(record); self?.refreshTasks[record.id] = nil }
    }
    func externalCompletion(_ record: FileOperationRecord) { Task { [weak self] in await self?.browser?.refreshAfterOperation(record) } }
    var canWrite: Bool { browser?.isNavigating == false && browser?.session.contentState == .loaded && browser?.session.directoryReference != nil }
    var summary: String {
        if let active = operations.records.first(where: { !$0.state.isTerminal }) { return "\(active.request.kind.title)：\(active.state.title) · \(active.results.count)/\(active.total)" }
        if context.isPreparing { return "正在准备拖放任务…" }
        return lastMessage
    }
    @discardableResult func create(_ kind: FileOperationKind, destination explicit: FileReference? = nil) -> UUID? {
        guard canWrite, let destination = explicit ?? browser?.session.directoryReference else { return nil }
        return context.submit(.init(kind: kind, destination: destination, name: kind == .newFolder ? "新建文件夹" : "Untitled.txt"), owner: self)
    }
    func beginRename(_ references: [FileReference]) {
        guard canWrite, let browser, references.count == 1, let parent = browser.session.directoryReference else { return }
        renameParent = parent
        browser.fileList.beginRename(references[0])
    }
    @discardableResult func rename(_ reference: FileReference, to name: String) -> UUID? {
        guard let parent = renameParent ?? browser?.session.directoryReference else { return nil }
        renameParent = nil
        return context.submit(.init(kind: .rename, sources: [reference], destination: parent, name: name), owner: self)
    }
    func copy(_ references: [FileReference], cut: Bool) {
        guard !references.isEmpty, browser?.isNavigating == false, references.allSatisfy({ $0.identity != nil }) else { return }
        clipboard.write(references, cut: cut)
    }
    @discardableResult func paste(destination explicit: FileReference? = nil) async -> UUID? {
        guard canWrite, let destination = explicit ?? browser?.session.directoryReference else { return nil }
        do {
            let snapshot = try await clipboard.snapshot(using: operations.engine)
            let id = context.submit(.init(kind: snapshot.kind, sources: snapshot.sources, destination: destination), owner: self)
            pasteSnapshots[id] = snapshot
            return id
        } catch { lastMessage = error.localizedDescription; onStatusChange?(); return nil }
    }
    @discardableResult func trash(_ references: [FileReference]) async -> UUID? {
        guard canWrite, !references.isEmpty else { return nil }
        let confirmed: Bool
        if let confirmTrash { confirmed = await confirmTrash(references) }
        else {
            let alert = NSAlert(); alert.messageText = "将 \(references.count) 个项目移入废纸篓？"
            alert.informativeText = references.prefix(6).map { $0.url.lastPathComponent }.joined(separator: "\n") + (references.count > 6 ? "\n…" : "")
            alert.addButton(withTitle: "移入废纸篓"); alert.addButton(withTitle: "取消")
            confirmed = await response(to: alert) == .alertFirstButtonReturn
        }
        guard confirmed else { return nil }
        return context.submit(.init(kind: .trash, sources: references), owner: self)
    }
    func wait(for id: UUID) async -> FileOperationRecord {
        let result = await operations.wait(for: id)
        await refreshTasks[id]?.value
        refreshTasks[id] = nil
        return result
    }
    func cancel(_ id: UUID) {
        operations.cancel(id)
        if conflictID == id, let sheet = conflictSheet { sheet.sheetParent?.endSheet(sheet, returnCode: .abort) }
    }
    func cancelAll() { for record in operations.records where !record.state.isTerminal { cancel(record.id) } }
    func showTasks() { panel.update(); panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil) }
    private func completed(_ record: FileOperationRecord) async {
        lastMessage = "\(record.request.kind.title)：\(record.state.title) · 成功 \(record.successCount)、跳过 \(record.skippedCount)、失败 \(record.failureCount)"
        guard let browser else { return }
        await browser.refreshAfterOperation(record)
        if record.failureCount > 0 || !record.artifacts.isEmpty { showTasks() }
        if [.newFolder, .newTextFile].contains(record.request.kind), let created = record.results.first(where: { $0.outcome == .succeeded })?.destination,
           !browser.isNavigating,
           record.request.destination?.identity == browser.session.directoryReference?.identity,
           let item = browser.session.items.first(where: { $0.url.path == created.path }) {
            browser.session.setFilter("")
            renameParent = browser.session.directoryReference; browser.fileList.beginRename(item.reference)
        }
        onStatusChange?()
    }
    func resolve(_ conflict: FileConflict) async -> ConflictDecision {
        let alert = NSAlert(); alert.messageText = "目标已存在：\(conflict.destination.lastPathComponent)"
        alert.informativeText = "\(conflict.destination.deletingLastPathComponent().path)\n目录冲突会按整个目录处理。"
        alert.addButton(withTitle: "跳过"); alert.addButton(withTitle: "保留两份"); alert.addButton(withTitle: "取消剩余任务")
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = "应用于本批次剩余冲突"
        conflictSheet = alert.window; conflictID = operations.records.first(where: { $0.state == .waitingForDecision })?.id
        let result = await response(to: alert)
        conflictSheet = nil; conflictID = nil
        return ConflictDecision(result == .alertFirstButtonReturn ? .skip : result == .alertSecondButtonReturn ? .keepBoth : .cancel, applyToRemaining: alert.suppressionButton?.state == .on)
    }
    private func response(to alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = browser?.viewIfLoaded?.window?.isVisible == true ? browser?.viewIfLoaded?.window : context.presentationWindow else { return .abort }
        return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
    }
}
