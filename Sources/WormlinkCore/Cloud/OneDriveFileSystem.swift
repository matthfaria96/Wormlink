import Foundation

/// OneDrive e OneDrive for Business (Microsoft Graph), endereçando itens pelo caminho.
public final class OneDriveFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    let session: CloudSession
    /// Unidade do Graph: "…/me/drive" (OneDrive) ou "…/drives/<id>" (biblioteca de um site do SharePoint).
    let drive: String
    static let personalDrive = "https://graph.microsoft.com/v1.0/me/drive"
    static let simpleUploadLimit: Int64 = 4 * 1024 * 1024
    static let chunk = 320 * 1024 * 32   // múltiplo de 320 KiB, exigido pelo Graph

    init(bookmark: Bookmark, session: CloudSession, drive: String = OneDriveFileSystem.personalDrive, home: String? = nil) {
        title = bookmark.displayName
        homePath = RemotePath.normalize(home ?? bookmark.path)
        self.session = session
        self.drive = drive
    }

    /// SharePoint: o favorito guarda o site ("contoso.sharepoint.com" + "/sites/Equipe"); a biblioteca padrão
    /// do site vira a raiz.
    static func sharePoint(bookmark: Bookmark, session: CloudSession) async throws -> OneDriveFileSystem {
        let site = RemotePath.normalize(bookmark.path)
        let siteURL = URL(string: "https://graph.microsoft.com/v1.0/sites/\(bookmark.hostname):\(site == "/" ? "" : site)")!
        let (data, response) = try await session.send(URLRequest(url: siteURL))
        guard let siteID = try cloudJSON(data, response)["id"] as? String else { throw WormlinkError.invalidResponse }
        let (driveData, driveResponse) = try await session.send(URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/sites/\(siteID)/drive")!))
        guard let driveID = try cloudJSON(driveData, driveResponse)["id"] as? String else { throw WormlinkError.invalidResponse }
        return OneDriveFileSystem(bookmark: bookmark, session: session, drive: "https://graph.microsoft.com/v1.0/drives/\(driveID)", home: "/")
    }

    /// `/root` ou `/root:/a/b:` (cada parte codificada).
    func itemURL(_ path: String, suffix: String = "") -> URL { Self.itemURL(path, suffix: suffix, drive: drive) }

    static func itemURL(_ path: String, suffix: String = "", drive: String = personalDrive) -> URL {
        let p = RemotePath.normalize(path)
        if p == "/" { return URL(string: drive + "/root" + (suffix.isEmpty ? "" : "/" + suffix))! }
        let encoded = p.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":#?"))) ?? String($0) }
            .joined(separator: "/")
        return URL(string: drive + "/root:/" + encoded + ":" + (suffix.isEmpty ? "" : "/" + suffix))!
    }

    private func call(_ method: String, _ url: URL, _ body: [String: Any]? = nil, expect: Set<Int> = [200, 201, 204]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.send(request, body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        return try cloudJSON(data, response, expect: expect)
    }

    static func item(_ entry: [String: Any], in dir: String) -> FileItem? {
        guard let name = entry["name"] as? String else { return nil }
        let isDir = entry["folder"] != nil
        let info = entry["fileSystemInfo"] as? [String: Any]
        return FileItem(path: RemotePath.join(dir, name), isDirectory: isDir,
                        size: isDir ? nil : (entry["size"] as? NSNumber)?.int64Value,
                        modified: parseISODate(info?["lastModifiedDateTime"] as? String ?? entry["lastModifiedDateTime"] as? String))
    }

    public func list(_ path: String) async throws -> [FileItem] {
        let dir = RemotePath.normalize(path)
        var next: URL? = URL(string: itemURL(dir, suffix: "children").absoluteString + "?$top=1000")
        var items: [FileItem] = []
        while let url = next {
            let json = try await call("GET", url)
            items += (json["value"] as? [[String: Any]] ?? []).compactMap { Self.item($0, in: dir) }
            next = (json["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return items
    }

    public func createDirectory(_ path: String) async throws {
        _ = try await call("POST", itemURL(RemotePath.parent(path), suffix: "children"),
                           ["name": RemotePath.name(path), "folder": [String: Any](), "@microsoft.graph.conflictBehavior": "fail"])
    }

    public func delete(_ item: FileItem) async throws {
        _ = try await call("DELETE", itemURL(item.path))
    }

    public func move(_ path: String, to newPath: String) async throws {
        let parent = RemotePath.normalize(RemotePath.parent(newPath))
        _ = try await call("PATCH", itemURL(path),
                           ["name": RemotePath.name(newPath), "parentReference": ["path": parent == "/" ? "/drive/root:" : "/drive/root:" + parent]])
    }

    public var canResumeDownloads: Bool { true }
    public var supportsModificationDates: Bool { true }

    public func setModificationDate(_ path: String, _ date: Date) async throws {
        _ = try await call("PATCH", itemURL(path), ["fileSystemInfo": ["lastModifiedDateTime": date.formatted(.iso8601)]])
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await session.download(URLRequest(url: itemURL(path, suffix: "content")), to: local, offset: offset, progress: progress)
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size <= Self.simpleUploadLimit {
            var request = URLRequest(url: itemURL(path, suffix: "content"))
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.send(request, file: local, delegate: CloudUploadProgress(progress))
            _ = try cloudJSON(data, response)
            return
        }
        // Sessão de envio: blocos enviados direto à URL da sessão (sem token).
        let created = try await call("POST", itemURL(path, suffix: "createUploadSession"),
                                     ["item": ["@microsoft.graph.conflictBehavior": "replace"]])
        guard let uploadURL = (created["uploadUrl"] as? String).flatMap(URL.init(string:)) else { throw WormlinkError.invalidResponse }
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        var offset: Int64 = 0
        while let chunk = try reader.read(upToCount: Self.chunk), !chunk.isEmpty {
            try Task.checkCancellation()
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            let (data, response) = try await session.urlSession.upload(for: request, from: chunk)
            _ = try cloudJSON(data, response as! HTTPURLResponse, expect: [200, 201, 202])
            offset += Int64(chunk.count)
            progress(offset)
        }
    }

    public var uploadsAreAtomic: Bool { true }

    public func disconnect() async {}

    func accountEmail() async -> String? {
        guard let json = try? await call("GET", URL(string: "https://graph.microsoft.com/v1.0/me")!) else { return nil }
        return json["mail"] as? String ?? json["userPrincipalName"] as? String
    }
}
