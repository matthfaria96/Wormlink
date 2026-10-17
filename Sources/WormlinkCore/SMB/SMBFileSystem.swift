import Foundation
import NetFS

/// SMB (Windows, NAS, macOS) usando o cliente SMB do próprio sistema: cada compartilhamento é montado pelo
/// NetFS numa pasta privada do app (sem aparecer no Finder) e as operações viram operações de disco.
/// Caminhos do Wormlink: "/COMPARTILHAMENTO/pasta/arquivo".
public final class SMBFileSystem: FileSystem, @unchecked Sendable {
    public let title: String
    public let homePath: String
    private let host: String
    private let port: Int
    private let user: String
    private let password: String?
    private let local = LocalFileSystem()
    private let lock = NSLock()
    private var mounts: [String: URL] = [:]
    /// Compartilhamentos que já estavam montados (Finder, outra janela): usados, mas nunca desmontados por aqui.
    private var borrowed = Set<String>()
    /// Pasta temporária do usuário, com o caminho real (/private/var/…): o macOS recusa montagens dentro de
    /// ~/Library e caminhos que passam por links simbólicos.
    static var mountRoot: URL {
        // realpath mantém o /private (resolvingSymlinksInPath o remove).
        let temp = FileManager.default.temporaryDirectory.path
        let real = realpath(temp, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? temp
        return URL(filePath: real).appending(path: "Wormlink-SMB")
    }

    init(bookmark: Bookmark, password: String?) {
        title = bookmark.displayName
        host = bookmark.hostname
        port = bookmark.port
        user = bookmark.username
        self.password = password
        homePath = RemotePath.normalize(bookmark.path)
    }

    /// Desmonta o que tiver sobrado de uma execução anterior (app encerrado à força).
    public static func cleanupStaleMounts() {
        let root = mountRoot
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            unmount(folder.path, MNT_FORCE)
            // rmdir só apaga pasta vazia: se a desmontagem falhou, o compartilhamento continua intacto.
            rmdir(folder.path)
        }
    }

    public static func connect(_ bookmark: Bookmark, password: String?) async throws -> SMBFileSystem {
        let fs = SMBFileSystem(bookmark: bookmark, password: password)
        if let share = fs.share(of: fs.homePath) { _ = try await fs.mountpoint(for: share) }
        return fs
    }

    // MARK: Montagem

    func share(of path: String) -> String? {
        RemotePath.normalize(path).split(separator: "/").first.map(String.init)
    }

    /// Monta o compartilhamento na primeira vez que é usado.
    func mountpoint(for share: String) async throws -> URL {
        if let existing = lock.withLock({ mounts[share] }) { return existing }
        let folder = Self.mountRoot.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var c = URLComponents()
        c.scheme = "smb"
        c.host = host
        if port != 445 { c.port = port }
        c.path = "/" + share
        guard let url = c.url else { throw WormlinkError.invalidBookmark }
        let (user, password) = (self.user, self.password)
        let status: Int32 = try await Task.detached {
            let open = NSMutableDictionary()
            open[kNetFSUseGuestKey] = user.isEmpty
            open[kNetFSAllowLoopbackKey] = true        // servidores em 127.0.0.1 / no próprio Mac
            open[kNAUIOptionKey] = kNAUIOptionNoUI     // sem janelas do sistema: erros voltam para o app
            let mount = NSMutableDictionary()
            mount[kNetFSMountAtMountDirKey] = true
            mount[kNetFSMountFlagsKey] = MNT_DONTBROWSE
            var points: Unmanaged<CFArray>?
            let result = NetFSMountURLSync(url as CFURL, folder as CFURL, user.isEmpty ? nil : user as CFString,
                                           (password ?? "") as CFString, open, mount, &points)
            points?.release()
            try Task.checkCancellation()
            return result
        }.value
        Transcript.log(title, "MOUNT \(url.absoluteString) → \(status)")
        if status == EEXIST, let existing = Self.existingMount(host: host, port: port, share: share) {
            rmdir(folder.path)
            Transcript.log(title, "Já montado em \(existing.path)")
            lock.withLock { mounts[share] = existing; borrowed.insert(share) }
            return existing
        }
        guard status == 0 else {
            rmdir(folder.path)
            // EAUTH (80) ou EACCES (13): usuário/senha.
            throw status == 80 || status == 13 || status == Int32(EAUTH) ? WormlinkError.authenticationFailed
                : WormlinkError.server(status: Int(status), message: String(cString: strerror(status)))
        }
        lock.withLock { mounts[share] = folder }
        return folder
    }

    /// Ponto de montagem de //…@host[:porta]/share já montado no sistema.
    static func existingMount(host: String, port: Int, share: String) -> URL? {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard count > 0, let pointer else { return nil }
        for entry in UnsafeBufferPointer(start: pointer, count: Int(count)) {
            var entry = entry
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard type == "smbfs" else { continue }
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if matches(from, host: host, port: port, share: share) { return URL(filePath: on) }
        }
        return nil
    }

