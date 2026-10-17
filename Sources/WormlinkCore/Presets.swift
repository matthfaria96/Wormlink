import Foundation

/// Perfil de conexão: um serviço com endereço, porta e rótulos já definidos, sobre um protocolo existente
/// (os "connection profiles" do Cyberduck e os protocolos extras do Transmit).
public struct ConnectionPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var connectionProtocol: ConnectionProtocol
    public var hostname: String
    public var port: Int?
    /// Pasta inicial; `{user}` vira o nome do usuário (Nextcloud/ownCloud).
    public var path: String
    public var hostnameEditable: Bool
    public var userLabel: String?
    public var passwordLabel: String?
    public var plainHTTP: Bool
    public var icon: ServerIcon
    public var note: String?

    public init(id: String, name: String, protocol proto: ConnectionProtocol, hostname: String = "", port: Int? = nil, path: String = "",
                hostnameEditable: Bool = true, userLabel: String? = nil, passwordLabel: String? = nil, plainHTTP: Bool = false,
                icon: ServerIcon, note: String? = nil) {
        self.id = id
        self.name = name
        self.connectionProtocol = proto
        self.hostname = hostname
        self.port = port
        self.path = path
        self.hostnameEditable = hostnameEditable
        self.userLabel = userLabel
        self.passwordLabel = passwordLabel
        self.plainHTTP = plainHTTP
        self.icon = icon
        self.note = note
    }

    /// Aplica o perfil a um favorito (mantendo apelido, usuário e senha).
    public func apply(to bookmark: inout Bookmark) {
        bookmark.connectionProtocol = connectionProtocol
        bookmark.hostname = hostname
        bookmark.port = port ?? connectionProtocol.defaultPort
        bookmark.path = path.replacingOccurrences(of: "{user}", with: bookmark.username)
        bookmark.plainHTTP = plainHTTP
        bookmark.icon = icon
        bookmark.preset = id
    }

    public static let builtIn: [ConnectionPreset] = [
        .init(id: "b2", name: "Backblaze B2", protocol: .b2, hostname: "api.backblazeb2.com", hostnameEditable: false,
              userLabel: "Key ID", passwordLabel: "Application Key", icon: .archive,
              note: "Use uma Application Key do painel da Backblaze; o endpoint da região é descoberto sozinho."),
        .init(id: "wasabi", name: "Wasabi", protocol: .s3, hostname: "s3.wasabisys.com", userLabel: "Access Key", passwordLabel: "Secret Key",
              icon: .cloud, note: "Para outras regiões: s3.<região>.wasabisys.com"),
        .init(id: "r2", name: "Cloudflare R2", protocol: .s3, hostname: "<conta>.r2.cloudflarestorage.com", userLabel: "Access Key ID",
              passwordLabel: "Secret Access Key", icon: .cloud, note: "Troque <conta> pelo Account ID da Cloudflare."),
        .init(id: "spaces", name: "DigitalOcean Spaces", protocol: .s3, hostname: "nyc3.digitaloceanspaces.com", userLabel: "Access Key",
              passwordLabel: "Secret", icon: .cloud, note: "Use a região do seu Space (nyc3, ams3, sgp1, fra1…)."),
        .init(id: "gcs", name: "Google Cloud Storage (HMAC)", protocol: .s3, hostname: "storage.googleapis.com", hostnameEditable: false,
              userLabel: "Access ID (HMAC)", passwordLabel: "Secret (HMAC)", icon: .cloud,
              note: "Crie chaves HMAC em Cloud Storage › Configurações › Interoperabilidade."),
        .init(id: "linode", name: "Akamai/Linode Object Storage", protocol: .s3, hostname: "us-east-1.linodeobjects.com",
              userLabel: "Access Key", passwordLabel: "Secret Key", icon: .cloud),
        .init(id: "scaleway", name: "Scaleway Object Storage", protocol: .s3, hostname: "s3.fr-par.scw.cloud",
              userLabel: "Access Key", passwordLabel: "Secret Key", icon: .cloud),
        .init(id: "hetzner-s3", name: "Hetzner Object Storage", protocol: .s3, hostname: "fsn1.your-objectstorage.com",
              userLabel: "Access Key", passwordLabel: "Secret Key", icon: .cloud),
        .init(id: "dreamobjects", name: "DreamObjects", protocol: .s3, hostname: "objects-us-east-1.dream.io",
              userLabel: "Access Key", passwordLabel: "Secret Key", icon: .cloud),
        .init(id: "minio", name: "MinIO / S3 local", protocol: .s3, hostname: "127.0.0.1", port: 9000,
              userLabel: "Access Key", passwordLabel: "Secret Key", plainHTTP: true, icon: .server),
        .init(id: "rackspace", name: "Rackspace Cloud Files", protocol: .swift, hostname: "identity.api.rackspacecloud.com",
              path: "", userLabel: "Usuário", passwordLabel: "API Key", icon: .cloud, note: "Autenticação Keystone v2 (/v2.0)."),
        .init(id: "nextcloud", name: "Nextcloud", protocol: .webdavs, path: "/remote.php/dav/files/{user}", icon: .cloud,
              note: "Com login em dois fatores, use uma senha de app (Configurações › Segurança)."),
        .init(id: "owncloud", name: "ownCloud", protocol: .webdavs, path: "/remote.php/dav/files/{user}", icon: .cloud),
        .init(id: "storagebox", name: "Hetzner Storage Box", protocol: .sftp, hostname: "<usuário>.your-storagebox.de", port: 23,
              icon: .archive),
    ]

    /// Lê um `.cyberduckprofile` (plist) quando o protocolo base é suportado aqui.
    public static func cyberduckProfile(_ data: Data) throws -> ConnectionPreset {
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw WormlinkError.invalidBookmark
        }
        func string(_ key: String) -> String? { (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func bool(_ key: String) -> Bool? { (dict[key] as? Bool) ?? (dict[key] as? String).map { $0 == "true" } }
        let base = string("Protocol") ?? ""
        let proto: ConnectionProtocol
        var path = string("Default Path") ?? string("Context") ?? ""
        switch base {
        case "nextcloud", "owncloud": proto = .webdavs; if path.isEmpty { path = "/remote.php/dav/files/{user}" }
        default:
            guard let known = ConnectionProtocol(rawValue: base) ?? ConnectionProtocol(scheme: base) else {
                throw WormlinkError.unsupportedProtocol(base)
            }
            proto = known
        }
        let name = string("Description") ?? string("Default Nickname") ?? base
        return ConnectionPreset(id: "cyberduck:\(string("Vendor") ?? "")-\(name)", name: name, protocol: proto,
                                hostname: string("Default Hostname") ?? "", port: string("Default Port").flatMap(Int.init), path: path,
                                hostnameEditable: bool("Hostname Configurable") ?? true,
                                userLabel: string("Username Placeholder"), passwordLabel: string("Password Placeholder"),
                                plainHTTP: string("Scheme") == "http", icon: .default(for: proto))
    }
}

/// Perfis importados pelo usuário, guardados na pasta de dados.
public enum PresetStore {
    static var file: URL { WormlinkPaths.dataDirectory.appending(path: "Profiles.json") }

    public static func imported() -> [ConnectionPreset] {
        (try? JSONDecoder().decode([ConnectionPreset].self, from: Data(contentsOf: file))) ?? []
    }

    public static func add(_ preset: ConnectionPreset) throws {
        var all = imported().filter { $0.id != preset.id }
        all.append(preset)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: file, options: .atomic)
    }

    public static var all: [ConnectionPreset] { ConnectionPreset.builtIn + imported() }
}
