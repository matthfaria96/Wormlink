import Foundation

/// Importar servidores de outros apps (o Cyberduck tem ~25 importadores; aqui os que existem no Mac
/// ou são comuns em arquivos trazidos do Windows) e exportar/restaurar a lista do Wormlink.
public enum ServerImporter: String, CaseIterable, Identifiable, Sendable {
    case cyberduck, transmit, filezilla, winscp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cyberduck: "Cyberduck"
        case .transmit: "Transmit"
        case .filezilla: "FileZilla"
        case .winscp: String(localized: "WinSCP (arquivo .ini)")
        }
    }

    /// Onde cada app guarda os servidores neste Mac (nil = o usuário escolhe o arquivo).
    public var defaultLocation: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .cyberduck: return Bookmark.cyberduckBookmarksFolder
        case .transmit: return home.appending(path: "Library/Application Support/Transmit/Metadata")
        case .filezilla: return home.appending(path: ".config/filezilla/sitemanager.xml")
        case .winscp: return nil
        }
    }

    public var isAvailable: Bool { defaultLocation.map { FileManager.default.fileExists(atPath: $0.path) } ?? true }

    /// Servidores encontrados, com a senha quando o formato a guarda (FileZilla) — vai para o Chaves, não para o arquivo.
    public func read(_ location: URL? = nil) throws -> [(bookmark: Bookmark, password: String?)] {
        guard let url = location ?? defaultLocation else { return [] }
        switch self {
        case .cyberduck: return Bookmark.importCyberduckBookmarks(from: url).map { ($0, nil) }
        case .transmit: return try Self.transmit(url)
        case .filezilla: return try Self.fileZilla(Data(contentsOf: url))
        case .winscp: return Self.winSCP(try String(contentsOf: url, encoding: .utf8))
        }
    }

    // MARK: Transmit

    static func transmit(_ folder: URL) throws -> [(bookmark: Bookmark, password: String?)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "favoriteMetadata" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return transmit(dict).map { ($0, nil) }
        }
    }

    static func transmit(_ dict: [String: Any]) -> Bookmark? {
        func value(_ key: String) -> Any? { dict["com_panic_transmit_" + key] }
        guard let host = value("server") as? String, !host.isEmpty else { return nil }
        let name = (value("protocol") as? String ?? "").lowercased()
        let proto: ConnectionProtocol = name.contains("sftp") ? .sftp
            : name.contains("implicit") || name.contains("tls") || name.contains("ssl") && name.contains("ftp") ? .ftps
            : name.contains("webdav") ? (name.contains("https") ? .webdavs : .webdav)
            : name.contains("s3") ? .s3 : name.contains("azure") ? .azure : name.contains("b2") ? .b2
            : name.contains("dropbox") ? .dropbox : name.contains("google") ? .googleDrive : name.contains("onedrive") ? .oneDrive
            : name.contains("box") ? .box : name.contains("swift") || name.contains("cloud files") ? .swift
            : name.contains("smb") ? .smb : .ftp
        var bookmark = Bookmark(id: (value("uniqueIdentifier") as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                                nickname: value("nickname") as? String ?? "", connectionProtocol: proto, hostname: host,
                                port: (value("port") as? NSNumber)?.intValue, username: value("username") as? String ?? value("user") as? String ?? "",
                                path: value("remotePath") as? String ?? value("initialRemotePath") as? String ?? "",
                                localPath: value("localPath") as? String)
        bookmark.icon = .default(for: proto)
        return bookmark
    }

    // MARK: FileZilla

    static func fileZilla(_ data: Data) throws -> [(bookmark: Bookmark, password: String?)] {
        let parser = XMLParser(data: data)
        let delegate = FileZillaParser()
        parser.delegate = delegate
        guard parser.parse() else { throw WormlinkError.invalidBookmark }
        return delegate.servers
    }

    /// Caminho remoto do FileZilla: "1 0 3 www 7 projeto" (tipo, prefixo, depois tamanho+nome de cada parte).
    static func fileZillaPath(_ encoded: String) -> String {
        var tokens = encoded.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 2 else { return encoded.hasPrefix("/") ? encoded : "" }
        tokens.removeFirst(2)
        var parts: [String] = []
        var rest = tokens.joined(separator: " ")[...]
        while let space = rest.firstIndex(of: " "), let length = Int(rest[..<space]) {
            let start = rest.index(after: space)
            let end = rest.index(start, offsetBy: length, limitedBy: rest.endIndex) ?? rest.endIndex
            parts.append(String(rest[start..<end]))
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
        }
        return parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    private final class FileZillaParser: NSObject, XMLParserDelegate {
        var servers: [(bookmark: Bookmark, password: String?)] = []
        private var current: [String: String]?
        private var text = ""
        private var folders: [String] = []
        private var passwordBase64 = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            // O nome da pasta é o texto do <Folder> antes do primeiro elemento filho.
            let pending = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if current == nil, !folders.isEmpty, folders.last == "", !pending.isEmpty { folders[folders.count - 1] = pending }
            text = ""
            if name == "Server" { current = [:] }
            if name == "Folder" { folders.append("") }
            if name == "Pass" { passwordBase64 = attributes["encoding"] == "base64" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            if name == "Folder" { _ = folders.popLast(); return }
            guard var server = current else { return }
            if name == "Server" {
                current = nil
                guard let host = server["Host"], !host.isEmpty else { return }
                let proto: ConnectionProtocol = switch server["Protocol"] ?? "0" {
                case "1": .sftp
                case "3", "4": .ftps
                default: .ftp
                }
                var bookmark = Bookmark(nickname: server["Name"] ?? "", connectionProtocol: proto, hostname: host,
                                        port: server["Port"].flatMap(Int.init), username: server["User"] ?? "",
                                        path: server["RemoteDir"].map(ServerImporter.fileZillaPath) ?? "",
                                        localPath: server["LocalDir"].flatMap { $0.isEmpty ? nil : $0 })
                if server["Protocol"] == "3" { bookmark.port = server["Port"].flatMap(Int.init) ?? 990 }
                bookmark.group = folders.last { !$0.isEmpty }
                bookmark.icon = .default(for: proto)
                var password = server["Pass"]
                if passwordBase64, let encoded = password { password = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } }
                servers.append((bookmark, password))
            } else {
                server[name] = value
                current = server
            }
        }
    }

    // MARK: WinSCP

    static func winSCP(_ text: String) -> [(bookmark: Bookmark, password: String?)] {
        var result: [(bookmark: Bookmark, password: String?)] = []
        var name: String?
        var fields: [String: String] = [:]
        func flush() {
            defer { name = nil; fields = [:] }
            guard let name, let host = fields["HostName"], !host.isEmpty else { return }
            // FSProtocol: 0 SCP, 1/2 SFTP, 5 FTP, 6 WebDAV, 7 S3. Ftps: 1 implícito, 2/3 explícito.
            var proto: ConnectionProtocol = switch fields["FSProtocol"] ?? "2" {
            case "5": .ftp
            case "6": fields["Ftps"] == nil || fields["Ftps"] == "0" ? .webdav : .webdavs
            case "7": .s3
            default: .sftp
            }
            if proto == .ftp, let ftps = fields["Ftps"], ftps != "0" { proto = .ftps }
            let decodedName = (name.removingPercentEncoding ?? name).split(separator: "/").map(String.init)
            var bookmark = Bookmark(nickname: decodedName.last ?? name, connectionProtocol: proto, hostname: host,
                                    port: fields["PortNumber"].flatMap(Int.init), username: fields["UserName"] ?? "",
                                    path: fields["RemoteDirectory"]?.removingPercentEncoding ?? "",
                                    localPath: fields["LocalDirectory"]?.removingPercentEncoding)
            if decodedName.count > 1 { bookmark.group = decodedName.dropLast().joined(separator: "/") }
            bookmark.icon = .default(for: proto)
            result.append((bookmark, nil))   // senhas do WinSCP são ofuscadas por chave mestra: não são lidas
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                if line.hasPrefix("[Sessions\\"), line.hasSuffix("]") { name = String(line.dropFirst(10).dropLast()) }
            } else if name != nil, let eq = line.firstIndex(of: "=") {
                fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        flush()
        return result
    }
}

/// Exportação/backup dos servidores do Wormlink (.wormlinkservers, JSON). Senhas só se o usuário pedir.
public struct ServerBackup: Codable, Sendable {
    public var version = 1
    public var exported = Date()
    public var bookmarks: [Bookmark]
    public var passwords: [String: String]?

    public init(bookmarks: [Bookmark], includePasswords: Bool) {
        self.bookmarks = bookmarks
        if includePasswords {
            var map: [String: String] = [:]
            for b in bookmarks { if let p = Keychain.password(for: b) { map[b.id.uuidString] = p } }
            passwords = map
        }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
        // Com senhas, só o dono lê o arquivo.
        if passwords != nil { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    public static func read(_ url: URL) throws -> ServerBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ServerBackup.self, from: Data(contentsOf: url))
    }
}
