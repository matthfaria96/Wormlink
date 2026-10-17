@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// SFTP sobre SSH (Citadel + SwiftNIO SSH). Leituras e escritas usam várias requisições
/// simultâneas, como o Cyberduck, para não esperar uma ida e volta por bloco.
public final class SFTPFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    /// Pasta de login do usuário no servidor (para ~/.ssh/authorized_keys).
    public let loginDirectory: String
    private let ssh: SSHClient
    private let sftp: SFTPClient

    /// Tamanho de cada bloco e quantos ficam em voo ao mesmo tempo.
    static let chunk = 32 * 1024
    static let window = 16

    private init(title: String, homePath: String, loginDirectory: String, ssh: SSHClient, sftp: SFTPClient) {
        self.title = title
        self.homePath = homePath
        self.loginDirectory = loginDirectory
        self.ssh = ssh
        self.sftp = sftp
    }

    /// Um destino SSH já resolvido pelo ~/.ssh/config.
    struct Hop {
        var host: String
        var port: Int
        var user: String
        var config: SSHConfig.Resolved
    }

    /// `[usuário@]host[:porta]`, como no ProxyJump; o host pode ser outro alias do config.
    static func hop(_ spec: String, config file: SSHConfig, defaultUser: String) -> Hop {
        var rest = Substring(spec)
        var user: String?
        if let at = rest.lastIndex(of: "@") { user = String(rest[..<at]); rest = rest[rest.index(after: at)...] }
        var port: Int?
        if let colon = rest.lastIndex(of: ":"), !rest.contains("]") { port = Int(rest[rest.index(after: colon)...]); rest = rest[..<colon] }
        let alias = String(rest)
        let resolved = file.resolve(alias)
        return Hop(host: resolved.hostName ?? alias, port: port ?? resolved.port ?? 22,
                   user: user ?? resolved.user ?? defaultUser, config: resolved)
    }

    public static func connect(_ bookmark: Bookmark, password: String?, trust: ConnectionTrust) async throws -> SFTPFileSystem {
        let file = SSHConfig.load()
        let resolved = file.resolve(bookmark.hostname)
        // O endereço pode ser um alias do ~/.ssh/config; campos preenchidos no favorito têm prioridade.
        let target = Hop(host: resolved.hostName ?? bookmark.hostname,
                         port: bookmark.port != 22 ? bookmark.port : (resolved.port ?? 22),
                         user: bookmark.username.isEmpty ? (resolved.user ?? NSUserName()) : bookmark.username,
                         config: resolved)
        let agent = SSHAgent.default(identityAgent: resolved.identityAgent)

        func settings(_ hop: Hop, keyFile: String?, password: String?) async -> SSHClientSettings {
            let auth = await SSHUserAuth.make(username: hop.user, password: password, keyFile: keyFile, config: hop.config,
                                              agent: SSHAgent.default(identityAgent: hop.config.identityAgent) ?? agent,
                                              passphrase: trust.passphrase,
                                              interactive: InteractiveResponder(host: hop.host, user: hop.user, password: password,
                                                                                prompt: trust.interactive))
            var settings = SSHClientSettings(host: hop.host, port: hop.port, authenticationMethod: { .custom(auth) },
                                             hostKeyValidator: .custom(HostKeyValidator(host: hop.host, port: hop.port, trust: trust.hostKey)))
            settings.connectTimeout = .seconds(Int64(bookmark.timeout ?? 20))
            return settings
        }

        let ssh: SSHClient
        do {
            let jumps = (resolved.proxyJump ?? "").split(separator: ",").map { hop(String($0), config: file, defaultUser: target.user) }
            if jumps.isEmpty {
                ssh = try await SSHClient.connect(to: await settings(target, keyFile: bookmark.keyFile, password: password))
            } else {
                // ProxyJump: conecta no primeiro bastion e salta até o destino.
                Transcript.log(bookmark.displayName, "ProxyJump " + jumps.map { "\($0.user)@\($0.host):\($0.port)" }.joined(separator: " → "))
                var client = try await SSHClient.connect(to: await settings(jumps[0], keyFile: nil, password: nil))
                for next in jumps.dropFirst() { client = try await client.jump(to: await settings(next, keyFile: nil, password: nil)) }
                ssh = try await client.jump(to: await settings(target, keyFile: bookmark.keyFile, password: password))
            }
        } catch let error as WormlinkError {
            throw error
        } catch {
            if "\(error)".contains("allAuthenticationOptionsFailed") || "\(error)".contains("authenticationFailed") {
                throw WormlinkError.authenticationFailed
            }
            throw error
        }
        let sftp = try await ssh.openSFTP()
        let login = (try? await sftp.getRealPath(atPath: ".")) ?? "/"
        let start = bookmark.path.isEmpty ? login : bookmark.path
        return SFTPFileSystem(title: bookmark.displayName, homePath: RemotePath.normalize(start), loginDirectory: RemotePath.normalize(login),
                              ssh: ssh, sftp: sftp)
    }

    // MARK: Listagem

    public func list(_ path: String) async throws -> [FileItem] {
        let dir = RemotePath.normalize(path)
        Transcript.log(title, "LIST \(dir)")
        var items: [FileItem] = []
        for name in try await sftp.listDirectory(atPath: dir) {
            for component in name.components where component.filename != "." && component.filename != ".." {
                var item = Self.item(RemotePath.join(dir, component.filename), component.attributes, longname: component.longname)
                if item.isSymlink, let target = try? await sftp.getAttributes(at: item.path) {
                    // Links seguem o destino para saber se abrem como pasta.
                    item.isDirectory = Self.isDirectory(target.permissions)
                    if !item.isDirectory { item.size = target.size.map(Int64.init) }
                }
                items.append(item)
            }
        }
        return items
    }

    static func item(_ path: String, _ a: SFTPFileAttributes, longname: String = "") -> FileItem {
        let type = (a.permissions ?? 0) & 0o170000
        let isDir = type == 0o040000 || (a.permissions == nil && longname.hasPrefix("d"))
        let fields = longname.split(separator: " ", omittingEmptySubsequences: true)
        return FileItem(path: path, isDirectory: isDir, isSymlink: type == 0o120000,
                        size: isDir ? nil : a.size.map(Int64.init),
                        modified: a.accessModificationTime?.modificationTime,
                        mode: a.permissions.map { UInt16($0 & 0o7777) },
                        // `ls -l`: permissões, links, dono, grupo…
                        owner: fields.count > 3 ? String(fields[2]) : a.uidgid.map { "\($0.userId)" },
                        group: fields.count > 3 ? String(fields[3]) : a.uidgid.map { "\($0.groupId)" })
    }

    static func isDirectory(_ permissions: UInt32?) -> Bool { (permissions ?? 0) & 0o170000 == 0o040000 }

    // MARK: Operações

    public func createDirectory(_ path: String) async throws {
        Transcript.log(title, "MKDIR \(path)")
        try await sftp.createDirectory(atPath: RemotePath.normalize(path))
    }

    public func delete(_ item: FileItem) async throws {
        Transcript.log(title, "DELETE \(item.path)")
        if item.isDirectory && !item.isSymlink {
            for child in try await list(item.path) { try await delete(child) }
            try await sftp.rmdir(at: item.path)
        } else {
            try await sftp.remove(at: item.path)
        }
    }

    public func move(_ path: String, to newPath: String) async throws {
        Transcript.log(title, "RENAME \(path) → \(newPath)")
        try await sftp.rename(at: RemotePath.normalize(path), to: RemotePath.normalize(newPath))
    }

    public var supportsPermissions: Bool { true }

    public func setPermissions(_ path: String, mode: UInt16) async throws {
        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(mode)
        try await sftp.setAttributes(at: path, to: attributes)
    }

    // MARK: Transferências

    public var canResumeDownloads: Bool { true }
    public var canResumeUploads: Bool { true }
    public var supportsModificationDates: Bool { true }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        var attributes = SFTPFileAttributes()
        attributes.accessModificationTime = .init(accessTime: date, modificationTime: date)
        try await sftp.setAttributes(at: path, to: attributes)
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset start: Int64,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        Transcript.log(title, "GET \(path)" + (start > 0 ? " (retomando de \(start))" : ""))
        let size = Int64(try await sftp.getAttributes(at: path).size ?? 0)
        if start == 0 || !FileManager.default.fileExists(atPath: local.path) {
            FileManager.default.createFile(atPath: local.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(start))
        try handle.seekToEnd()
        let file = try await sftp.openFile(filePath: path, flags: .read)
        do {
            var offset: Int64 = start
            while offset < size {
                try Task.checkCancellation()
                // Uma janela de leituras em paralelo; os blocos são gravados em ordem.
                let end = min(size, offset + Int64(Self.window * Self.chunk))
                let starts = Array(stride(from: offset, to: end, by: Self.chunk))
                let blocks = try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
                    for start in starts {
                        let length = Int(min(Int64(Self.chunk), end - start))
                        group.addTask { (start, try await Self.read(file, at: start, length: length)) }
                    }
                    var result: [Int64: Data] = [:]
                    for try await (start, data) in group { result[start] = data }
                    return result
                }
                for start in starts { try handle.write(contentsOf: blocks[start] ?? Data()) }
                await BandwidthLimiter.shared.throttle(Int(end - offset), .download)
                offset = end
                progress(offset)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// Lê exatamente `length` bytes (o servidor pode devolver menos por resposta).
    private static func read(_ file: SFTPFile, at start: Int64, length: Int) async throws -> Data {
        var data = Data(capacity: length)
        while data.count < length {
            let buffer = try await file.read(from: UInt64(start) + UInt64(data.count), length: UInt32(length - data.count))
            guard buffer.readableBytes > 0 else { break }   // arquivo encolheu durante a leitura
            data.append(contentsOf: buffer.readableBytesView)
        }
        return data
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await upload(local, to: path, offset: 0, progress: progress)
    }

    public func upload(_ local: URL, to path: String, offset start: Int64,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        Transcript.log(title, "PUT \(path)" + (start > 0 ? " (retomando de \(start))" : ""))
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(start))
        let file = try await sftp.openFile(filePath: path, flags: start > 0 ? [.write, .create] : [.write, .create, .truncate])
        do {
            var offset: Int64 = start
            while true {
                try Task.checkCancellation()
                var blocks: [(Int64, Data)] = []
                for _ in 0..<Self.window {
                    guard let data = try reader.read(upToCount: Self.chunk), !data.isEmpty else { break }
                    blocks.append((offset, data))
                    offset += Int64(data.count)
                }
                if blocks.isEmpty { break }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (start, data) in blocks {
                        group.addTask { try await file.write(ByteBuffer(data: data), at: UInt64(start)) }
                    }
                    try await group.waitForAll()
                }
                await BandwidthLimiter.shared.throttle(blocks.reduce(0) { $0 + $1.1.count }, .upload)
                progress(offset)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    // MARK: Comandos (shell remoto)

    public var supportsCommands: Bool { true }

    public func execute(_ command: String) async throws -> String {
        Transcript.log(title, "$ \(command)")
        do {
            let output = try await ssh.executeCommand(command, maxResponseSize: 4 * 1024 * 1024, mergeStreams: true)
            return String(buffer: output)
        } catch {
            throw WormlinkError.commandFailed(String(describing: error))
        }
    }

    /// Caminho entre aspas simples para o shell remoto.
    public static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// SHA-256 calculado no servidor (sha256sum no Linux, shasum no macOS/BSD), quando há shell.
    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        let quoted = Self.shellQuote(path)
        guard let output = try? await execute("sha256sum -- \(quoted) 2>/dev/null || shasum -a 256 \(quoted)"),
              let hex = output.split(separator: " ").first, hex.count == 64 else { return nil }
        return Checksum(.sha256, String(hex))
    }

    public func disconnect() async {
        try? await sftp.close()
        try? await ssh.close()
    }
}

/// Erros de status do SFTP com mensagens legíveis (em vez de "SFTPMessage.Status erro 1").
extension SFTPMessage.Status: @retroactive LocalizedError {
    public var errorDescription: String? {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String = switch errorCode {
        case .noSuchFile: "Arquivo ou pasta não encontrado no servidor."
        case .permissionDenied: "Permissão negada pelo servidor."
        case .eof: "Fim do arquivo."
        case .noConnection, .connectionLost: "A conexão com o servidor caiu."
        case .unsupportedOperation: "O servidor não permite esta operação."
        case .badMessage: "O servidor não entendeu o pedido."
        default: "O servidor recusou a operação."
        }
        return detail.isEmpty || detail.lowercased() == "failure" ? text : "\(text) (\(detail))"
    }
}
