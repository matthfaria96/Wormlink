import Foundation

/// Protocolos de conexão. Os valores brutos são os identificadores do Cyberduck,
/// para que favoritos `.duck` importados mantenham o protocolo.
public enum ConnectionProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case sftp
    case smb
    case ftp
    case ftps
    case webdav = "dav"
    case webdavs = "davs"
    case s3
    case b2
    case azure
    case swift
    case dropbox
    case box
    case googleDrive = "googledrive"
    case oneDrive = "onedrive"
    case sharePoint = "sharepoint"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sftp: "SFTP (SSH)"
        case .smb: "SMB (Windows, NAS)"
        case .ftp: "FTP"
        case .ftps: String(localized: "FTP com TLS/SSL")
        case .webdav: "WebDAV (HTTP)"
        case .webdavs: "WebDAV (HTTPS)"
        case .s3: "Amazon S3"
        case .b2: "Backblaze B2"
        case .azure: "Microsoft Azure"
        case .swift: "OpenStack Swift"
        case .dropbox: "Dropbox"
        case .box: "Box"
        case .googleDrive: "Google Drive"
        case .oneDrive: "Microsoft OneDrive"
        case .sharePoint: "Microsoft SharePoint"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .smb: 445
        case .ftp, .ftps: 21
        case .webdav: 80
        case .webdavs, .s3, .b2, .azure, .swift, .dropbox, .box, .googleDrive, .oneDrive, .sharePoint: 443
        }
    }

    /// Esquema usado em URLs (`sftp://usuario@servidor/caminho`).
    public var scheme: String {
        switch self {
        case .webdav: "http"
        case .webdavs: "https"
        default: rawValue
        }
    }

    public var symbolName: String {
        switch self {
        case .sftp: "lock.shield"
        case .smb: "externaldrive.connected.to.line.below"
        case .ftp, .ftps: "server.rack"
        case .webdav, .webdavs: "globe"
        case .s3: "cloud"
        case .b2: "flame"
        case .azure: "cloud.circle"
        case .swift: "bird"
        case .dropbox: "shippingbox"
        case .box: "square.stack.3d.up"
        case .googleDrive: "triangle"
        case .oneDrive: "cloud.fill"
        case .sharePoint: "building.2"
        }
    }

    /// Nuvens com login OAuth no navegador (sem endereço, porta nem senha).
    public var isOAuth: Bool { oauthProvider != nil }

    public var oauthProvider: OAuthProvider? {
        switch self {
        case .dropbox: .dropbox
        case .box: .box
        case .googleDrive: .googleDrive
        case .oneDrive: .oneDrive
        case .sharePoint: .sharePoint
        default: nil
        }
    }

    /// Servidor da API, usado como "endereço" do favorito e no Chaves.
    public var fixedHost: String? {
        switch self {
        case .b2: "api.backblazeb2.com"
        case .dropbox: "api.dropboxapi.com"
        case .box: "api.box.com"
        case .googleDrive: "www.googleapis.com"
        case .oneDrive: "graph.microsoft.com"
        default: nil
        }
    }

    /// Protocolos com implementação pronta nesta versão.
    public var isAvailable: Bool { true }

    public init?(scheme: String) {
        switch scheme.lowercased() {
        case "sftp", "ssh", "scp": self = .sftp
        case "smb", "cifs": self = .smb
        case "ftp": self = .ftp
        case "ftps", "ftp+tls", "ftpes": self = .ftps
        case "http", "dav", "webdav": self = .webdav
        case "https", "davs", "webdavs": self = .webdavs
        case "s3": self = .s3
        case "b2": self = .b2
        case "azure": self = .azure
        case "swift", "cf": self = .swift
        case "dropbox": self = .dropbox
        case "box": self = .box
        case "googledrive", "gdrive": self = .googleDrive
        case "onedrive": self = .oneDrive
        case "sharepoint": self = .sharePoint
        default: return nil
        }
    }

    /// Protocolo do item de senha no Chaves (mesmo esquema usado pelo Cyberduck).
    var keychainProtocol: CFString {
        switch self {
        case .sftp: kSecAttrProtocolSSH
        case .smb: kSecAttrProtocolSMB
        case .ftp: kSecAttrProtocolFTP
        case .ftps: kSecAttrProtocolFTPS
        case .webdav: kSecAttrProtocolHTTP
        case .webdavs, .s3, .b2, .azure, .swift, .dropbox, .box, .googleDrive, .oneDrive, .sharePoint: kSecAttrProtocolHTTPS
        }
    }
}
