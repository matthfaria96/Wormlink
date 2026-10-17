import Foundation

/// Servidor salvo (favorito).
public struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var nickname: String
    public var connectionProtocol: ConnectionProtocol
    public var hostname: String
    public var port: Int
    public var username: String
    /// Pasta remota inicial; vazio abre a pasta padrão do servidor.
    public var path: String
    /// Pasta local que o painel esquerdo abre junto com este favorito.
    public var localPath: String?
    public var comment: String?
    /// Chave SSH privada escolhida para este servidor (além das de `~/.ssh`).
    public var keyFile: String?
    /// Ícone e cor do cartão na grade de servidores.
    public var icon: ServerIcon = .globe
    public var color: ServerColor = .violet
    /// Pastas atalho deste servidor (barra de Places).
    public var places: [String] = []
    public var lastUsed: Date?
    /// URL pública que corresponde à pasta remota ("Root URL" no Transmit, "Web URL" no Cyberduck).
    public var webURL: String?
    /// S3: perfil da AWS CLI (~/.aws), papel IAM para AssumeRole, External ID, dispositivo MFA e endpoint do STS.
    public var awsProfile: String?
    public var roleARN: String?
    public var externalID: String?
    public var mfaSerial: String?
    public var stsEndpoint: String?
    /// S3: padrões para arquivos novos (classe de armazenamento, criptografia, ACL) e opções do bucket.
    public var s3StorageClass: String?
    public var s3Encryption: String?
    public var s3ACL: String?
    public var s3RequesterPays: Bool?
    public var s3Accelerate: Bool?
    /// OpenStack Swift: caminho de autenticação ("/v3", "/v2.0", "/auth/v1.0") e região do catálogo.
    public var swiftAuthPath: String?
    public var swiftRegion: String?
    /// Ajustes por servidor (Transmit "ServerSpecificPrefs"): codificação de nomes (FTP), tempo limite,
    /// MLSD e modo ASCII por extensão.
    public var encoding: String?
    public var timeout: Int?
    public var ftpUseMLSD: Bool?
    public var ftpASCIIMode: Bool?
    /// Perfil de conexão usado ao criar (rótulos e ajudas no editor).
    public var preset: String?
    /// Grupo (pasta) na lista de servidores.
    public var group: String?
    /// S3 compatível sem TLS (ex.: servidor local). Equivale ao perfil "S3 (HTTP)" do Cyberduck.
    public var plainHTTP = false

    public init(id: UUID = UUID(), nickname: String = "", connectionProtocol: ConnectionProtocol = .sftp,
                hostname: String = "", port: Int? = nil, username: String = "", path: String = "",
                localPath: String? = nil, comment: String? = nil) {
        self.id = id
        self.nickname = nickname
        self.connectionProtocol = connectionProtocol
        self.hostname = hostname
        self.port = port ?? connectionProtocol.defaultPort
        self.username = username
        self.path = path
        self.localPath = localPath
        self.comment = comment
    }

    public var displayName: String { nickname.isEmpty ? hostname : nickname }

    /// `protocolo://usuario@servidor:porta/caminho`, omitindo a porta padrão.
    public var url: URL? {
        var c = URLComponents()
        c.scheme = connectionProtocol.scheme
        c.host = hostname
        if !username.isEmpty { c.user = username }
        if port != connectionProtocol.defaultPort { c.port = port }
        c.path = path.isEmpty ? "" : RemotePath.normalize(path)
        return c.url
    }

    /// Cria um favorito a partir de um endereço digitado, como `sftp://ana@exemplo.com:2222/www`.
    public init?(address: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "sftp://" + text }
        guard let c = URLComponents(string: text), let scheme = c.scheme,
              let proto = ConnectionProtocol(scheme: scheme), let host = c.host, !host.isEmpty else { return nil }
        self.init(connectionProtocol: proto, hostname: host, port: c.port, username: c.user ?? "",
                  path: c.path == "/" ? "" : c.path)
    }
}

/// Símbolos que o usuário pode escolher para o cartão do servidor.
public enum ServerIcon: String, Codable, CaseIterable, Sendable {
    case globe, server, cloud, lock, bolt, heart, house, briefcase, photo, music, film, archive, terminal, cart, star, leaf

    public static func `default`(for proto: ConnectionProtocol) -> ServerIcon {
        switch proto {
        case .sftp: .terminal
        case .ftp, .ftps, .smb: .server
        case .s3, .azure, .swift: .cloud
        case .webdav, .webdavs: .globe
        case .dropbox, .b2, .box: .archive
        case .googleDrive, .oneDrive: .cloud
        case .sharePoint: .briefcase
        }
    }

    public var symbolName: String {
        switch self {
        case .globe: "globe"
        case .server: "server.rack"
        case .cloud: "cloud.fill"
        case .lock: "lock.fill"
        case .bolt: "bolt.fill"
        case .heart: "heart.fill"
        case .house: "house.fill"
        case .briefcase: "briefcase.fill"
        case .photo: "photo.fill"
        case .music: "music.note"
        case .film: "film.fill"
        case .archive: "archivebox.fill"
        case .terminal: "apple.terminal.fill"
        case .cart: "cart.fill"
        case .star: "star.fill"
        case .leaf: "leaf.fill"
        }
    }
}

public enum ServerColor: String, Codable, CaseIterable, Sendable {
    case violet, blue, teal, green, yellow, orange, red, pink, graphite
}

// MARK: - Decodificação tolerante (campos novos são opcionais em arquivos antigos)

