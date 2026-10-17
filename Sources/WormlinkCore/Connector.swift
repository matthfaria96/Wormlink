import Foundation

/// Abre a sessão do protocolo certo para um favorito.
public enum Connector {
    public static func connect(_ bookmark: Bookmark, password: String?, trust: ConnectionTrust) async throws -> any FileSystem {
        switch bookmark.connectionProtocol {
        case .sftp:
            return try await SFTPFileSystem.connect(bookmark, password: password, trust: trust)
        case .ftp, .ftps:
            return try await FTPFileSystem.connect(bookmark, password: password, certificateTrust: trust.certificate)
        case .s3:
            let fs = try await S3FileSystem.connect(bookmark, secret: password ?? "", trust: trust)
            _ = try await fs.list(fs.homePath)
            return fs
        case .smb:
            let fs = try await SMBFileSystem.connect(bookmark, password: password)
            _ = try await fs.list(fs.homePath)
            return fs
        case .swift:
            let fs = try await SwiftFileSystem.connect(bookmark, password: password ?? "")
            _ = try await fs.list(fs.homePath)
            return fs
        case .azure:
            let fs = try AzureFileSystem(bookmark: bookmark, secret: password ?? "")
            _ = try await fs.list(fs.homePath)
            return fs
        case .b2:
            let fs = try await B2.connect(bookmark, applicationKey: password ?? "", trust: trust)
            _ = try await fs.list(fs.homePath)
            return fs
        case .dropbox, .box, .googleDrive, .oneDrive, .sharePoint:
            return try await connectCloud(bookmark, secret: password, trust: trust)
        case .webdav, .webdavs:
            let fs = try WebDAVFileSystem(bookmark: bookmark, password: password, certificateTrust: trust.certificate)
            _ = try await fs.list(fs.homePath)   // valida endereço e credenciais já na conexão
            return fs
        }
    }

    /// Nuvens: usa os tokens do Chaves; sem eles (ou com acesso revogado), faz o login no navegador.
    static func connectCloud(_ bookmark: Bookmark, secret: String?, trust: ConnectionTrust) async throws -> any FileSystem {
        guard let provider = bookmark.connectionProtocol.oauthProvider else { throw WormlinkError.invalidBookmark }
        func open(_ tokens: OAuthTokens) async throws -> any FileSystem {
            let session = CloudSession(provider: provider, tokens: tokens, bookmark: bookmark)
            let fs: any FileSystem
            switch bookmark.connectionProtocol {
            case .dropbox: fs = DropboxFileSystem(bookmark: bookmark, session: session)
            case .box: fs = BoxFileSystem(bookmark: bookmark, session: session)
            case .googleDrive: fs = GoogleDriveFileSystem(bookmark: bookmark, session: session)
            case .sharePoint: fs = try await OneDriveFileSystem.sharePoint(bookmark: bookmark, session: session)
            default: fs = OneDriveFileSystem(bookmark: bookmark, session: session)
            }
            _ = try await fs.list(fs.homePath)
            return fs
        }
        if let saved = OAuthTokens.decode(secret) {
            do { return try await open(saved) } catch WormlinkError.authenticationFailed { /* login de novo */ }
        }
        let tokens = try await OAuthFlow.authorize(provider, open: trust.openBrowser)
        Keychain.setPassword(tokens.encoded, for: bookmark)
        return try await open(tokens)
    }
}
