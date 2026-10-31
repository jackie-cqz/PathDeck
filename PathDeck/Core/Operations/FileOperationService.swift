import Foundation
import Darwin

@MainActor
public final class FileOperationService {
    public private(set) var records: [FileOperationRecord] = []
    public var onChange: (() -> Void)?
    public var onComplete: ((FileOperationRecord) -> Void)?
    public var onIdle: (() -> Void)?
    public var resolveConflict: ((FileConflict) async -> ConflictDecision)?
    public let engine: FileOperationEngine
    private var pending: [UUID] = []
    private var cancellations: [UUID: OperationCancellation] = [:]
    private var waiters: [UUID: [CheckedContinuation<FileOperationRecord, Never>]] = [:]
    private var worker: Task<Void, Never>?
    public var isBusy: Bool { records.contains { !$0.state.isTerminal } }
    public init(engine: FileOperationEngine = FileOperationEngine()) { self.engine = engine }

    public func recover() async throws {
        let recovered = try await engine.recover(); let current = Set(records.map(\.id))
        records = recovered.filter { !current.contains($0.id) } + records; onChange?()
    }
    @discardableResult public func submit(_ request: FileOperationRequest) -> UUID {
        records.append(FileOperationRecord(request: request)); pending.append(request.id)
        cancellations[request.id] = OperationCancellation(); onChange?()
        if worker == nil { worker = Task { await self.drain() } }
        return request.id
    }
    public func cancel(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id && !$0.state.isTerminal }) else { return }
        cancellations[id]?.cancel(); records[index].state = .cancelRequested; onChange?()
    }
    public func cancelAll() { for record in records where !record.state.isTerminal { cancel(record.id) } }
    public func wait(for id: UUID) async -> FileOperationRecord {
        if let record = records.first(where: { $0.id == id }), record.state.isTerminal { return record }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    private func update(_ record: FileOperationRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }; onChange?()
    }
    private func drain() async {
        while !pending.isEmpty {
            let id = pending.removeFirst()
            guard var record = records.first(where: { $0.id == id }), let token = cancellations[id] else { continue }
            var batchDecision: ConflictDecision?
            let sources: [FileReference?] = record.request.sources.isEmpty ? [nil] : record.request.sources.map(Optional.some)
            for source in sources {
                if token.isCancelled { break }
                record.state = .preparing; record.currentName = source?.url.lastPathComponent ?? record.request.name ?? record.request.kind.title; update(record)
                var name = record.request.name ?? source?.url.lastPathComponent
                let original = name ?? ""; var number = 2
                while !token.isCancelled {
                    record.state = .running; update(record)
                    let step = await engine.execute(record, source: source, name: name, cancellation: token)
                    record.artifacts = step.artifacts
                    if let result = step.result { record.results.append(result); break }
                    guard let conflict = step.conflict else { break }
                    if record.request.kind == .rename {
                        record.results.append(FileOperationResult(source: source?.url, destination: conflict, outcome: .failed, message: "原位置名称已存在，未覆盖；请处理占用后重试。")); break
                    }
                    record.state = .waitingForDecision; update(record)
                    let decision: ConflictDecision
                    if let batchDecision { decision = batchDecision }
                    else if [.newFolder, .newTextFile].contains(record.request.kind) { decision = ConflictDecision(.keepBoth) }
                    else { decision = await resolveConflict?(FileConflict(source: source?.url, destination: conflict)) ?? ConflictDecision(.skip) }
                    if decision.applyToRemaining { batchDecision = decision }
                    switch decision.action {
                    case .cancel: token.cancel()
                    case .skip: record.results.append(FileOperationResult(source: source?.url, destination: conflict, outcome: .skipped, message: "已跳过同名项目。"))
                    case .keepBoth:
                        name = FileOperationEngine.alternativeName(original, number: number, isDirectory: record.request.kind == .newFolder || source?.identity?.mode == S_IFDIR); number += 1
                        if number < 10_000 { continue }
                        record.results.append(FileOperationResult(source: source?.url, destination: conflict, outcome: .failed, message: "无法生成可用名称。"))
                    }
                    break
                }
            }
            if token.isCancelled { record.state = .cancelled }
            else if record.failureCount > 0 { record.state = record.successCount > 0 ? .completedWithErrors : .failed }
            else { record.state = .completed }
            do { try await engine.persist(record) }
            catch { record.results.append(FileOperationResult(source: nil, destination: nil, outcome: .failed, message: "记录最终状态失败：\(error.localizedDescription)")); record.state = record.successCount > 0 ? .completedWithErrors : .failed }
            update(record); cancellations[id] = nil
            for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: record) }
            onComplete?(record)
        }
        worker = nil; onIdle?()
    }
}
