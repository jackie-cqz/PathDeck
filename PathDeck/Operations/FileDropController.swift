import AppKit
#if SWIFT_PACKAGE
import PathDeckCore
#endif

@MainActor
final class FileDropController {
    private struct Payload {
        let references: [FileReference]
        let internalDrag: Bool
    }
    private let actions: FileActionController
    private var cachedKey: String?
    private var cachedPayload: Payload?
    private var preparationTask: Task<UUID?, Never>?
    var modifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    init(actions: FileActionController) { self.actions = actions }
    var canStart: Bool { actions.canWrite && actions.browser?.fileList.isRenaming == false }
    private func payload(_ info: any NSDraggingInfo) -> Payload? {
        let key = "\(info.draggingSequenceNumber):\(info.draggingPasteboard.changeCount)"
        if key == cachedKey { return cachedPayload }
        let urls = FileDragState.urls(in: info.draggingPasteboard)
        let payload: Payload?
        if let source = info.draggingSource as? any FileDragSource {
            let refs = source.fileDragState.references
            payload = source.fileDragState.isActive && !refs.isEmpty && Set(refs.map { $0.url.standardizedFileURL }) == Set(urls.map(\.standardizedFileURL)) ? Payload(references: refs, internalDrag: true) : nil
        } else {
            payload = urls.isEmpty ? nil : Payload(references: urls.map { FileReference(url: $0, identity: nil) }, internalDrag: false)
        }
        cachedKey = key; cachedPayload = payload; return payload
    }
    private func kind(_ info: any NSDraggingInfo, destination: FileReference) -> FileOperationKind? {
        guard canStart, let payload = payload(info) else { return nil }
        let flags = modifierFlags()
        guard !(flags.contains(.option) && flags.contains(.command)) else { return nil }
        let intent: FileDropPolicy.Intent
        if flags.contains(.option) || (actions.browser?.fileList.windowsFriendly == true && flags.contains(.control)) { intent = .copy }
        else if flags.contains(.command) { intent = .move }
        else { intent = .automatic }
        return FileDropPolicy.operation(sources: payload.references, destination: destination, internalDrag: payload.internalDrag,
                                        permitsCopy: info.draggingSourceOperationMask.contains(.copy), permitsMove: info.draggingSourceOperationMask.contains(.move), intent: intent)
    }
    func validate(_ info: any NSDraggingInfo, destination: FileReference) -> NSDragOperation {
        guard let operation = kind(info, destination: destination) else { return [] }
        return operation == .move ? .move : .copy
    }
    func accept(_ info: any NSDraggingInfo, destination: FileReference) -> Bool {
        guard let kind = kind(info, destination: destination), let payload = payload(info) else { return false }
        // Preparation is busy work too: Quit must wait even while external identities are captured.
        let actions = actions, context = actions.context
        let (id, cancellation) = context.beginPreparation()
        preparationTask = Task {
            defer { context.endPreparation(id) }
            if cancellation.isCancelled { return nil }
            let references = payload.internalDrag ? payload.references : await actions.operations.engine.capture(payload.references.map(\.url))
            if cancellation.isCancelled { actions.lastMessage = "拖放已取消"; actions.onStatusChange?(); return nil }
            return context.submit(.init(kind: kind, sources: references, destination: destination), owner: actions)
        }
        return true
    }
    func waitForPreparation() async -> UUID? { await preparationTask?.value }
}
