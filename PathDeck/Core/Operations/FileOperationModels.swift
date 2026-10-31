import Foundation
import Darwin

public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64
    public let mode: UInt16
    public static func read(_ url: URL) throws -> FileIdentity {
        var value = stat()
        guard url.isFileURL, url.withUnsafeFileSystemRepresentation({ path in path.map { lstat($0, &value) } ?? -1 }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileIdentity(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino), birthSeconds: Int64(value.st_birthtimespec.tv_sec), birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec), mode: value.st_mode & S_IFMT)
    }
}

public struct FileReference: Codable, Equatable, Sendable {
    public let url: URL
    public let identity: FileIdentity?
    public init(url: URL, identity: FileIdentity?) { self.url = url; self.identity = identity }
    public static func capture(_ url: URL) throws -> FileReference { FileReference(url: url, identity: try FileIdentity.read(url)) }
    public func verify() throws {
        guard let identity, try FileIdentity.read(url) == identity else { throw FileOperationError.changed(url) }
    }
}

public enum FileOperationKind: String, Codable, Sendable {
    case newFolder, newTextFile, rename, copy, move, trash
    public var title: String {
        switch self {
        case .newFolder: "新建文件夹"
        case .newTextFile: "新建文本文件"
        case .rename: "重命名"
        case .copy: "复制"
        case .move: "移动"
        case .trash: "移入废纸篓"
        }
    }
}
public struct FileOperationRequest: Codable, Sendable {
    public let id: UUID
    public let kind: FileOperationKind
    public let sources: [FileReference]
    public let destination: FileReference?
    public let name: String?
    public init(kind: FileOperationKind, sources: [FileReference] = [], destination: FileReference? = nil, name: String? = nil) {
        id = UUID(); self.kind = kind; self.sources = sources; self.destination = destination; self.name = name
    }
}
public enum FileOperationState: String, Codable, Sendable {
    case queued, preparing, waitingForDecision, running, cancelRequested
    case completed, completedWithErrors, cancelled, failed, interruptedUnknown
    public var isTerminal: Bool { [.completed, .completedWithErrors, .cancelled, .failed, .interruptedUnknown].contains(self) }
    public var title: String {
        switch self {
        case .queued: "排队中"
        case .preparing: "准备中"
        case .waitingForDecision: "等待处理冲突"
        case .running: "正在处理当前项目"
        case .cancelRequested: "已请求取消，等待当前项目结束"
        case .completed: "已完成"
        case .completedWithErrors: "部分完成"
        case .cancelled: "已取消剩余任务"
        case .failed: "失败"
        case .interruptedUnknown: "上次任务已中断，结果待核实"
        }
    }
}
public struct FileOperationResult: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case succeeded, skipped, failed, cancelled }
    public let source: URL?
    public let destination: URL?
    public let outcome: Outcome
    public let message: String
    public init(source: URL?, destination: URL?, outcome: Outcome, message: String = "") {
        self.source = source; self.destination = destination; self.outcome = outcome; self.message = message
    }
}
public struct FileOperationRecord: Codable, Sendable, Identifiable {
    public var id: UUID { request.id }
    public let request: FileOperationRequest
    public var createdAt = Date()
    public var state: FileOperationState = .queued
    public var results: [FileOperationResult] = []
    public var artifacts: [URL] = []
    public var currentName = ""
    public var total: Int { max(request.sources.count, 1) }
    public var successCount: Int { results.filter { $0.outcome == .succeeded }.count }
    public var failureCount: Int { results.filter { $0.outcome == .failed }.count }
    public var skippedCount: Int { results.filter { $0.outcome == .skipped }.count }
    public init(request: FileOperationRequest) { self.request = request }
}
public struct FileConflict: Sendable {
    public let source: URL?
    public let destination: URL
}
public struct ConflictDecision: Sendable {
    public enum Action: Sendable { case skip, keepBoth, cancel }
    public let action: Action
    public let applyToRemaining: Bool
    public init(_ action: Action, applyToRemaining: Bool = false) { self.action = action; self.applyToRemaining = applyToRemaining }
}
public enum FileOperationError: Error, LocalizedError {
    case invalidName, changed(URL), conflict(URL), descendant, crossVolume, unsupported, cancelled, residual(URL, String)
    public var errorDescription: String? {
        switch self {
        case .invalidName: "名称不能为空、.、..，也不能包含 / 或 NUL。"
        case .changed(let url): "项目已改变或无法核实，请刷新后重试：\(url.path)"
        case .conflict(let url): "目标名称已存在：\(url.lastPathComponent)"
        case .descendant: "不能把文件夹放入自身或其子文件夹。"
        case .crossVolume: "当前版本只支持同卷移动。请先复制并确认结果，再自行处理原件。"
        case .unsupported: "当前版本只支持已下载的普通本地文件、文件夹和链接；此位置或对象不支持写操作。"
        case .cancelled: "已取消；原件保留。"
        case .residual(let url, let reason): "\(reason) 临时项目保留在：\(url.path)"
        }
    }
}
public final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func check() throws { if isCancelled { throw FileOperationError.cancelled } }
}
