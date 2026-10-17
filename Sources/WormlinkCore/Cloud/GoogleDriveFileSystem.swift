import Foundation

/// Google Drive (API v3). O Drive identifica arquivos por ID; os caminhos são resolvidos e guardados em cache.
public final class GoogleDriveFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    let session: CloudSession
    private let ids = IDCache()
    static let api = URL(string: "https://www.googleapis.com/drive/v3/")!
    static let upload = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    static let folderType = "application/vnd.google-apps.folder"
    static let fields = "id,name,mimeType,size,modifiedTime"

    init(bookmark: Bookmark, session: CloudSession) {
        title = bookmark.displayName
        homePath = RemotePath.normalize(bookmark.path)
        self.session = session
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var c = URLComponents(url: Self.api.appending(path: path), resolvingAgainstBaseURL: false)!
        c.setQuery(query.map { URLQueryItem(name: $0.key, value: $0.value) })
        let (data, response) = try await session.send(URLRequest(url: c.url!))
        return try cloudJSON(data, response)
    }

    private func json(_ method: String, _ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.send(request, body: try JSONSerialization.data(withJSONObject: body))
        return try cloudJSON(data, response, expect: [200, 201, 204])
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// ID do item no caminho (a raiz é "root").
    func id(for path: String) async throws -> String {
        let p = RemotePath.normalize(path)
        if p == "/" { return "root" }
        if let cached = await ids.get(p) { return cached }
        let parent = try await id(for: RemotePath.parent(p))
        let query = "name = \(Self.quoted(RemotePath.name(p))) and \(Self.quoted(parent)) in parents and trashed = false"
        let json = try await get("files", ["q": query, "fields": "files(\(Self.fields))", "pageSize": "10"])
        guard let file = (json["files"] as? [[String: Any]])?.first, let id = file["id"] as? String else { throw WormlinkError.notFound(p) }
        await ids.set(p, id)
        return id
    }

    static func item(_ file: [String: Any], in dir: String) -> FileItem? {
        guard let name = file["name"] as? String else { return nil }
        let isDir = file["mimeType"] as? String == folderType
        return FileItem(path: RemotePath.join(dir, name.replacingOccurrences(of: "/", with: "∕")), isDirectory: isDir,
                        size: isDir ? nil : (file["size"] as? String).flatMap(Int64.init),
                        modified: parseISODate(file["modifiedTime"] as? String))
    }

    public func list(_ path: String) async throws -> [FileItem] {
        let dir = RemotePath.normalize(path)
        let folder = try await id(for: dir)
        var items: [FileItem] = []
        var token: String?
        repeat {
            var query = ["q": "\(Self.quoted(folder)) in parents and trashed = false", "pageSize": "1000",
                         "fields": "nextPageToken,files(\(Self.fields))"]
            if let token { query["pageToken"] = token }
            let json = try await get("files", query)
            for file in json["files"] as? [[String: Any]] ?? [] {
                guard let item = Self.item(file, in: dir), let id = file["id"] as? String else { continue }
                await ids.set(item.path, id)
                items.append(item)
            }
            token = json["nextPageToken"] as? String
        } while token != nil
        return items
    }

    public func createDirectory(_ path: String) async throws {
        let parent = try await id(for: RemotePath.parent(path))
        let created = try await json("POST", Self.api.appending(path: "files"),
                                     ["name": RemotePath.name(path), "mimeType": Self.folderType, "parents": [parent]])
        if let id = created["id"] as? String { await ids.set(RemotePath.normalize(path), id) }
    }

    /// Vai para a Lixeira do Drive (recuperável), como o Cyberduck.
    public func delete(_ item: FileItem) async throws {
        let id = try await id(for: item.path)
        _ = try await json("PATCH", Self.api.appending(path: "files/\(id)"), ["trashed": true])
        await ids.remove(prefix: item.path)
    }

    public func move(_ path: String, to newPath: String) async throws {
        let id = try await id(for: path)
        let oldParent = try await self.id(for: RemotePath.parent(path))
        let newParent = try await self.id(for: RemotePath.parent(newPath))
        var c = URLComponents(url: Self.api.appending(path: "files/\(id)"), resolvingAgainstBaseURL: false)!
        if oldParent != newParent { c.queryItems = [.init(name: "addParents", value: newParent), .init(name: "removeParents", value: oldParent)] }
        _ = try await json("PATCH", c.url!, ["name": RemotePath.name(newPath)])
        await ids.remove(prefix: path)
    }

    public var canResumeDownloads: Bool { true }
    public var supportsModificationDates: Bool { true }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        let id = try await id(for: path)
        _ = try await json("PATCH", Self.api.appending(path: "files/\(id)"), ["modifiedTime": date.formatted(.iso8601)])
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let id = try await id(for: path)
        var c = URLComponents(url: Self.api.appending(path: "files/\(id)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "alt", value: "media")]
        do {
            try await session.download(URLRequest(url: c.url!), to: local, offset: offset, progress: progress)
        } catch WormlinkError.server(let status, _) where status == 403 {
            throw WormlinkError.unsupportedOperation(String(localized: "Baixar documentos do Google (Docs, Planilhas, Apresentações)"))
        }
    }

    /// Envio retomável do Google (uma sessão por arquivo): cria ou substitui.
    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let existing = try? await id(for: path)
        let parent = try await id(for: RemotePath.parent(path))
        let modified = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
        var metadata: [String: Any] = ["modifiedTime": modified.formatted(.iso8601)]
        var c: URLComponents
        if let existing {
            c = URLComponents(url: Self.upload.appending(path: existing), resolvingAgainstBaseURL: false)!
        } else {
            c = URLComponents(url: Self.upload, resolvingAgainstBaseURL: false)!
            metadata["name"] = RemotePath.name(path)
            metadata["parents"] = [parent]
        }
        c.queryItems = [.init(name: "uploadType", value: "resumable"), .init(name: "fields", value: "id")]
        var start = URLRequest(url: c.url!)
        start.httpMethod = existing == nil ? "POST" : "PATCH"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.send(start, body: try JSONSerialization.data(withJSONObject: metadata))
        _ = try cloudJSON(data, response)
        guard let location = response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)) else {
            throw WormlinkError.invalidResponse
        }
        var put = URLRequest(url: location)
        put.httpMethod = "PUT"
        let (body, done) = try await session.send(put, file: local, delegate: CloudUploadProgress(progress))
        let json = try cloudJSON(body, done)
        if let id = json["id"] as? String { await ids.set(RemotePath.normalize(path), id) }
    }

    public var uploadsAreAtomic: Bool { true }

    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        let id = try await id(for: path)
        return (try await get("files/\(id)", ["fields": "md5Checksum"])["md5Checksum"] as? String).map { Checksum(.md5, $0) }
    }

    public func disconnect() async {}

    func accountEmail() async -> String? {
        ((try? await get("about", ["fields": "user"]))?["user"] as? [String: Any])?["emailAddress"] as? String
    }
}

/// Cache caminho → ID do Google Drive.
actor IDCache {
    private var map: [String: String] = [:]
    func get(_ path: String) -> String? { map[path] }
    func set(_ path: String, _ id: String) { map[path] = id }
    func remove(prefix: String) {
        let p = RemotePath.normalize(prefix)
        map = map.filter { $0.key != p && !$0.key.hasPrefix(p + "/") }
    }
}
