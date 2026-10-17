import FileProvider
import UniformTypeIdentifiers
import WormlinkCore

/// "Wormlink Disk": monta um servidor no Finder (como o Transmit Disk e o Mountain Duck).
/// Cada domínio é um favorito; os identificadores são opacos e sobrevivem a renomear/mover (ItemIdentifiers).
@objc(WormlinkDiskExtension)
final class WormlinkDiskExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    let domain: NSFileProviderDomain
    private let connection: Connection

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        WormlinkLogging.configure()
        connection = Connection(account: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {
        Task { await connection.close() }
    }

    // MARK: Itens

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run(completionHandler) { [connection] in
            let (fs, paths) = try await connection.open()
            if identifier == .rootContainer { return DiskItem.root(paths) }
            return try await DiskItem.lookup(paths.path(for: identifier), fs: fs, paths: paths)
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet { return WorkingSetEnumerator() }
        return FolderEnumerator(container: containerItemIdentifier, connection: connection)
    }

    // MARK: Conteúdo

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let domain = domain
        Task { [connection] in
            do {
                let (fs, paths) = try await connection.open()
                let path = try paths.path(for: itemIdentifier)
                let item = try await DiskItem.lookup(path, fs: fs, paths: paths)
                let folder = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
                let local = folder.appending(path: UUID().uuidString)
                let size = max(item.file.size ?? 1, 1)
                try await fs.download(path, to: local) { done in progress.completedUnitCount = min(100, done * 100 / size) }
                completionHandler(local, item, nil)
            } catch {
                await connection.failed(error)
                completionHandler(nil, nil, Self.map(error))
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        Task { [connection] in
            do {
                let (fs, paths) = try await connection.open()
                let parent = try paths.path(for: itemTemplate.parentItemIdentifier)
                let path = RemotePath.join(parent, itemTemplate.filename)
                // Pastas e pacotes (.app, .bundle…) são diretórios; o pacote vem com o conteúdo junto.
                let isDirectory = itemTemplate.contentType?.conforms(to: .directory) == true
                    || (url.flatMap { try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory } ?? false)
                if isDirectory {
                    try await fs.createDirectory(path)
                    if let url {
                        let copier = Copier(from: LocalFileSystem(), to: fs)
                        for child in try await LocalFileSystem().list(url.path) {
                            try await copier.copy(child, into: path) { _ in }
                        }
                    }
                } else if let url {
                    try await fs.upload(url, to: path) { _ in }
                } else {
                    try await fs.createFile(path)
                }
                // Caminho reaproveitado (algo apagado por fora com o mesmo nome): item novo, identificador novo.
                paths.store.removed(path)
                completionHandler(try await DiskItem.lookup(path, fs: fs, paths: paths), [], false, nil)
            } catch {
                await connection.failed(error)
                completionHandler(nil, [], false, Self.map(error))
            }
        }
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        Task { [connection] in
            do {
                let (fs, paths) = try await connection.open()
                var path = try paths.path(for: item.itemIdentifier)
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let target = RemotePath.join(try paths.path(for: item.parentItemIdentifier), item.filename)
                    if target != path {
                        try await fs.move(path, to: target)
                        paths.store.moved(from: path, to: target)
                        path = target
                    }
                }
                if changedFields.contains(.contents), let newContents {
                    try await fs.upload(newContents, to: path) { _ in }
                }
                // Campos que o servidor não guarda (etiquetas, datas de criação…) ficam só no Mac.
                let ignored = changedFields.subtracting([.filename, .parentItemIdentifier, .contents])
                completionHandler(try await DiskItem.lookup(path, fs: fs, paths: paths), ignored, false, nil)
            } catch {
                await connection.failed(error)
                completionHandler(nil, [], false, Self.map(error))
            }
        }
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        Task { [connection] in
            do {
                let (fs, paths) = try await connection.open()
                let item = try await DiskItem.lookup(paths.path(for: identifier), fs: fs, paths: paths)
                try await fs.delete(item.file)
                paths.store.removed(item.file.path)
                completionHandler(nil)
            } catch {
                await connection.failed(error)
                completionHandler(Self.map(error))
            }
        }
        return Progress()
    }

    // MARK: Apoio

    private func run(_ completion: @escaping (NSFileProviderItem?, Error?) -> Void,
                     _ body: @escaping @Sendable () async throws -> NSFileProviderItem) -> Progress {
        Task { [connection] in
            do {
                completion(try await body(), nil)
            } catch {
                await connection.failed(error)
                completion(nil, Self.map(error))
            }
        }
        return Progress()
    }

    static func map(_ error: Error) -> Error {
        switch error {
        case WormlinkError.notFound: NSFileProviderError(.noSuchItem)
        case WormlinkError.authenticationFailed, WormlinkError.hostKeyRejected: NSFileProviderError(.notAuthenticated)
        case WormlinkError.invalidBookmark: NSFileProviderError(.providerNotFound)
        default: NSFileProviderError(.serverUnreachable, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        }
    }
}

/// Conexão compartilhada pela extensão, aberta sob demanda e refeita se cair.
actor Connection {
    private let account: String
    private var fs: (any FileSystem)?
    private var root = "/"
    private let store: ItemIdentifiers

    init(account: String) {
        self.account = account
        store = ItemIdentifiers(file: Self.sandbox(account).appending(path: "identifiers.json"))
    }

    private static func sandbox(_ account: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Wormlink/\(account)")
    }

    func open() async throws -> (any FileSystem, Paths) {
        if let fs { return (fs, Paths(store: store, root: root)) }
        guard let config = DiskConfig.load(account) else { throw WormlinkError.invalidBookmark }
        let sandbox = Self.sandbox(account)
        let bookmark = try config.install(in: sandbox)
        // Sem interface na extensão: só vale o que o app já aceitou (chaves e certificados instalados acima).
        let trust = ConnectionTrust(hostKey: { _ in false }, certificate: { _ in false },
                                    passphrase: { _ in nil })
        let opened = try await Connector.connect(bookmark, password: config.secret, trust: trust)
        fs = opened
        root = RemotePath.normalize(bookmark.path.isEmpty ? opened.homePath : bookmark.path)
        return (opened, Paths(store: store, root: root))
    }

    /// Respostas do servidor (não existe, sem permissão…) mantêm a conexão; o resto (caiu, tempo esgotado,
    /// erro de rede) faz a próxima operação reconectar.
    func failed(_ error: Error) {
        switch error {
        case WormlinkError.notFound, WormlinkError.server, WormlinkError.unsupportedOperation, WormlinkError.checksumMismatch: return
        default: fs = nil
        }
    }

    func close() async {
        await fs?.disconnect()
        fs = nil
    }
}

/// Converte identificadores ⇄ caminhos remotos; a raiz do favorito é sempre .rootContainer.
struct Paths: Sendable {
    let store: ItemIdentifiers
    let root: String

    func path(for identifier: NSFileProviderItemIdentifier) throws -> String {
        if identifier == .rootContainer { return root }
        guard let path = store.path(for: identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
        return path
    }

    func identifier(for path: String) -> NSFileProviderItemIdentifier {
        let path = RemotePath.normalize(path)
        return path == root ? .rootContainer : NSFileProviderItemIdentifier(store.identifier(for: path))
    }
}

final class DiskItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let file: FileItem
    let paths: Paths
    private var root: String { paths.root }

    init(_ file: FileItem, paths: Paths) {
        self.file = file
        self.paths = paths
    }

    static func root(_ paths: Paths) -> DiskItem { DiskItem(FileItem(path: paths.root, isDirectory: true), paths: paths) }

    /// Procura o item listando a pasta-mãe.
    static func lookup(_ path: String, fs: any FileSystem, paths: Paths) async throws -> DiskItem {
        if RemotePath.normalize(path) == paths.root { return .root(paths) }
        guard let file = try await fs.list(RemotePath.parent(path)).first(where: { $0.path == RemotePath.normalize(path) }) else {
            throw WormlinkError.notFound(path)
        }
        return DiskItem(file, paths: paths)
    }

    var itemIdentifier: NSFileProviderItemIdentifier { paths.identifier(for: file.path) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        file.path == root ? .rootContainer : paths.identifier(for: RemotePath.parent(file.path))
    }
    var filename: String { file.path == root ? "Wormlink" : file.name }
    var contentType: UTType {
        file.isDirectory ? .folder : (UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)
    }
    var documentSize: NSNumber? { file.size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { file.modified }
    var capabilities: NSFileProviderItemCapabilities {
        file.isDirectory
            ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting, .allowsDeleting]
            : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }
    var itemVersion: NSFileProviderItemVersion {
        let stamp = Data("\(file.size ?? -1)-\(file.modified?.timeIntervalSince1970 ?? 0)".utf8)
        return NSFileProviderItemVersion(contentVersion: stamp, metadataVersion: stamp)
    }
}

/// Lista uma pasta. Mudanças não são rastreadas: o sistema relista quando a âncora expira.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    let container: NSFileProviderItemIdentifier
    let connection: Connection

    init(container: NSFileProviderItemIdentifier, connection: Connection) {
        self.container = container
        self.connection = connection
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task { [container, connection] in
            do {
                let (fs, paths) = try await connection.open()
                let items = try await fs.list(paths.path(for: container)).map { DiskItem($0, paths: paths) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                await connection.failed(error)
                observer.finishEnumeratingWithError(WormlinkDiskExtension.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("\(Date().timeIntervalSince1970)".utf8)))
    }
}

final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("0".utf8)))
    }
}
