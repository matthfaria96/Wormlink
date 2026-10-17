import Foundation

/// FTP, FTP com TLS explícito (AUTH TLS) e FTPS implícito.
/// Como no Cyberduck, a navegação usa uma conexão de controle e cada transferência abre a sua.
public final class FTPFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    private let config: FTPConfig
    private let queue = SerialQueue()
    private let browser: Box

    /// A conexão de navegação é refeita se o servidor a derrubar por inatividade.
    private final class Box: @unchecked Sendable { var connection: FTPConnection; init(_ c: FTPConnection) { connection = c } }

    private init(title: String, homePath: String, config: FTPConfig, connection: FTPConnection) {
        self.title = title
        self.homePath = homePath
        self.config = config
        browser = Box(connection)
    }

    public static func connect(_ bookmark: Bookmark, password: String?, certificateTrust: @escaping CertificateTrust) async throws -> FTPFileSystem {
        let security: FTPSecurity = switch bookmark.connectionProtocol {
        case .ftps: bookmark.port == 990 ? .implicitTLS : .explicitTLS
        default: .none
        }
        var config = FTPConfig(host: bookmark.hostname, port: bookmark.port, username: bookmark.username,
                               password: password ?? "", security: security, certificateTrust: certificateTrust)
        config.encoding = bookmark.stringEncoding
        config.useMLSD = bookmark.ftpUseMLSD ?? true
        config.timeout = bookmark.timeout ?? 20
        if bookmark.ftpASCIIMode == true { config.asciiExtensions = FTPFileSystem.asciiExtensions }
        let connection = try await FTPConnection.open(config)
        var home = RemotePath.normalize(bookmark.path)
        if bookmark.path.isEmpty, let pwd = try? await connection.command("PWD"), pwd.code == 257,
           let first = pwd.text.firstIndex(of: "\""), let last = pwd.text.lastIndex(of: "\""), first < last {
            home = RemotePath.normalize(String(pwd.text[pwd.text.index(after: first)..<last]))
        }
        return FTPFileSystem(title: bookmark.displayName, homePath: home, config: config, connection: connection)
    }

    /// Executa na conexão de navegação, reconectando uma vez se ela caiu.
    private func browse<T: Sendable>(_ body: @escaping @Sendable (FTPConnection) async throws -> T) async throws -> T {
        try await queue.run { [browser, config] in
            if !browser.connection.isOpen { browser.connection = try await FTPConnection.open(config) }
            do {
                return try await body(browser.connection)
            } catch WormlinkError.connectionClosed {
                browser.connection = try await FTPConnection.open(config)
                return try await body(browser.connection)
            } catch let error as WormlinkError {
                // Resposta do servidor lida normalmente: o canal segue em sincronia. Qualquer outra falha (tempo
                // esgotado, conexão de dados caída) pode deixar uma resposta pendente; fecha para a próxima reabrir.
                if case .server = error {} else if case .notFound = error {} else { await browser.connection.close() }
                throw error
            } catch {
                await browser.connection.close()
                throw error
            }
        }
    }

    public func list(_ path: String) async throws -> [FileItem] {
        try await browse { try await $0.list(RemotePath.normalize(path)) }
    }

    public func createDirectory(_ path: String) async throws {
        try await browse { c in _ = try await c.expect(await c.command("MKD \(RemotePath.normalize(path))"), 257, 250) }
    }

    public func delete(_ item: FileItem) async throws {
        if item.isDirectory && !item.isSymlink {
            for child in try await list(item.path) { try await delete(child) }
            try await browse { c in _ = try await c.expect(await c.command("RMD \(item.path)"), 250) }
        } else {
            try await browse { c in _ = try await c.expect(await c.command("DELE \(item.path)"), 250) }
        }
    }

    public func move(_ path: String, to newPath: String) async throws {
        try await browse { c in
            _ = try await c.expect(await c.command("RNFR \(RemotePath.normalize(path))"), 350)
            _ = try await c.expect(await c.command("RNTO \(RemotePath.normalize(newPath))"), 250)
        }
    }

    public var supportsPermissions: Bool { true }

    public func setPermissions(_ path: String, mode: UInt16) async throws {
        try await browse { c in _ = try await c.expect(await c.command("SITE CHMOD \(String(mode, radix: 8)) \(path)"), 200) }
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await upload(local, to: path, offset: 0, progress: progress)
    }

    public var canResumeDownloads: Bool { true }
    public var canResumeUploads: Bool { true }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTransferConnection { try await $0.download(path, to: local, offset: offset, progress: progress) }
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTransferConnection { try await $0.upload(local, to: path, offset: offset, progress: progress) }
    }

    /// MFMT (draft-somers-ftp-mfxx), quando o servidor anuncia.
    public var supportsModificationDates: Bool { browser.connection.features.contains { $0.hasPrefix("MFMT") } }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        let stamp = FTPListParser.mlsdFormatter.string(from: date)
        try await browse { c in _ = try await c.expect(await c.command("MFMT \(stamp) \(path)"), 213) }
    }

    /// Cada transferência usa uma conexão própria, para não bloquear a navegação.
    private func withTransferConnection(_ body: (FTPConnection) async throws -> Void) async throws {
        let connection = try await FTPConnection.open(config)
        do {
            try await body(connection)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    // MARK: Comando bruto e checksum

    public var supportsCommands: Bool { true }

    /// Extensões de texto transferidas em ASCII quando o servidor tem o modo ASCII ligado ("AsciiFileTypes" do Transmit).
    public static var asciiExtensions: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: "asciiExtensions") ?? defaultASCIIExtensions).map { $0.lowercased() })
    }

    public static let defaultASCIIExtensions = ["txt", "html", "htm", "css", "js", "php", "pl", "py", "rb", "sh", "cgi", "xml",
                                                "json", "md", "csv", "ini", "conf", "cfg", "htaccess", "sql", "svg", "yml", "yaml"]

    /// Envia um comando FTP como está ("Send Raw Command" do Transmit) e devolve a resposta.
    public func execute(_ command: String) async throws -> String {
        try await browse { c in try await c.command(command).text }
    }

    /// HASH (draft-bryan-ftpext-hash) ou os comandos não padronizados XSHA256/XMD5, quando o servidor anuncia.
    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        try await browse { c in
            let features = c.features
            func hex(_ reply: FTPReply) -> String? {
                reply.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
                    .first { $0.count == 64 || $0.count == 32 && $0.allSatisfy(\.isHexDigit) }
            }
            if features.contains(where: { $0.hasPrefix("HASH") && $0.contains("SHA-256") }) {
                _ = try await c.command("OPTS HASH SHA-256")
                let reply = try await c.command("HASH \(path)")
                if reply.code == 213, let value = hex(reply), value.count == 64 { return Checksum(.sha256, value) }
            }
            if features.contains("XSHA256") {
                let reply = try await c.command("XSHA256 \(path)")
                if reply.code == 250, let value = hex(reply), value.count == 64 { return Checksum(.sha256, value) }
            }
            if features.contains("XMD5") {
                let reply = try await c.command("XMD5 \(path)")
                if reply.code == 250, let value = hex(reply), value.count == 32 { return Checksum(.md5, value) }
            }
            return nil
        }
    }

    public func disconnect() async {
        await browser.connection.close()
    }
}

/// Executa operações assíncronas uma de cada vez, na ordem de chegada.
actor SerialQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await operation()
    }
}