    /// "//usuário@host:porta/SHARE" (usuário e porta opcionais) aponta para este servidor e compartilhamento?
    static func matches(_ from: String, host: String, port: Int, share: String) -> Bool {
        guard from.hasPrefix("//") else { return false }
        let rest = from.dropFirst(2)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        var server = String(rest[..<slash])
        if let at = server.lastIndex(of: "@") { server = String(server[server.index(after: at)...]) }
        let mountedPort = server.split(separator: ":").dropFirst().first.flatMap { Int($0) } ?? 445
        let mountedHost = server.split(separator: ":").first.map(String.init) ?? server
        let mountedShare = String(rest[rest.index(after: slash)...]).removingPercentEncoding ?? ""
        return mountedHost.caseInsensitiveCompare(host) == .orderedSame && mountedPort == port
            && mountedShare.caseInsensitiveCompare(share) == .orderedSame
    }

    /// Caminho remoto → caminho no disco montado.
    func localPath(_ path: String) async throws -> String {
        guard let share = share(of: path) else { throw WormlinkError.unsupportedOperation(String(localized: "Isto na raiz do servidor")) }
        let mount = try await mountpoint(for: share)
        let rest = RemotePath.normalize(path).split(separator: "/").dropFirst().joined(separator: "/")
        return rest.isEmpty ? mount.path : mount.appending(path: rest).path
    }

    private func remote(_ item: FileItem, share: String, mount: URL) -> FileItem {
        var copy = item
        let relative = String(item.path.dropFirst(RemotePath.normalize(mount.path).count))
        copy.path = RemotePath.normalize("/" + share + relative)
        copy.mode = nil   // SMB não tem permissões POSIX de verdade
        return copy
    }

    // MARK: Operações

    public func list(_ path: String) async throws -> [FileItem] {
        guard let share = share(of: path) else { return try listShares() }
        let mount = try await mountpoint(for: share)
        return try await local.list(try await localPath(path)).map { remote($0, share: share, mount: mount) }
            .filter { !$0.name.hasPrefix("._") && $0.name != ".DS_Store" }
    }

    /// Compartilhamentos do servidor (smbutil view), para quando o favorito não indica um.
    func listShares() throws -> [FileItem] {
        var c = URLComponents()
        c.host = host
        if !user.isEmpty { c.user = user; c.password = password }
        if port != 445 { c.port = port }
        let target = "//" + (c.string?.dropFirst(2) ?? Substring(host))
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/smbutil")
        process.arguments = ["view", "-N", String(target)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Self.parseShares(text).map { FileItem(path: "/" + $0, isDirectory: true) }
    }

    /// Linhas "Nome  Disk  Comentário" da saída do smbutil (só discos, sem IPC$).
    static func parseShares(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            // O nome pode ter espaços ("Meus Arquivos   Disk   comentário"): vale o que vem antes da coluna Disk.
            guard let match = line.firstMatch(of: /^(.+?)\s+Disk(\s|$)/) else { return nil }
            let name = String(match.output.1).trimmingCharacters(in: .whitespaces)
            return name.isEmpty || name.hasSuffix("$") ? nil : name
        }
    }

    public func createDirectory(_ path: String) async throws { try await local.createDirectory(try await localPath(path)) }

    /// Itens do servidor são apagados de vez (não há Lixo em compartilhamentos).
    public func delete(_ item: FileItem) async throws {
        try FileManager.default.removeItem(atPath: try await localPath(item.path))
    }

    public func move(_ path: String, to newPath: String) async throws {
        try await local.move(try await localPath(path), to: try await localPath(newPath))
    }

    public var canResumeDownloads: Bool { true }
    public var canResumeUploads: Bool { true }
    public var supportsModificationDates: Bool { true }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        try await local.setModificationDate(try await localPath(path), date)
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to destination: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let source = URL(filePath: try await localPath(path))
        try await Task.detached { try LocalFileSystem.stream(source, to: destination, offset: offset, progress: progress) }.value
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await upload(local, to: path, offset: 0, progress: progress)
    }

    public func upload(_ source: URL, to path: String, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let destination = URL(filePath: try await localPath(path))
        try await Task.detached { try LocalFileSystem.stream(source, to: destination, offset: offset, progress: progress) }.value
    }

    public func disconnect() async {
        let folders = lock.withLock { () -> [URL] in
            defer { mounts.removeAll(); borrowed.removeAll() }
            return mounts.filter { !borrowed.contains($0.key) }.map(\.value)
        }
        for folder in folders {
            try? await FileManager.default.unmountVolume(at: folder, options: [.withoutUI])
            rmdir(folder.path)   // nunca removeItem: numa montagem ainda ativa ele apagaria o servidor
        }
    }

    deinit {
        // Garante que nada fique montado se a conexão sumir sem disconnect().
        for (share, folder) in mounts where !borrowed.contains(share) { unmount(folder.path, MNT_FORCE) }
    }
}
