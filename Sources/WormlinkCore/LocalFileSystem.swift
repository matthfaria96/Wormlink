import Foundation

/// Disco deste Mac, exposto com a mesma interface dos servidores.
public final class LocalFileSystem: FileSystem {
    public let title = "Este Mac"
    public let homePath: String

    public init(homePath: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homePath = homePath
    }

    public func url(for path: String) -> URL { URL(filePath: path) }

    public func list(_ path: String) async throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url(for: path), includingPropertiesForKeys: keys)
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isLink = v?.isSymbolicLink ?? false
            // Links para pastas abrem como pasta.
            let isDir = isLink ? ((try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                               : (v?.isDirectory ?? false)
            let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
            return FileItem(path: RemotePath.normalize(u.path), isDirectory: isDir, isSymlink: isLink,
                            size: isDir ? nil : v?.fileSize.map(Int64.init), modified: v?.contentModificationDate,
                            mode: (attrs?[.posixPermissions] as? NSNumber)?.uint16Value,
                            owner: attrs?[.ownerAccountName] as? String, group: attrs?[.groupOwnerAccountName] as? String)
        }
    }

    public func createDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: false)
    }

    /// Itens locais vão para o Lixo, como no Finder.
    public func delete(_ item: FileItem) async throws {
        try FileManager.default.trashItem(at: url(for: item.path), resultingItemURL: nil)
    }

    public func move(_ path: String, to newPath: String) async throws {
        try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try copy(url(for: path), to: local, progress: progress)
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try copy(local, to: url(for: path), progress: progress)
    }

    public func setPermissions(_ path: String, mode: UInt16) async throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
    }

    public var supportsPermissions: Bool { true }

    public var canResumeDownloads: Bool { true }
    public var canResumeUploads: Bool { true }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Self.stream(url(for: path), to: local, offset: offset, progress: progress)
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Self.stream(local, to: url(for: path), offset: offset, progress: progress)
    }

    public var supportsModificationDates: Bool { true }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Cópia em blocos a partir de `offset` (retomada), acrescentando ao destino.
    static func stream(_ from: URL, to: URL, offset: Int64, progress: @Sendable (Int64) -> Void) throws {
        if offset == 0 || !FileManager.default.fileExists(atPath: to.path) {
            FileManager.default.createFile(atPath: to.path, contents: nil)
        }
        let reader = try FileHandle(forReadingFrom: from)
        let writer = try FileHandle(forWritingTo: to)
        defer { try? reader.close(); try? writer.close() }
        try reader.seek(toOffset: UInt64(offset))
        try writer.truncate(atOffset: UInt64(offset))
        var total = offset
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try writer.write(contentsOf: chunk)
            total += Int64(chunk.count)
            progress(total)
        }
    }

    public func disconnect() async {}

    private func copy(_ from: URL, to: URL, progress: @Sendable (Int64) -> Void) throws {
        if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
        try FileManager.default.copyItem(at: from, to: to)   // clonagem APFS quando possível
        progress((try? from.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
    }
}
