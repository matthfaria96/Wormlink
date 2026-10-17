import Foundation

/// Arquivo ou pasta listado num painel (local ou remoto).
public struct FileItem: Hashable, Identifiable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64?
    public var modified: Date?
    /// Bits de permissão POSIX (`0o755`), quando o protocolo informa.
    public var mode: UInt16?
    public var owner: String?
    public var group: String?
    /// Destino de um link simbólico, quando conhecido.
    public var linkTarget: String?

    public var id: String { path }
    public var name: String { RemotePath.name(path) }
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(path: String, isDirectory: Bool, isSymlink: Bool = false, size: Int64? = nil,
                modified: Date? = nil, mode: UInt16? = nil, owner: String? = nil, group: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.mode = mode
        self.owner = owner
        self.group = group
    }

    /// Permissões no formato `rwxr-xr-x`.
    public var permissions: String? { mode.map(FileItem.permissionString) }

    public static func permissionString(_ mode: UInt16) -> String {
        let flags: [(UInt16, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
                                            (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x")]
        return String(flags.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }
}

/// Operações comuns a todos os protocolos. Caminhos são absolutos e separados por `/`.
public protocol FileSystem: AnyObject, Sendable {
    /// Rótulo curto do painel (nome do favorito ou "Este Mac").
    var title: String { get }
    /// Pasta aberta ao conectar.
    var homePath: String { get }

    func list(_ path: String) async throws -> [FileItem]
    func createDirectory(_ path: String) async throws
    func delete(_ item: FileItem) async throws
    func move(_ path: String, to newPath: String) async throws
    /// Baixa um arquivo para `local`; `progress` recebe o total de bytes já transferidos.
    func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    /// Envia o arquivo `local` para `path`; `progress` recebe o total de bytes já transferidos.
    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    /// Altera as permissões POSIX (chmod). Nem todo protocolo suporta.
    func setPermissions(_ path: String, mode: UInt16) async throws
    var supportsPermissions: Bool { get }
    /// Retomada: baixar ou enviar continuando a partir de `offset` bytes.
    var canResumeDownloads: Bool { get }
    var canResumeUploads: Bool { get }
    func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws
    func upload(_ local: URL, to path: String, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws
    /// Preserva a data de modificação depois de uma transferência (deixa a sincronização estável).
    var supportsModificationDates: Bool { get }
    func setModificationDate(_ path: String, _ date: Date) async throws
    /// Soma de verificação calculada pelo servidor (nil quando o protocolo não oferece).
    func remoteChecksum(_ path: String) async throws -> Checksum?
    /// O servidor já troca o arquivo de uma vez (S3, nuvens): não precisa de nome temporário.
    var uploadsAreAtomic: Bool { get }
    /// Comandos remotos (shell via SSH ou comando FTP bruto).
    var supportsCommands: Bool { get }
    func execute(_ command: String) async throws -> String
    func disconnect() async
}

extension FileSystem {
    public func setPermissions(_ path: String, mode: UInt16) async throws {
        throw WormlinkError.unsupportedOperation(String(localized: "Alterar permissões"))
    }

    public var supportsPermissions: Bool { false }

    public var canResumeDownloads: Bool { false }
    public var canResumeUploads: Bool { false }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard offset == 0 else { throw WormlinkError.unsupportedOperation("Retomar download") }
        try await download(path, to: local, progress: progress)
    }

    public func upload(_ local: URL, to path: String, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard offset == 0 else { throw WormlinkError.unsupportedOperation("Retomar envio") }
        try await upload(local, to: path, progress: progress)
    }

    public var supportsModificationDates: Bool { false }

    public func remoteChecksum(_ path: String) async throws -> Checksum? { nil }

    public var uploadsAreAtomic: Bool { false }

    public var supportsCommands: Bool { false }

    public func execute(_ command: String) async throws -> String {
        throw WormlinkError.unsupportedOperation(String(localized: "Enviar comandos"))
    }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        throw WormlinkError.unsupportedOperation("Alterar a data")
    }

    /// Cria um arquivo vazio enviando um temporário de zero bytes.
    public func createFile(_ path: String) async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "Wormlink-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: temp) }
        try await upload(temp, to: path) { _ in }
    }
}

public enum WormlinkError: LocalizedError, Equatable {
    case invalidBookmark
    case unsupportedProtocol(String)
    case authenticationFailed
    case server(status: Int, message: String)
    case invalidResponse
    case notFound(String)
    case hostKeyRejected
    case unsupportedOperation(String)
    case connectionClosed
    case timedOut
    case missingClientID(String)
    case checksumMismatch(String)
    case awsProfileNotFound(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBookmark: String(localized: "O favorito não pôde ser lido.")
        case .unsupportedProtocol(let name): String(localized: "O protocolo \(name) ainda não está disponível nesta versão do Wormlink.")
        case .authenticationFailed: String(localized: "Usuário ou senha incorretos.")
        case .server(let status, let message): String(localized: "O servidor respondeu \(status): \(message)")
        case .invalidResponse: String(localized: "Resposta inesperada do servidor.")
        case .notFound(let path): String(localized: "“\(path)” não existe.")
        case .hostKeyRejected: String(localized: "A chave do servidor não foi aceita.")
        case .unsupportedOperation(let name): String(localized: "\(name) não é suportado por este protocolo.")
        case .connectionClosed: String(localized: "O servidor encerrou a conexão.")
        case .timedOut: String(localized: "O servidor demorou demais para responder.")
        case .checksumMismatch(let name): String(localized: "A verificação de “\(name)” falhou: o arquivo no destino é diferente da origem.")
        case .awsProfileNotFound(let name): String(localized: "O perfil “\(name)” não foi encontrado (ou não tem chaves) em ~/.aws/credentials ou ~/.aws/config.")
        case .commandFailed(let output): "O comando falhou: \(output)"
        case .missingClientID(let name): String(localized: "Falta o Client ID do \(name). Cadastre um app no provedor e cole o ID em Ajustes › Nuvens.")
        }
    }
}

