import Foundation

/// Opções de sincronização (origem → destino, num sentido só, como no Transmit).
public struct SyncOptions: Codable, Hashable, Sendable {
    public enum Compare: String, Codable, CaseIterable, Sendable {
        /// Tamanho diferente ou origem mais nova.
        case sizeOrDate
        case sizeOnly
        case dateOnly

        public var title: String {
            switch self {
            case .sizeOrDate: String(localized: "Tamanho e data")
            case .sizeOnly: String(localized: "Só tamanho")
            case .dateOnly: String(localized: "Só data")
            }
        }
    }

    public var compare: Compare = .sizeOrDate
    /// Apagar do destino o que não existe na origem ("Delete orphaned files").
    public var deleteOrphans = false
    public var skip: SkipRules = .default
    /// Folga na comparação de datas (FAT, FTP sem segundos, relógios diferentes).
    public var tolerance: TimeInterval = 2
    /// Diferença fixa de fuso entre os dois lados, em segundos ("Time offset" do Transmit).
    public var timeOffset: TimeInterval = 0

    public init() {}
}

/// Uma mudança proposta pela comparação.
public struct SyncChange: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case add, update, delete }

    public var id: String { relativePath }
    public let relativePath: String
    public let kind: Kind
    public let source: FileItem?
    public let destination: FileItem?

    public var isDirectory: Bool { (source ?? destination)?.isDirectory ?? false }
    public var size: Int64 { kind == .delete ? 0 : (source?.size ?? 0) }
}

/// Compara duas pastas e aplica as mudanças.
public struct Synchronizer: Sendable {
    public let source: any FileSystem
    public let destination: any FileSystem
    public var options: SyncOptions

    public init(from source: any FileSystem, to destination: any FileSystem, options: SyncOptions = SyncOptions()) {
        self.source = source
        self.destination = destination
        self.options = options
    }

    /// Percorre as duas árvores. `visiting` recebe cada pasta comparada (para mostrar progresso).
    public func compare(_ sourceRoot: String, _ destinationRoot: String,
                        visiting: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [SyncChange] {
        var changes: [SyncChange] = []
        try await walk(RemotePath.normalize(sourceRoot), RemotePath.normalize(destinationRoot), relative: "", into: &changes, visiting: visiting)
        return changes
    }

    private func walk(_ src: String, _ dst: String, relative: String, into changes: inout [SyncChange],
                      visiting: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        visiting(relative.isEmpty ? "/" : relative)
        let sourceItems = try await source.list(src).filter { !options.skip.skips($0.name) }
        let destinationItems = ((try? await destination.list(dst)) ?? []).filter { !options.skip.skips($0.name) }
        let byName = Dictionary(destinationItems.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let sourceNames = Set(sourceItems.map(\.name))

        for item in sourceItems.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let rel = relative.isEmpty ? item.name : relative + "/" + item.name
            guard let other = byName[item.name] else {
                changes.append(SyncChange(relativePath: rel, kind: .add, source: item, destination: nil))
                continue
            }
            switch (item.isDirectory, other.isDirectory) {
            case (true, true):
                if item.isSymlink { continue }   // links para pastas podem formar ciclos
                try await walk(item.path, other.path, relative: rel, into: &changes, visiting: visiting)
            case (false, false):
                if differs(item, other) { changes.append(SyncChange(relativePath: rel, kind: .update, source: item, destination: other)) }
            default:
                // Pasta virou arquivo (ou o contrário): substitui.
                changes.append(SyncChange(relativePath: rel, kind: .update, source: item, destination: other))
            }
        }
        if options.deleteOrphans {
            // Destinos que ignoram maiúsculas (APFS, Dropbox, SMB…): "README.md" é o mesmo arquivo que "Readme.md",
            // que já vai ser enviado por cima. Apagar o "órfão" apagaria o arquivo recém-enviado.
            let foldedSource = Set(sourceNames.map { $0.lowercased() })
            for orphan in destinationItems where !sourceNames.contains(orphan.name) && !foldedSource.contains(orphan.name.lowercased()) {
                let rel = relative.isEmpty ? orphan.name : relative + "/" + orphan.name
                changes.append(SyncChange(relativePath: rel, kind: .delete, source: nil, destination: orphan))
            }
        }
    }

    func differs(_ a: FileItem, _ b: FileItem) -> Bool {
        let sizeDiffers = a.size != nil && b.size != nil && a.size != b.size
        var newer = false
        if let da = a.modified, let db = b.modified {
            newer = da.addingTimeInterval(options.timeOffset).timeIntervalSince(db) > options.tolerance
        }
        switch options.compare {
        case .sizeOrDate: return sizeDiffers || newer
        case .sizeOnly: return sizeDiffers
        case .dateOnly: return newer
        }
    }

    /// Aplica as mudanças escolhidas. `progress` recebe bytes; `done` é chamado a cada mudança concluída.
    public func apply(_ changes: [SyncChange], sourceRoot: String, destinationRoot: String,
                      progress: @escaping @Sendable (Int64) -> Void,
                      done: @escaping @Sendable (SyncChange, Error?) -> Void = { _, _ in }) async throws {
        var copier = Copier(from: source, to: destination, skip: options.skip)
        copier.resolver = { _, _ in .overwrite }
        for change in changes {
            try Task.checkCancellation()
            do {
                let parent = RemotePath.parent(RemotePath.join(destinationRoot, change.relativePath))
                switch change.kind {
                case .add:
                    if let item = change.source { try await copier.copy(item, into: parent, existing: [], progress: progress) }
                case .update:
                    if let old = change.destination, old.isDirectory != change.source?.isDirectory {
                        try await destination.delete(old)
                    }
                    if let item = change.source {
                        let existing = change.destination.map { [$0] }?.filter { $0.isDirectory == item.isDirectory } ?? []
                        try await copier.copy(item, into: parent, existing: existing, progress: progress)
                    }
                case .delete:
                    if let item = change.destination { try await destination.delete(item) }
                }
                done(change, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                done(change, error)
            }
        }
    }
}
