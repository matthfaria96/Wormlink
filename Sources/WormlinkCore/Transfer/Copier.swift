import Foundation

/// O que fazer quando o destino já tem um item com o mesmo nome.
public enum ConflictAction: String, Codable, CaseIterable, Sendable {
    case overwrite, skip, rename, resume

    public var title: String {
        switch self {
        case .overwrite: "Substituir"
        case .skip: "Pular"
        case .rename: "Manter os dois"
        case .resume: "Retomar"
        }
    }
}

/// Decide um conflito (normalmente perguntando ao usuário). Recebe o item de origem e o existente.
public typealias ConflictResolver = @Sendable (_ source: FileItem, _ existing: FileItem) async -> ConflictAction

/// Regras para ignorar arquivos ("Skip Rules" do Transmit): padrões glob aplicados ao nome.
public struct SkipRules: Codable, Hashable, Sendable {
    public var patterns: [String]

    public init(patterns: [String]) { self.patterns = patterns }

    public static let `default` = SkipRules(patterns: [".DS_Store", "._*", ".Spotlight-V100", ".Trashes", ".fseventsd", "Thumbs.db", "desktop.ini"])
    public static let none = SkipRules(patterns: [])

    public func skips(_ name: String) -> Bool {
        patterns.contains { pattern in
            let p = pattern.trimmingCharacters(in: .whitespaces)
            return !p.isEmpty && fnmatch(p, name, 0) == 0
        }
    }
}

/// Copia itens entre dois sistemas de arquivos quaisquer (local ↔ servidor ou servidor ↔ servidor),
/// percorrendo pastas, respeitando as regras de exclusão e resolvendo conflitos.
public struct Copier: Sendable {
    public let source: any FileSystem
    public let destination: any FileSystem
    public var skip: SkipRules
    public var resolver: ConflictResolver?
    public var preserveDates: Bool
    /// Envia com nome temporário e renomeia no fim, para nunca deixar um arquivo pela metade no lugar
    /// do original (opção "upload with temporary filename" do Cyberduck).
    public var atomicUploads = false
    /// Confere cada arquivo depois de transferido (checksum do servidor ou, na falta, o tamanho).
    public var verifyChecksums = false

    public init(from source: any FileSystem, to destination: any FileSystem, skip: SkipRules = .none,
                resolver: ConflictResolver? = nil, preserveDates: Bool = true) {
        self.source = source
        self.destination = destination
        self.skip = skip
        self.resolver = resolver
        self.preserveDates = preserveDates
    }

    /// Soma dos tamanhos dos arquivos (pastas são percorridas; itens ignorados não contam).
    public func totalSize(of item: FileItem) async throws -> Int64 {
        guard !skip.skips(item.name) else { return 0 }
        guard item.isDirectory else { return item.size ?? 0 }
        guard !item.isSymlink else { return 0 }   // link para pasta: seguir pode entrar em ciclo (ln -s .. volta)
        var total: Int64 = 0
        for child in try await source.list(item.path) { total += try await totalSize(of: child) }
        return total
    }

