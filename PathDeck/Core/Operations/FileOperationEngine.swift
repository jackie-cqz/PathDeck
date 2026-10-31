import Foundation
import Darwin

public struct OperationStep: Sendable {
    public let result: FileOperationResult?
    public let conflict: URL?
    public let artifacts: [URL]
}

/// All blocking IO, coordination and journal writes run on one dedicated queue.
public final class FileOperationEngine: @unchecked Sendable {
    private let queue: OperationQueue
    private let journalDirectory: URL?
    private let trash: @Sendable (URL) throws -> URL?
    private let beforeCommit: (@Sendable (URL) throws -> Void)?

    public init(journalDirectory: URL? = nil,
                trash: @escaping @Sendable (URL) throws -> URL? = FileOperationEngine.systemTrash,
                beforeCommit: (@Sendable (URL) throws -> Void)? = nil) {
        self.journalDirectory = journalDirectory; self.trash = trash; self.beforeCommit = beforeCommit
        queue = OperationQueue(); queue.name = "local.pathdeck.write-io"
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
    }

    public static func systemTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    public func capture(_ urls: [URL]) async -> [FileReference] {
        (try? await perform { urls.map { FileReference(url: $0, identity: try? FileIdentity.read($0)) } }) ?? []
    }
    public func persist(_ record: FileOperationRecord) async throws { try await perform { try self.save(record) } }
    public func recover() async throws -> [FileOperationRecord] {
        try await perform {
            guard let folder = self.journalDirectory, FileManager.default.fileExists(atPath: folder.path) else { return [] }
            var records: [FileOperationRecord] = []
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                guard var record = try? JSONDecoder().decode(FileOperationRecord.self, from: Data(contentsOf: url)), url.deletingPathExtension().lastPathComponent == record.id.uuidString else { continue }
                record.artifacts.removeAll { (try? FileIdentity.read($0)) == nil }
                if !record.state.isTerminal { record.state = .interruptedUnknown; try self.save(record) }
                records.append(record)
            }
            return Array(records.sorted { $0.createdAt < $1.createdAt }.suffix(100))
        }
    }

    public func execute(_ input: FileOperationRecord, source: FileReference?, name: String?, cancellation: OperationCancellation) async -> OperationStep {
        // The operation returns every artifact it created, including on cancellation.
        (try? await perform {
            var record = input
            do {
                try cancellation.check()
                try self.save(record) // Journal failure prevents any new mutation.
                let destination = try self.executeSync(&record, source: source, name: name, cancellation: cancellation)
                return OperationStep(result: FileOperationResult(source: source?.url, destination: destination, outcome: .succeeded), conflict: nil, artifacts: record.artifacts)
            } catch FileOperationError.conflict(let url) {
                return OperationStep(result: nil, conflict: url, artifacts: record.artifacts)
            } catch {
                let cancelled = cancellation.isCancelled || (error as? FileOperationError).map { if case .cancelled = $0 { true } else { false } } == true
                return OperationStep(result: FileOperationResult(source: source?.url, destination: nil, outcome: cancelled ? .cancelled : .failed, message: error.localizedDescription), conflict: nil, artifacts: record.artifacts)
            }
        }) ?? OperationStep(result: FileOperationResult(source: source?.url, destination: nil, outcome: .failed, message: "无法启动文件操作。"), conflict: nil, artifacts: input.artifacts)
    }

    private func executeSync(_ record: inout FileOperationRecord, source: FileReference?, name: String?, cancellation: OperationCancellation) throws -> URL? {
        let request = record.request
        if request.kind == .trash {
            guard let source else { throw FileOperationError.unsupported }
            try verifySupported(source); try cancellation.check()
            var result: URL?
            try coordinated(source.url, options: .forDeleting) { url in
                try source.verify()
                guard try FileIdentity.read(url) == source.identity else { throw FileOperationError.changed(source.url) }
                result = try self.trash(source.url)
            }
            return result
        }
        guard let target = request.destination else { throw FileOperationError.unsupported }
        try verifySupported(target, directory: true)
        let filename = name ?? source?.url.lastPathComponent ?? ""
        try Self.validateName(filename)
        let destination = target.url.appendingPathComponent(filename)
        if let source {
            try verifySupported(source)
            if request.kind == .rename, try FileIdentity.read(source.url.deletingLastPathComponent()) != target.identity { throw FileOperationError.unsupported }
            if request.kind == .move && source.identity?.device != target.identity?.device { throw FileOperationError.crossVolume }
            try rejectDescendant(source, target: target)
            if request.kind == .move && source.url.path == destination.path { return source.url }
            if request.kind == .rename && source.url.path == destination.path { return source.url }
        }
        if let existing = try? FileIdentity.read(destination) {
            if request.kind == .rename, let source, existing == source.identity {
                return try caseRename(&record, source: source, target: target, destination: destination)
            }
            throw FileOperationError.conflict(destination)
        }

        switch request.kind {
        case .newFolder, .newTextFile:
            try coordinated(target.url, options: .forMerging) { _ in
                try target.verify(); try cancellation.check()
                let fd = try self.openDirectory(target); defer { close(fd) }
                if request.kind == .newFolder {
                    guard mkdirat(fd, filename, 0o755) == 0 else { try self.throwPOSIX(destination) }
                } else {
                    let file = openat(fd, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                    guard file >= 0 else { try self.throwPOSIX(destination) }
                    defer { close(file) }
                }
            }
            return destination
        case .rename, .move:
            guard let source else { throw FileOperationError.unsupported }
            try coordinatedPair(source.url, destination: target.url, moving: true) { actualSource, _ in
                try source.verify(); try target.verify(); try cancellation.check()
                guard try FileIdentity.read(actualSource) == source.identity else { throw FileOperationError.changed(source.url) }
                try self.beforeCommit?(destination)
                try cancellation.check()
                try self.renameExclusive(source.url, to: destination, parent: target)
            }
            return destination
        case .copy:
            guard let source else { throw FileOperationError.unsupported }
            try validateCopyTree(source, cancellation: cancellation)
            let stage = target.url.appendingPathComponent(".PathDeck-copy-\(UUID().uuidString)", isDirectory: true)
            let payload = stage.appendingPathComponent("payload")
            try coordinatedPair(source.url, destination: target.url, moving: false) { actualSource, _ in
                try source.verify(); try target.verify(); try cancellation.check()
                guard try FileIdentity.read(actualSource) == source.identity else { throw FileOperationError.changed(source.url) }
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                record.artifacts.append(stage); try self.save(record)
                // Foundation preserves links and supported file metadata/resource forks.
                try FileManager.default.copyItem(at: actualSource, to: payload)
                try source.verify(); try target.verify(); try cancellation.check()
                try self.beforeCommit?(destination)
                try cancellation.check()
                try self.renameExclusive(payload, to: destination, parent: target)
                // Only remove the empty container. Never recursively delete a partial copy.
                if rmdir(stage.path) == 0 { record.artifacts.removeAll { $0 == stage } }
            }
            return destination
        case .trash: throw FileOperationError.unsupported
        }
    }

    public static func validateName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") { throw FileOperationError.invalidName }
    }
    public static func alternativeName(_ original: String, number: Int, isDirectory: Bool = false) -> String {
        if isDirectory { return "\(original) (\(number))" }
        let value = original as NSString
        let ext = value.pathExtension
        if ext.isEmpty || original.hasPrefix(".") && !original.dropFirst().contains(".") { return "\(original) (\(number))" }
        return "\(value.deletingPathExtension) (\(number)).\(ext)"
    }

    private func verifySupported(_ reference: FileReference, directory: Bool = false) throws {
        try reference.verify()
        var metadata = stat()
        guard lstat(reference.url.path, &metadata) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let kind = metadata.st_mode & S_IFMT
        guard [S_IFREG, S_IFDIR, S_IFLNK].contains(kind), !directory || kind == S_IFDIR else { throw FileOperationError.unsupported }
        if kind == S_IFLNK { return } // Copy/move/trash the link itself, never its target.
        let values = try reference.url.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey])
        let components = reference.url.pathComponents
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let provider = ["CloudStorage", "Mobile Documents"].contains { components.starts(with: library.appendingPathComponent($0).pathComponents) }
        if values.volumeIsLocal == false || values.isUbiquitousItem == true || provider { throw FileOperationError.unsupported }
        if reference.url.path == "/" { throw FileOperationError.unsupported }
    }
    private func validateCopyTree(_ source: FileReference, cancellation: OperationCancellation) throws {
        var metadata = stat(); guard lstat(source.url.path, &metadata) == 0 else { throw FileOperationError.changed(source.url) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return }
        var failure: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: source.url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, error in failure = error; return false }) else { throw FileOperationError.unsupported }
        for case let url as URL in enumerator {
            try cancellation.check()
            let reference = try FileReference.capture(url)
            guard reference.identity?.device == source.identity?.device else { throw FileOperationError.unsupported }
            try verifySupported(reference)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants() }
        }
        if let failure { throw failure }
    }
    private func rejectDescendant(_ source: FileReference, target: FileReference) throws {
        var metadata = stat(); guard lstat(source.url.path, &metadata) == 0 else { throw FileOperationError.changed(source.url) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return }
        let sourcePath = source.url.resolvingSymlinksInPath().pathComponents
        let targetPath = target.url.resolvingSymlinksInPath().pathComponents
        if targetPath.starts(with: sourcePath) { throw FileOperationError.descendant }
    }
    private func openDirectory(_ reference: FileReference) throws -> Int32 {
        let fd = open(reference.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var value = stat()
        guard fstat(fd, &value) == 0, UInt64(UInt32(bitPattern: value.st_dev)) == reference.identity?.device, UInt64(value.st_ino) == reference.identity?.inode else { close(fd); throw FileOperationError.changed(reference.url) }
        return fd
    }
    private func renameExclusive(_ source: URL, to destination: URL, parent: FileReference) throws {
        let fd = try openDirectory(parent); defer { close(fd) }
        guard renameatx_np(AT_FDCWD, source.path, fd, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EXDEV { throw FileOperationError.crossVolume }
            try throwPOSIX(destination)
        }
    }
    private func caseRename(_ record: inout FileOperationRecord, source: FileReference, target: FileReference, destination: URL) throws -> URL {
        let temporary = target.url.appendingPathComponent(".PathDeck-rename-\(UUID().uuidString)")
        record.artifacts.append(temporary); try save(record)
        try coordinatedPair(source.url, destination: target.url, moving: true) { _, _ in
            try source.verify(); try target.verify()
            try self.renameExclusive(source.url, to: temporary, parent: target)
            do { try self.renameExclusive(temporary, to: destination, parent: target) }
            catch {
                do { try self.renameExclusive(temporary, to: source.url, parent: target) }
                catch { throw FileOperationError.residual(temporary, "大小写重命名回退失败。") }
                record.artifacts.removeAll { $0 == temporary }
                throw error
            }
        }
        record.artifacts.removeAll { $0 == temporary }
        return destination
    }
    private func throwPOSIX(_ target: URL) throws -> Never {
        let code = errno
        if code == EEXIST { throw FileOperationError.conflict(target) }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: target.path])
    }
    private func coordinated(_ url: URL, options: NSFileCoordinator.WritingOptions, _ work: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(); var coordinationError: NSError?; var operationError: (any Error)?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { actual in do { try work(actual) } catch { operationError = error } }
        if let error = operationError ?? coordinationError { throw error }
    }
    private func coordinatedPair(_ source: URL, destination: URL, moving: Bool, _ work: (URL, URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(); var coordinationError: NSError?; var operationError: (any Error)?
        if moving {
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forMerging, error: &coordinationError) { a, b in do { try work(a, b) } catch { operationError = error } }
        } else {
            coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: .forMerging, error: &coordinationError) { a, b in do { try work(a, b) } catch { operationError = error } }
        }
        if let error = operationError ?? coordinationError { throw error }
    }
    private func save(_ record: FileOperationRecord) throws {
        guard let folder = journalDirectory else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent(record.id.uuidString).appendingPathExtension("json"), options: .atomic)
    }
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) } }
        }
    }
}