extension Bookmark {
    enum CodingKeys: String, CodingKey {
        case id, nickname, connectionProtocol, hostname, port, username, path, localPath, comment, keyFile, icon, color, places, lastUsed, plainHTTP, webURL, group, awsProfile, roleARN, externalID, mfaSerial, stsEndpoint, preset, swiftAuthPath, swiftRegion, encoding, timeout, ftpUseMLSD, ftpASCIIMode, s3StorageClass, s3Encryption, s3ACL, s3RequesterPays, s3Accelerate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        connectionProtocol = try c.decode(ConnectionProtocol.self, forKey: .connectionProtocol)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? connectionProtocol.defaultPort
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        keyFile = try c.decodeIfPresent(String.self, forKey: .keyFile)
        icon = (try? c.decodeIfPresent(ServerIcon.self, forKey: .icon)) ?? .globe
        color = (try? c.decodeIfPresent(ServerColor.self, forKey: .color)) ?? .violet
        places = try c.decodeIfPresent([String].self, forKey: .places) ?? []
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
        plainHTTP = try c.decodeIfPresent(Bool.self, forKey: .plainHTTP) ?? false
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile)
        roleARN = try c.decodeIfPresent(String.self, forKey: .roleARN)
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        mfaSerial = try c.decodeIfPresent(String.self, forKey: .mfaSerial)
        stsEndpoint = try c.decodeIfPresent(String.self, forKey: .stsEndpoint)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        swiftAuthPath = try c.decodeIfPresent(String.self, forKey: .swiftAuthPath)
        swiftRegion = try c.decodeIfPresent(String.self, forKey: .swiftRegion)
        encoding = try c.decodeIfPresent(String.self, forKey: .encoding)
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        ftpUseMLSD = try c.decodeIfPresent(Bool.self, forKey: .ftpUseMLSD)
        ftpASCIIMode = try c.decodeIfPresent(Bool.self, forKey: .ftpASCIIMode)
        s3StorageClass = try c.decodeIfPresent(String.self, forKey: .s3StorageClass)
        s3Encryption = try c.decodeIfPresent(String.self, forKey: .s3Encryption)
        s3ACL = try c.decodeIfPresent(String.self, forKey: .s3ACL)
        s3RequesterPays = try c.decodeIfPresent(Bool.self, forKey: .s3RequesterPays)
        s3Accelerate = try c.decodeIfPresent(Bool.self, forKey: .s3Accelerate)
    }

    /// Codificação escolhida para nomes de arquivo (padrão UTF-8).
    public var stringEncoding: String.Encoding {
        guard let encoding, !encoding.isEmpty else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
        return cf == kCFStringEncodingInvalidId ? .utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

// MARK: - Cyberduck

extension Bookmark {
    /// Lê um favorito do Cyberduck (`.duck`, plist com as chaves de `Host.serialize`).
    public init(cyberduckPlist data: Data) throws {
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw WormlinkError.invalidBookmark
        }
        func string(_ key: String) -> String? { (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let host = string("Hostname") else { throw WormlinkError.invalidBookmark }
        let proto = string("Protocol").flatMap(ConnectionProtocol.init(rawValue:))
            ?? string("Protocol").flatMap(ConnectionProtocol.init(scheme:)) ?? .sftp
        self.init(
            id: string("UUID").flatMap(UUID.init(uuidString:)) ?? UUID(),
            nickname: string("Nickname") ?? "",
            connectionProtocol: proto,
            hostname: host,
            port: string("Port").flatMap(Int.init),
            username: string("Username") ?? "",
            path: string("Path") ?? "",
            localPath: string("Download Folder").map { ($0 as NSString).expandingTildeInPath },
            comment: string("Comment")
        )
        keyFile = string("Private Key File")
        webURL = string("Web URL")
        icon = ServerIcon.default(for: proto)
    }

    /// Pasta onde o Cyberduck guarda os favoritos.
    public static var cyberduckBookmarksFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/G69SCX94XU.duck/Library/Application Support/duck/Bookmarks")
    }

    /// Todos os favoritos do Cyberduck instalados neste Mac (vazio se não houver).
    public static func importCyberduckBookmarks(from folder: URL = cyberduckBookmarksFolder) -> [Bookmark] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "duck" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Bookmark(cyberduckPlist: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Persistência

/// Lista de favoritos gravada em JSON em Application Support.
public struct BookmarkStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = BookmarkStore.defaultURL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        WormlinkPaths.dataDirectory.appending(path: "Bookmarks.json")
    }

    public func load() -> [Bookmark] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    public func save(_ bookmarks: [Bookmark]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bookmarks).write(to: fileURL, options: .atomic)
    }
}

extension Bookmark {
    /// Endereço público de um item, a partir da URL raiz (como o "Create URL" do Transmit
    /// e o "Copy URL" do Cyberduck). Sem URL raiz, usa o endereço do protocolo.
    public func publicURL(for itemPath: String) -> URL? {
        let normalized = RemotePath.normalize(itemPath)
        if let root = webURL, !root.isEmpty, var base = URL(string: root) {
            let remoteRoot = RemotePath.normalize(path)
            var relative = normalized
            if remoteRoot != "/", normalized.hasPrefix(remoteRoot) { relative = String(normalized.dropFirst(remoteRoot.count)) }
            for part in relative.split(separator: "/") { base.append(path: String(part)) }
            return base
        }
        var c = URLComponents()
        c.scheme = connectionProtocol.scheme
        c.host = hostname
        if !username.isEmpty { c.user = username }
        if port != connectionProtocol.defaultPort { c.port = port }
        c.path = normalized
        return c.url
    }
}
