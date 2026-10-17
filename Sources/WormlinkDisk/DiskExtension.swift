import FileProvider
import UniformTypeIdentifiers
import WormlinkCore

/// "Wormlink Disk": monta um servidor no Finder (como o Transmit Disk e o Mountain Duck).
/// Cada domínio é um favorito; o identificador de cada item é o caminho remoto.
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
            let (fs, root) = try await connection.open()
            if identifier == .rootContainer { return DiskItem.root(path: root) }
            return try await DiskItem.lookup(Paths.path(for: identifier, root: root), fs: fs, root: root)
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
                let (fs, root) = try await connection.open()
                let path = Paths.path(for: itemIdentifier, root: root)
                let item = try await DiskItem.lookup(path, fs: fs, root: root)
                let folder = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
                let local = folder.appending(path: UUID().uuidString)
                let size = max(item.file.size ?? 1, 1)
                try await fs.download(path, to: local) { done in progress.completedUnitCount = min(100, done * 100 / size) }
                completionHandler(local, item, nil)
            } catch {
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
                let (fs, root) = try await connection.open()
                let parent = Paths.path(for: itemTemplate.parentItemIdentifier, root: root)
                let path = RemotePath.join(parent, itemTemplate.filename)
                if itemTemplate.contentType == .folder {
                    try await fs.createDirectory(path)
                } else if let url {
                    try await fs.upload(url, to: path) { _ in }
                } else {
                    try await fs.createFile(path)
                }
                completionHandler(try await DiskItem.lookup(path, fs: fs, root: root), [], false, nil)
            } catch {
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
                let (fs, root) = try await connection.open()
                var path = Paths.path(for: item.itemIdentifier, root: root)
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let target = RemotePath.join(Paths.path(for: item.parentItemIdentifier, root: root), item.filename)
                    if target != path {
                        try await fs.move(path, to: target)
                        path = target
                    }
                }
                if changedFields.contains(.contents), let newContents {
                    try await fs.upload(newContents, to: path) { _ in }
                }
                // Campos que o servidor não guarda (etiquetas, datas de criação…) ficam só no Mac.
                let ignored = changedFields.subtracting([.filename, .parentItemIdentifier, .contents])
                completionHandler(try await DiskItem.lookup(path, fs: fs, root: root), ignored, false, nil)
            } catch {
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
                let (fs, root) = try await connection.open()
                let item = try await DiskItem.lookup(Paths.path(for: identifier, root: root), fs: fs, root: root)
                try await fs.delete(item.file)
                completionHandler(nil)
            } catch {
                completionHandler(Self.map(error))
            }
        }
        return Progress()
    }

    // MARK: Apoio

    private func run(_ completion: @escaping (NSFileProviderItem?, Error?) -> Void,
                     _ body: @escaping @Sendable () async throws -> NSFileProviderItem) -> Progress {
        Task {
            do { completion(try await body(), nil) } catch { completion(nil, Self.map(error)) }
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

    init(account: String) { self.account = account }

    func open() async throws -> (any FileSystem, String) {
        if let fs { return (fs, root) }
        guard let config = DiskConfig.load(account) else { throw WormlinkError.invalidBookmark }
        let sandbox = URL.applicationSupportDirectory.appending(path: "Wormlink/\(account)")
        let bookmark = try config.install(in: sandbox)
        // Sem interface na extensão: só vale o que o app já aceitou (chaves e certificados instalados acima).
        let trust = ConnectionTrust(hostKey: { _ in false }, certificate: { _ in false },
                                    passphrase: { _ in nil })
        let opened = try await Connector.connect(bookmark, password: config.secret, trust: trust)
        fs = opened
        root = RemotePath.normalize(bookmark.path.isEmpty ? opened.homePath : bookmark.path)
        return (opened, root)
    }

    func reset() { fs = nil }

    func close() async {
        await fs?.disconnect()
        fs = nil
    }
}

enum Paths {
    static func path(for identifier: NSFileProviderItemIdentifier, root: String) -> String {
        identifier == .rootContainer ? root : RemotePath.normalize(identifier.rawValue)
    }

    static func identifier(for path: String, root: String) -> NSFileProviderItemIdentifier {
        RemotePath.normalize(path) == root ? .rootContainer : NSFileProviderItemIdentifier(RemotePath.normalize(path))
    }
}

final class DiskItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let file: FileItem
    let root: String

    init(_ file: FileItem, root: String) {
        self.file = file
        self.root = root
    }

    static func root(path: String) -> DiskItem { DiskItem(FileItem(path: path, isDirectory: true), root: path) }

    /// Procura o item listando a pasta-mãe (o caminho é o identificador).
    static func lookup(_ path: String, fs: any FileSystem, root: String) async throws -> DiskItem {
        if RemotePath.normalize(path) == root { return .root(path: root) }
        guard let file = try await fs.list(RemotePath.parent(path)).first(where: { $0.path == RemotePath.normalize(path) }) else {
            throw WormlinkError.notFound(path)
        }
        return DiskItem(file, root: root)
    }

    var itemIdentifier: NSFileProviderItemIdentifier { Paths.identifier(for: file.path, root: root) }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        file.path == root ? .rootContainer : Paths.identifier(for: RemotePath.parent(file.path), root: root)
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
                let (fs, root) = try await connection.open()
                let items = try await fs.list(Paths.path(for: container, root: root)).map { DiskItem($0, root: root) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                await connection.reset()
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