    /// Copia `item` para dentro de `directory`. `progress` recebe bytes novos (incrementos).
    /// `existing` é a listagem do destino, quando já conhecida (evita listar de novo).
    public func copy(_ item: FileItem, into directory: String, existing: [FileItem]? = nil,
                     progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard !skip.skips(item.name) else { return }
        if item.isDirectory && item.isSymlink { return }   // não segue links para pastas (evita ciclos)
        let siblings: [FileItem]
        if let existing { siblings = existing } else { siblings = (try? await destination.list(directory)) ?? [] }
        // Nomes do Mac podem estar decompostos (NFD); servidores (Linux, S3, Azure) comparam bytes, então
        // "ação" em NFD viraria um segundo arquivo. Envia em NFC, como o Cyberduck.
        let name = source is LocalFileSystem && !(destination is LocalFileSystem)
            ? item.name.precomposedStringWithCanonicalMapping : item.name
        var target = RemotePath.join(directory, name)
        let current = siblings.first { $0.name == name }

        if item.isDirectory {
            if let current, !current.isDirectory {
                // Um arquivo no lugar da pasta: só segue se o usuário mandar substituir.
                let action = await resolver?(item, current) ?? .overwrite
                if action == .skip { return }
                if action == .rename { target = Self.uniqueName(name, in: directory, taken: siblings.map(\.name)) }
                else { try await destination.delete(current) }
            }
            let exists = current?.isDirectory == true && RemotePath.name(target) == name
            if !exists { try await destination.createDirectory(target) }
            let children = exists ? ((try? await destination.list(target)) ?? []) : []
            for child in try await source.list(item.path) {
                try Task.checkCancellation()
                try await copy(child, into: target, existing: children, progress: progress)
            }
            return
        }

        var offset: Int64 = 0
        if let current {
            switch await resolver?(item, current) ?? .overwrite {
            case .skip:
                progress(item.size ?? 0)
                return
            case .rename:
                target = Self.uniqueName(name, in: directory, taken: siblings.map(\.name))
            case .resume:
                if let have = current.size, let want = item.size, have < want, canResume { offset = have }
            case .overwrite:
                if current.isDirectory { try await destination.delete(current) }
            }
        }
        let atomic = atomicUploads && offset == 0 && !(destination is LocalFileSystem) && !destination.uploadsAreAtomic
        if atomic {
            let temporary = RemotePath.join(directory, ".\(RemotePath.name(target)).wormlink-part")
            try await transfer(item, to: temporary, offset: 0, progress: progress)
            do {
                try await destination.move(temporary, to: target)
            } catch {
                guard let old = siblings.first(where: { $0.path == target }), !old.isDirectory else {
                    try? await destination.delete(FileItem(path: temporary, isDirectory: false))
                    throw error
                }
                // Muitos servidores (SFTP v3) não renomeiam por cima. O antigo vira reserva e só sai com o novo no
                // lugar; se algo falhar, o antigo volta e o novo continua no .wormlink-part. Nunca os dois somem.
                let backup = RemotePath.join(directory, ".\(RemotePath.name(target)).wormlink-old")
                try await destination.move(target, to: backup)
                do {
                    try await destination.move(temporary, to: target)
                } catch {
                    try? await destination.move(backup, to: target)
                    throw error
                }
                try? await destination.delete(FileItem(path: backup, isDirectory: false))
            }
        } else {
            try await transfer(item, to: target, offset: offset, progress: progress)
        }
        if preserveDates, let date = item.modified, destination.supportsModificationDates {
            try? await destination.setModificationDate(target, date)
        }
        if verifyChecksums { try await verify(item, target) }
    }

    /// Compara origem e destino: checksum quando um dos lados é o Mac e o outro sabe calcular; senão, tamanho.
    func verify(_ item: FileItem, _ target: String) async throws {
        switch (source, destination) {
        case (let local as LocalFileSystem, _):
            if let remote = try? await destination.remoteChecksum(target) {
                guard try Checksum.local(local.url(for: item.path), remote.algorithm) == remote else {
                    throw WormlinkError.checksumMismatch(item.name)
                }
                return
            }
        case (_, let local as LocalFileSystem):
            if let remote = try? await source.remoteChecksum(item.path) {
                guard try Checksum.local(local.url(for: target), remote.algorithm) == remote else {
                    throw WormlinkError.checksumMismatch(item.name)
                }
                return
            }
        default: break
        }
        let copied = try await destination.list(RemotePath.parent(target)).first { $0.path == RemotePath.normalize(target) }
        if let want = item.size, let got = copied?.size, want != got { throw WormlinkError.checksumMismatch(item.name) }
    }

    /// A retomada depende de quem escreve: o Mac (download) ou o servidor (envio).
    private var canResume: Bool {
        switch (source, destination) {
        case (is LocalFileSystem, _): destination.canResumeUploads
        case (_, is LocalFileSystem): source.canResumeDownloads
        default: false
        }
    }

    private func transfer(_ item: FileItem, to target: String, offset: Int64,
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let counter = Counter(progress)
        switch (source, destination) {
        case (let local as LocalFileSystem, _):
            try await destination.upload(local.url(for: item.path), to: target, offset: offset, progress: counter.report)
        case (_, let local as LocalFileSystem):
            try await source.download(item.path, to: local.url(for: target), offset: offset, progress: counter.report)
        default:
            let temp = FileManager.default.temporaryDirectory.appending(path: "Wormlink-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            // Metade do progresso para baixar, metade para enviar.
            let down = Counter { progress($0 / 2) }, up = Counter { progress($0 - $0 / 2) }
            try await source.download(item.path, to: temp, progress: down.report)
            try await destination.upload(temp, to: target, progress: up.report)
        }
    }

    /// "foto.jpg" → "foto 2.jpg", "foto 3.jpg"…
    static func uniqueName(_ name: String, in directory: String, taken: [String]) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate) { return RemotePath.join(directory, candidate) }
            n += 1
        }
    }
}

/// Converte totais acumulados por arquivo em incrementos.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    private let sink: @Sendable (Int64) -> Void
    init(_ sink: @escaping @Sendable (Int64) -> Void) { self.sink = sink }

    var report: @Sendable (Int64) -> Void {
        { [self] total in
            let delta = lock.withLock { () -> Int64 in
                let d = max(0, total - last)
                last = max(last, total)
                return d
            }
            if delta > 0 { sink(delta) }
        }
    }
}