/// Utilitários para caminhos remotos (sempre com `/`, independentes do sistema local).
public enum RemotePath {
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func join(_ base: String, _ name: String) -> String {
        normalize(base + "/" + name)
    }

    public static func parent(_ path: String) -> String {
        let p = normalize(path)
        guard p != "/" else { return "/" }
        return normalize(String(p[..<(p.lastIndex(of: "/") ?? p.startIndex)]))
    }

    public static func name(_ path: String) -> String {
        let p = normalize(path)
        return p == "/" ? "/" : String(p[p.index(after: p.lastIndex(of: "/")!)...])
    }

    /// Pastas do caminho, da raiz até ele (para a barra de caminho).
    public static func components(_ path: String) -> [String] {
        var result = ["/"]
        var current = "/"
        for part in normalize(path).split(separator: "/") {
            current = join(current, String(part))
            result.append(current)
        }
        return result
    }
}

/// Pasta de dados do Wormlink (favoritos, chaves de servidores aceitas, certificados).
/// Os testes trocam por uma pasta temporária para não tocar nos dados reais.
public enum WormlinkPaths {
    nonisolated(unsafe) public static var dataDirectory = URL.applicationSupportDirectory.appending(path: "Wormlink")
}

/// Prepara um arquivo local para receber dados a partir de `offset` (retomada).
enum LocalAppend {
    /// De onde a resposta HTTP realmente começa: 206 ou `Content-Range` no deslocamento pedido
    /// (alguns servidores mandam o trecho com status 200); senão o arquivo veio inteiro.
    static func effectiveOffset(_ offset: Int64, _ response: HTTPURLResponse) -> Int64 {
        guard offset > 0 else { return 0 }
        if let range = response.value(forHTTPHeaderField: "Content-Range") { return range.hasPrefix("bytes \(offset)-") ? offset : 0 }
        return response.statusCode == 206 ? offset : 0
    }

    static func prepare(_ url: URL, offset: Int64) throws {
        if offset == 0 || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
    }
}
