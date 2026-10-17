import Foundation

/// Cofre do Cryptomator aberto sobre qualquer conexão (SFTP, S3, Dropbox, disco local…).
/// Os caminhos são os mesmos da conexão: tudo abaixo de `root` aparece decifrado; o resto passa direto.
public final class CryptomatorFileSystem: FileSystem, @unchecked Sendable {
    public let inner: any FileSystem
    /// Pasta do cofre na conexão (onde ficam masterkey.cryptomator e d/).
    public let root: String
    public let vault: CryptomatorVault
    private let lock = NSLock()
    /// Caminho decifrado de pasta → ID da pasta no cofre.
    private var directoryIDs: [String: String]

    public var title: String { inner.title }
    public var homePath: String { root }
    public var supportsModificationDates: Bool { inner.supportsModificationDates }
    public var uploadsAreAtomic: Bool { inner.uploadsAreAtomic }

    init(inner: any FileSystem, root: String, vault: CryptomatorVault) {
        self.inner = inner
        self.root = RemotePath.normalize(root)
        self.vault = vault
        directoryIDs = [self.root: ""]
    }

    /// A listagem tem os arquivos de um cofre?
    public static func isVault(_ items: [FileItem]) -> Bool {
        items.contains { !$0.isDirectory && ($0.name == CryptomatorVault.masterkeyFile || $0.name == CryptomatorVault.configFile) }
    }

    public static func unlock(_ inner: any FileSystem, at root: String, password: String) async throws -> CryptomatorFileSystem {
        let names = Set(try await inner.list(root).map(\.name))
        let config = names.contains(CryptomatorVault.configFile) ? try await read(inner, RemotePath.join(root, CryptomatorVault.configFile)) : nil
        let masterkey = try await read(inner, RemotePath.join(root, try CryptomatorVault.masterkeyName(config: config)))
        let vault = try await Task.detached { try CryptomatorVault.unlock(masterkey: masterkey, config: config, password: password) }.value
        return CryptomatorFileSystem(inner: inner, root: root, vault: vault)
    }

    /// Cria um cofre novo (formato 8) na pasta `root`, que não pode existir ainda.
    public static func create(_ inner: any FileSystem, at root: String, password: String,
                              scryptCost: Int = 32768) async throws -> CryptomatorFileSystem {
        let created = await Task.detached { CryptomatorVault.create(password: password, scryptCost: scryptCost) }.value
        try await inner.createDirectory(root)
        try await write(inner, created.masterkey, to: RemotePath.join(root, CryptomatorVault.masterkeyFile))
        try await write(inner, created.config, to: RemotePath.join(root, CryptomatorVault.configFile))
        let fs = CryptomatorFileSystem(inner: inner, root: root, vault: created.vault)
        try await inner.createDirectory(RemotePath.join(root, "d"))
        try await fs.makeCipherDirectory(for: "")
        return fs
    }

    public func contains(_ path: String) -> Bool {
        let p = RemotePath.normalize(path)
        return p == root || p.hasPrefix(root == "/" ? "/" : root + "/")
    }

    // MARK: Mapeamento

    private func cipherDirectory(_ id: String) -> String { RemotePath.join(root, vault.directoryPath(for: id)) }

    /// Entrada cifrada de `name` dentro da pasta `parentID`; `long` é o nome completo quando foi encurtado (.c9s).
    private func entry(_ name: String, in parentID: String) -> (path: String, long: String?) {
        let encrypted = vault.encryptName(name, dirID: parentID)
        if let short = vault.shortened(encrypted) { return (RemotePath.join(cipherDirectory(parentID), short), encrypted) }
        return (RemotePath.join(cipherDirectory(parentID), encrypted), nil)
    }

    private func entry(for path: String) async throws -> (path: String, long: String?) {
        entry(RemotePath.name(path), in: try await directoryID(RemotePath.parent(path)))
    }

    /// Onde fica o conteúdo cifrado do arquivo.
    private func contentPath(_ e: (path: String, long: String?)) -> String {
        e.long == nil ? e.path : RemotePath.join(e.path, "contents.c9r")
    }

