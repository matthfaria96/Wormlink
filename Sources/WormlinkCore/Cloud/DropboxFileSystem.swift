import Foundation

/// Dropbox (API v2). Caminhos do Wormlink ("/Fotos/a.jpg") são os mesmos do Dropbox; a raiz é "".
public final class DropboxFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    let session: CloudSession
    static let api = URL(string: "https://api.dropboxapi.com/2/")!
    static let content = URL(string: "https://content.dropboxapi.com/2/")!
    static let singleUploadLimit: Int64 = 150 * 1024 * 1024
    static let chunk = 8 * 1024 * 1024

    init(bookmark: Bookmark, session: CloudSession) {
        title = bookmark.displayName
        homePath = RemotePath.normalize(bookmark.path)
        self.session = session
    }

    static func dropboxPath(_ path: String) -> String {
        let p = RemotePath.normalize(path)
        return p == "/" ? "" : p
    }

    private func rpc(_ endpoint: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.api.appending(path: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.send(request, body: try JSONSerialization.data(withJSONObject: body))
        return try cloudJSON(data, response)
    }

    /// O cabeçalho Dropbox-API-Arg precisa de JSON só com ASCII (o resto vira \uXXXX).
    static func apiArg(_ object: [String: Any]) -> String {
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        return json.unicodeScalars.map { $0.isASCII ? String($0) : $0.utf16.map { String(format: "\\u%04x", $0) }.joined() }.joined()
    }

    static func item(_ entry: [String: Any]) -> FileItem? {
        guard let tag = entry[".tag"] as? String, tag != "deleted", let path = entry["path_display"] as? String else { return nil }
        let isDir = tag == "folder"
        return FileItem(path: RemotePath.normalize(path), isDirectory: isDir,
                        size: isDir ? nil : (entry["size"] as? NSNumber)?.int64Value,
                        modified: parseISODate(entry["client_modified"] as? String ?? entry["server_modified"] as? String))
    }

    public func list(_ path: String) async throws -> [FileItem] {
        var json = try await rpc("files/list_folder", ["path": Self.dropboxPath(path), "limit": 2000])
        var items = (json["entries"] as? [[String: Any]] ?? []).compactMap(Self.item)
        while json["has_more"] as? Bool == true, let cursor = json["cursor"] as? String {
            json = try await rpc("files/list_folder/continue", ["cursor": cursor])
            items += (json["entries"] as? [[String: Any]] ?? []).compactMap(Self.item)
        }
        return items
    }

    public func createDirectory(_ path: String) async throws {
        _ = try await rpc("files/create_folder_v2", ["path": Self.dropboxPath(path)])
    }

    public func delete(_ item: FileItem) async throws {
        _ = try await rpc("files/delete_v2", ["path": Self.dropboxPath(item.path)])
    }

    public func move(_ path: String, to newPath: String) async throws {
        _ = try await rpc("files/move_v2", ["from_path": Self.dropboxPath(path), "to_path": Self.dropboxPath(newPath)])
    }

    public var canResumeDownloads: Bool { true }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var request = URLRequest(url: Self.content.appending(path: "files/download"))
        request.httpMethod = "POST"
        request.setValue(Self.apiArg(["path": Self.dropboxPath(path)]), forHTTPHeaderField: "Dropbox-API-Arg")
        try await session.download(request, to: local, offset: offset, progress: progress)
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let values = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        var commit: [String: Any] = ["path": Self.dropboxPath(path), "mode": "overwrite", "mute": true]
        // A data original vai junto (client_modified), o que deixa a sincronização estável.
        if let date = values.contentModificationDate {
            commit["client_modified"] = date.formatted(.iso8601)   // "2026-10-16T21:50:38Z"
        }
        if size <= Self.singleUploadLimit {
            var request = URLRequest(url: Self.content.appending(path: "files/upload"))
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.apiArg(commit), forHTTPHeaderField: "Dropbox-API-Arg")
            let (data, response) = try await session.send(request, file: local, delegate: CloudUploadProgress(progress))
            _ = try cloudJSON(data, response)
            return
        }
        // Sessão de envio em partes de 8 MB.
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        var sessionID: String?
        var offset: Int64 = 0
        while let chunk = try reader.read(upToCount: Self.chunk), !chunk.isEmpty {
            try Task.checkCancellation()
            var request = URLRequest(url: Self.content.appending(path: sessionID == nil ? "files/upload_session/start" : "files/upload_session/append_v2"))
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let arg: [String: Any] = sessionID.map { ["cursor": ["session_id": $0, "offset": offset], "close": false] } ?? ["close": false]
            request.setValue(Self.apiArg(arg), forHTTPHeaderField: "Dropbox-API-Arg")
            let (data, response) = try await session.send(request, body: chunk)
            let json = try cloudJSON(data, response)
            if sessionID == nil { sessionID = json["session_id"] as? String }
            offset += Int64(chunk.count)
            progress(offset)
        }
        guard let sessionID else { throw WormlinkError.invalidResponse }
        var finish = URLRequest(url: Self.content.appending(path: "files/upload_session/finish"))
        finish.httpMethod = "POST"
        finish.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        finish.setValue(Self.apiArg(["cursor": ["session_id": sessionID, "offset": offset], "commit": commit]), forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await session.send(finish, body: Data())
        _ = try cloudJSON(data, response)
    }

    public var uploadsAreAtomic: Bool { true }

    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        let json = try await rpc("files/get_metadata", ["path": Self.dropboxPath(path)])
        return (json["content_hash"] as? String).map { Checksum(.dropbox, $0) }
    }

    public func disconnect() async {}

    /// Nome e e-mail da conta, para o rótulo do favorito.
    func accountEmail() async -> String? {
        try? await rpc("users/get_current_account", [:])["email"] as? String
    }
}
