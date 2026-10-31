import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

/// One queue, journal, task panel and cut intent for the application, shared by all pages.
@MainActor
final class FileActionContext {
    private final class Observer { weak var value: FileActionController?; init(_ value: FileActionController) { self.value = value } }
    let operations: FileOperationService
    let clipboard: ClipboardService
    let panel: OperationsWindowController
    private var observers: [Observer] = []
    private var owners: [UUID: FileActionController] = [:]
    private var monitoring: Set<ObjectIdentifier> = []
    var isBusy: Bool { operations.isBusy }
    var onIdle: (() -> Void)?
    private var controllers: [FileActionController] { observers.compactMap(\.value) }
    var presentationWindow: NSWindow? {
        if let window = controllers.compactMap({ $0.browser?.viewIfLoaded?.window }).first(where: \.isMainWindow) ?? controllers.compactMap({ $0.browser?.viewIfLoaded?.window }).first(where: \.isVisible) { return window }
        panel.update(); panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil); return panel.window
    }
    init() {
        let journal = RuntimeContext.isTesting ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("PathDeck/Operations", isDirectory: true)
        operations = FileOperationService(engine: FileOperationEngine(journalDirectory: journal))
        clipboard = ClipboardService(pasteboard: RuntimeContext.isTesting ? NSPasteboard(name: .init("PathDeck-test-\(UUID().uuidString)")) : .general)
        panel = OperationsWindowController(service: operations)
        operations.onChange = { [weak self] in self?.panel.update(); self?.controllers.forEach { $0.onStatusChange?() } }
        operations.onIdle = { [weak self] in self?.reportIdle() }
        operations.resolveConflict = { [weak self] conflict in
            guard let self, let id = self.operations.records.first(where: { $0.state == .waitingForDecision })?.id, let owner = self.owners[id] else { return ConflictDecision(.cancel) }
            return await owner.resolve(conflict)
        }
        operations.onComplete = { [weak self] record in
            guard let self else { return }
            let owner = self.owners.removeValue(forKey: record.id)
            owner?.receive(record)
            for controller in self.controllers where controller !== owner { controller.externalCompletion(record) }
        }
        clipboard.onChange = { [weak self] in self?.controllers.forEach { $0.clipboardChanged() } }
        panel.onCancel = { [weak self] id in self?.owners[id]?.cancel(id) }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.operations.recover()
                if self.operations.records.contains(where: { $0.state == .interruptedUnknown || !$0.artifacts.isEmpty }) { self.panel.showWindow(nil) }
            } catch { self.controllers.forEach { $0.lastMessage = "无法读取任务记录：\(error.localizedDescription)"; $0.onStatusChange?() } }
        }
    }
    func register(_ controller: FileActionController) { observers.removeAll { $0.value == nil }; observers.append(Observer(controller)) }
    func setMonitoring(_ active: Bool, for controller: FileActionController) {
        if active { monitoring.insert(ObjectIdentifier(controller)) } else { monitoring.remove(ObjectIdentifier(controller)) }
        if monitoring.isEmpty { clipboard.stopMonitoring() } else { clipboard.startMonitoring() }
    }
    func submit(_ request: FileOperationRequest, owner: FileActionController) -> UUID {
        let id = operations.submit(request); owners[id] = owner; return id
    }
    private func reportIdle() { guard !isBusy else { return }; controllers.forEach { $0.onIdle?() }; onIdle?() }
    func cancelAll() {
        for record in operations.records where !record.state.isTerminal { owners[record.id]?.cancel(record.id) }
    }
}