    func directoryID(_ path: String) async throws -> String {
        let path = RemotePath.normalize(path)
        if let id = lock.withLock({ directoryIDs[path] }) { return id }
        guard contains(path) else { throw WormlinkError.notFound(path) }
        let e = try await entry(for: path)
        let data: Data
        do { data = try await Self.read(inner, RemotePath.join(e.path, "dir.c9r")) } catch { throw WormlinkError.notFound(path) }
        let id = String(decoding: data, as: UTF8.self)
        lock.withLock { directoryIDs[path] = id }
        return id
    }

    private func forget(_ path: String) {
        lock.withLock { directoryIDs = directoryIDs.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
    }

    private func makeCipherDirectory(for id: String) async throws {
        let folder = cipherDirectory(id)
        try? await inner.createDirectory(RemotePath.parent(folder))   // d/XX pode já existir
        try await inner.createDirectory(folder)
        // Cópia do ID dentro da própria pasta (permite recuperar nomes se um dir.c9r se perder).
        try await Self.write(inner, try vault.encrypt(Data(id.utf8)), to: RemotePath.join(folder, "dirid.c9r"))
    }

    // MARK: Operações

    public func list(_ path: String) async throws -> [FileItem] {
        guard contains(path) else { return try await inner.list(path) }
        let id = try await directoryID(path)
        var result: [FileItem] = []
        for item in try await inner.list(cipherDirectory(id)) {
            let name = item.name
            if name.hasSuffix(".c9r") {
                guard let clear = vault.decryptName(name, dirID: id) else { continue }
                var plain = item
                plain.path = RemotePath.join(path, clear)
                plain.size = item.isDirectory ? nil : item.size.flatMap(vault.cleartextSize)
                plain.mode = nil
                result.append(plain)
            } else if name.hasSuffix(".c9s"), item.isDirectory {
                guard let kids = try? await inner.list(item.path),
                      let long = try? await Self.read(inner, RemotePath.join(item.path, "name.c9s")),
                      let clear = vault.decryptName(String(decoding: long, as: UTF8.self), dirID: id) else { continue }
                if let contents = kids.first(where: { $0.name == "contents.c9r" }) {
                    var plain = contents
                    plain.path = RemotePath.join(path, clear)
                    plain.size = contents.size.flatMap(vault.cleartextSize)
                    plain.mode = nil
                    result.append(plain)
                } else if kids.contains(where: { $0.name == "dir.c9r" }) {
                    result.append(FileItem(path: RemotePath.join(path, clear), isDirectory: true, modified: item.modified))
                }
            }
        }
        return result
    }

    public func createDirectory(_ path: String) async throws {
        guard contains(path), RemotePath.normalize(path) != root else { return try await inner.createDirectory(path) }
        let e = try await entry(for: path)
        let id = UUID().uuidString.lowercased()
        try await inner.createDirectory(e.path)
        if let long = e.long { try await Self.write(inner, Data(long.utf8), to: RemotePath.join(e.path, "name.c9s")) }
        try await Self.write(inner, Data(id.utf8), to: RemotePath.join(e.path, "dir.c9r"))
        try await makeCipherDirectory(for: id)
        lock.withLock { directoryIDs[RemotePath.normalize(path)] = id }
    }

    public func delete(_ item: FileItem) async throws {
        guard contains(item.path), RemotePath.normalize(item.path) != root else { return try await inner.delete(item) }
        let e = try await entry(for: item.path)
        if item.isDirectory {
            let id = try await directoryID(item.path)
            for child in try await list(item.path) { try await delete(child) }
            try await removeTree(cipherDirectory(id))
            try await removeTree(e.path)
            forget(RemotePath.normalize(item.path))
        } else if e.long != nil {
            try await removeTree(e.path)
        } else {
            try await remove(FileItem(path: e.path, isDirectory: false))
        }
    }

    /// Apaga de vez (nos discos locais, sem passar pelo Lixo: o conteúdo cifrado não serve lá).
    private func remove(_ item: FileItem) async throws {
        if inner is LocalFileSystem {
            try FileManager.default.removeItem(atPath: item.path)
        } else {
            try await inner.delete(item)
        }
    }

    private func removeTree(_ path: String) async throws {
        if inner is LocalFileSystem { return try FileManager.default.removeItem(atPath: path) }
        for child in (try? await inner.list(path)) ?? [] {
            if child.isDirectory { try await removeTree(child.path) } else { try await inner.delete(child) }
        }
        try await inner.delete(FileItem(path: path, isDirectory: true))
    }

    public func move(_ path: String, to newPath: String) async throws {
        guard contains(path), contains(newPath) else {
            guard !contains(path), !contains(newPath) else {
                throw WormlinkError.unsupportedOperation(String(localized: "Mover para dentro ou para fora de um cofre"))
            }
            return try await inner.move(path, to: newPath)
        }
        let old = try await entry(for: path), new = try await entry(for: newPath)
        let isDirectory = (try? await Self.read(inner, RemotePath.join(old.path, "dir.c9r"))) != nil
        switch (old.long, new.long) {
        case (nil, nil):
            try await inner.move(old.path, to: new.path)
        case (nil, let long?):
            if isDirectory {
                try await inner.move(old.path, to: new.path)
            } else {
                try await inner.createDirectory(new.path)
                try await inner.move(old.path, to: RemotePath.join(new.path, "contents.c9r"))
            }
            try await Self.write(inner, Data(long.utf8), to: RemotePath.join(new.path, "name.c9s"))
        case (_?, nil):
            if isDirectory {
                try await inner.move(old.path, to: new.path)
                try await remove(FileItem(path: RemotePath.join(new.path, "name.c9s"), isDirectory: false))
            } else {
                try await inner.move(RemotePath.join(old.path, "contents.c9r"), to: new.path)
                try await removeTree(old.path)
            }
        case (_?, let long?):
            try await inner.move(old.path, to: new.path)
            try await Self.write(inner, Data(long.utf8), to: RemotePath.join(new.path, "name.c9s"))
        }
        forget(RemotePath.normalize(path))
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard contains(path) else { return try await inner.download(path, to: local, progress: progress) }
        let e = try await entry(for: path)
        let temp = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp) }
        let ratio = Double(CryptomatorVault.chunkSize) / Double(CryptomatorVault.chunkSize + 48)
        try await inner.download(contentPath(e), to: temp) { progress(Int64(Double($0) * ratio)) }
        let vault = vault, name = RemotePath.name(path)
        try await Task.detached { try vault.decryptFile(temp, to: local, name: name) }.value
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard contains(path) else { return try await inner.upload(local, to: path, progress: progress) }
        let e = try await entry(for: path)
        let temp = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp) }
        let vault = vault
        try await Task.detached { try vault.encryptFile(local, to: temp) }.value
        if let long = e.long {
            try? await inner.createDirectory(e.path)
            try await Self.write(inner, Data(long.utf8), to: RemotePath.join(e.path, "name.c9s"))
        }
        let ratio = Double(CryptomatorVault.chunkSize) / Double(CryptomatorVault.chunkSize + 48)
        try await inner.upload(temp, to: contentPath(e)) { progress(Int64(Double($0) * ratio)) }
    }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        guard contains(path) else { return try await inner.setModificationDate(path, date) }
        try await inner.setModificationDate(contentPath(try await entry(for: path)), date)
    }

    /// O cofre é só uma vista sobre a conexão: quem fecha a conexão é o dono dela.
    public func disconnect() async {}

    // MARK: Arquivos pequenos

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "Wormlink-cofre-\(UUID().uuidString)")
    }

    static func read(_ fs: any FileSystem, _ path: String) async throws -> Data {
        let temp = temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp) }
        try await fs.download(path, to: temp) { _ in }
        return try Data(contentsOf: temp)
    }

    static func write(_ fs: any FileSystem, _ data: Data, to path: String) async throws {
        let temp = temporaryFile()
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp)
        try await fs.upload(temp, to: path) { _ in }
    }
}
