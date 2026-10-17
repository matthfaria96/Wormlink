import AppIntents
import AppKit
import WormlinkCore

/// Servidor salvo, para os parâmetros das ações do Atalhos.
struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Servidor"
    static let defaultQuery = ServerQuery()

    let id: UUID
    let name: String
    let address: String

    init(_ bookmark: Bookmark) {
        id = bookmark.id
        name = bookmark.displayName
        address = "\(bookmark.connectionProtocol.displayName) — \(bookmark.hostname)"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(address)")
    }

    var bookmark: Bookmark? { IntentSupport.bookmarks().first { $0.id == id } }
}

struct ServerQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        IntentSupport.bookmarks().filter { identifiers.contains($0.id) }.map(ServerEntity.init)
    }

    func entities(matching string: String) async throws -> [ServerEntity] {
        IntentSupport.bookmarks().filter { $0.displayName.localizedCaseInsensitiveContains(string) }.map(ServerEntity.init)
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        IntentSupport.bookmarks().map(ServerEntity.init)
    }
}

nonisolated enum IntentSupport {
    /// Mesma fonte de favoritos do app (local ou iCloud Drive).
    static func bookmarks() -> [Bookmark] {
        let iCloud = UserDefaults.standard.bool(forKey: "iCloudSync") ? AppModel.iCloudFolder : nil
        return BookmarkStore(fileURL: iCloud?.appending(path: "Bookmarks.json") ?? BookmarkStore.defaultURL).load()
    }

    static func connect(_ server: ServerEntity) async throws -> (Bookmark, any FileSystem) {
        guard let bookmark = server.bookmark else { throw WormlinkError.invalidBookmark }
        let fs = try await Connector.connect(bookmark, password: Keychain.password(for: bookmark), trust: TrustPrompter.trust)
        return (bookmark, fs)
    }

    static func localItem(_ url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return FileItem(path: url.path, isDirectory: values?.isDirectory ?? false,
                        size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate)
    }
}

/// "Enviar Arquivos" (Upload do Transmit).
struct UploadFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Enviar Arquivos para Servidor"
    static let description = IntentDescription("Envia arquivos e pastas do Mac para um servidor do Wormlink.")

    @Parameter(title: "Arquivos", supportedContentTypes: [.item]) var files: [IntentFile]
    @Parameter(title: "Servidor") var server: ServerEntity
    @Parameter(title: "Pasta remota", description: "Vazio usa a pasta padrão do servidor.") var remoteFolder: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Enviar \(\.$files) para \(\.$server)") { \.$remoteFolder }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let (_, fs) = try await IntentSupport.connect(server)
        defer { Task { await fs.disconnect() } }
        let folder = remoteFolder.flatMap { $0.isEmpty ? nil : $0 } ?? fs.homePath
        let copier = Copier(from: LocalFileSystem(), to: fs, skip: TransferSettings.skipRules, resolver: { _, _ in .overwrite })
        var sent: [String] = []
        for file in files {
            guard let url = file.fileURL else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try await copier.copy(IntentSupport.localItem(url), into: folder) { _ in }
            sent.append(RemotePath.join(folder, url.lastPathComponent))
        }
        return .result(value: sent)
    }
}

/// "Baixar Arquivos" (Download do Transmit).
struct DownloadFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Baixar Arquivos do Servidor"
    static let description = IntentDescription("Baixa arquivos ou pastas de um servidor para uma pasta do Mac.")

    @Parameter(title: "Servidor") var server: ServerEntity
    @Parameter(title: "Caminhos remotos", description: "Ex.: /www/index.html") var paths: [String]
    @Parameter(title: "Pasta de destino", description: "Vazio usa Downloads.") var destination: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Baixar \(\.$paths) de \(\.$server)") { \.$destination }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let (_, fs) = try await IntentSupport.connect(server)
        defer { Task { await fs.disconnect() } }
        let target = destination.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        let copier = Copier(from: fs, to: LocalFileSystem(), skip: TransferSettings.skipRules, resolver: { _, _ in .overwrite })
        var results: [IntentFile] = []
        for path in paths {
            let parent = RemotePath.parent(path)
            guard let item = try await fs.list(parent).first(where: { $0.path == RemotePath.normalize(path) }) else {
                throw WormlinkError.notFound(path)
            }
            try await copier.copy(item, into: target) { _ in }
            let local = URL(filePath: target).appending(path: item.name)
            results.append(IntentFile(fileURL: local, filename: item.name))
        }
        return .result(value: results)
    }
}

/// "Sincronizar" (Synchronize do Transmit).
struct SyncFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Sincronizar Pasta com Servidor"
    static let description = IntentDescription("Compara uma pasta do Mac com uma pasta remota e copia o que mudou.")

    enum Direction: String, AppEnum {
        case upload, download
        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Direção"
        static let caseDisplayRepresentations: [Direction: DisplayRepresentation] = [
            .upload: "Do Mac para o servidor", .download: "Do servidor para o Mac",
        ]
    }

    @Parameter(title: "Servidor") var server: ServerEntity
    @Parameter(title: "Pasta do Mac") var localFolder: String
    @Parameter(title: "Pasta remota") var remoteFolder: String
    @Parameter(title: "Direção", default: .upload) var direction: Direction
    @Parameter(title: "Apagar órfãos", default: false) var deleteOrphans: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Sincronizar \(\.$localFolder) com \(\.$remoteFolder) em \(\.$server)") {
            \.$direction
            \.$deleteOrphans
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let (_, fs) = try await IntentSupport.connect(server)
        defer { Task { await fs.disconnect() } }
        let local = LocalFileSystem()
        var options = SyncOptions()
        options.deleteOrphans = deleteOrphans
        options.skip = TransferSettings.skipRules
        let localPath = (localFolder as NSString).expandingTildeInPath
        let sync = direction == .upload ? Synchronizer(from: local, to: fs, options: options)
                                        : Synchronizer(from: fs, to: local, options: options)
        let (source, target) = direction == .upload ? (localPath, remoteFolder) : (remoteFolder, localPath)
        let changes = try await sync.compare(source, target)
        try await sync.apply(changes, sourceRoot: source, destinationRoot: target, progress: { _ in })
        return .result(value: changes.count, dialog: "\(changes.count) mudança(s) sincronizada(s).")
    }
}

/// Abre o Wormlink conectado a um servidor.
struct OpenServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir Servidor no Wormlink"
    static let openAppWhenRun = true

    @Parameter(title: "Servidor") var server: ServerEntity

    func perform() async throws -> some IntentResult {
        NSWorkspace.shared.open(URL(string: "wormlink://bookmark/\(server.id.uuidString)")!)
        return .result()
    }
}

struct WormlinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenServerIntent(), phrases: ["Abrir servidor no \(.applicationName)"],
                    shortTitle: "Abrir Servidor", systemImageName: "server.rack")
        AppShortcut(intent: UploadFilesIntent(), phrases: ["Enviar arquivos com o \(.applicationName)"],
                    shortTitle: "Enviar Arquivos", systemImageName: "arrow.up.circle")
        AppShortcut(intent: SyncFolderIntent(), phrases: ["Sincronizar pasta com o \(.applicationName)"],
                    shortTitle: "Sincronizar", systemImageName: "arrow.triangle.2.circlepath")
    }
}
