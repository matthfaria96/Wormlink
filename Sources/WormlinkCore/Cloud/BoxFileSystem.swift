import CryptoKit
import Foundation

/// Box (API v2). Itens são identificados por ID (a raiz é "0"); os caminhos são resolvidos com cache.
public final class BoxFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    let session: CloudSession
    private let ids = IDCache()
    static let api = URL(string: "https://api.box.com/2.0/")!
    static let upload = URL(string: "https://upload.box.com/api/2.0/")!
    static let simpleUploadLimit: Int64 = 50 * 1024 * 1024
    static let fields = "name,size,modified_at,type,sha1"

    init(bookmark: Bookmark, session: CloudSession) {
        title = bookmark.displayName
        homePath = RemotePath.normalize(bookmark.path)
        self.session = session
    }

    private func call(_ method: String, _ url: URL, json: [String: Any]? = nil, expect: Set<Int> = [200, 201, 204]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if json != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.send(request, body: try json.map { try JSONSerialization.data(withJSONObject: $0) })
        return try cloudJSON(data, response, expect: expect)
    }

    static func item(_ entry: [String: Any], in dir: String) -> (FileItem, String)? {
        guard let name = entry["name"] as? String, let id = entry["id"] as? String else { return nil }
        let isDir = entry["type"] as? String == "folder"
        let size = (entry["size"] as? NSNumber)?.int64Value
        return (FileItem(path: RemotePath.join(dir, name.replacingOccurrences(of: "/", with: "∕")), isDirectory: isDir,
                         size: isDir ? nil : size, modified: parseISODate(entry["modified_at"] as? String)), id)
    }

    /// ID e tipo do item no caminho.
    func entry(for path: String) async throws -> (id: String, isFolder: Bool) {
        let p = RemotePath.normalize(path)
        if p == "/" { return ("0", true) }
        if let cached = await ids.get(p) { return (cached.hasPrefix("f:") ? String(cached.dropFirst(2)) : cached, cached.hasPrefix("f:")) }
        _ = try await list(RemotePath.parent(p))
        guard let cached = await ids.get(p) else { throw WormlinkError.notFound(p) }
        return (cached.hasPrefix("f:") ? String(cached.dropFirst(2)) : cached, cached.hasPrefix("f:"))
    }

    public func list(_ path: String) async throws -> [FileItem] {
        let dir = RemotePath.normalize(path)
        let folder = try await entry(for: dir)
        var items: [FileItem] = []
        var offset = 0
        while true {
            var c = URLComponents(url: Self.api.appending(path: "folders/\(folder.id)/items"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "fields", value: Self.fields), .init(name: "limit", value: "1000"), .init(name: "offset", value: "\(offset)")]
            let json = try await call("GET", c.url!)
            let entries = json["entries"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let (item, id) = Self.item(entry, in: dir) else { continue }
                await ids.set(item.path, item.isDirectory ? "f:" + id : id)
                items.append(item)
            }
            offset += entries.count
            let total = (json["total_count"] as? NSNumber)?.intValue ?? offset
            if entries.isEmpty || offset >= total { break }
        }
        return items
    }

    public func createDirectory(_ path: String) async throws {
        let parent = try await entry(for: RemotePath.parent(path))
        let created = try await call("POST", Self.api.appending(path: "folders"),
                                     json: ["name": RemotePath.name(path), "parent": ["id": parent.id]])
        if let id = created["id"] as? String { await ids.set(RemotePath.normalize(path), "f:" + id) }
    }

    /// Vai para a Lixeira do Box (recuperável).
    public func delete(_ item: FileItem) async throws {
        let target = try await entry(for: item.path)
        var c = URLComponents(url: Self.api.appending(path: target.isFolder ? "folders/\(target.id)" : "files/\(target.id)"),
                              resolvingAgainstBaseURL: false)!
        if target.isFolder { c.queryItems = [.init(name: "recursive", value: "true")] }
        _ = try await call("DELETE", c.url!)
        await ids.remove(prefix: item.path)
    }

    public func move(_ path: String, to newPath: String) async throws {
        let target = try await entry(for: path)
        let parent = try await entry(for: RemotePath.parent(newPath))
        _ = try await call("PUT", Self.api.appending(path: target.isFolder ? "folders/\(target.id)" : "files/\(target.id)"),
                           json: ["name": RemotePath.name(newPath), "parent": ["id": parent.id]])
        await ids.remove(prefix: path)
    }

    public var canResumeDownloads: Bool { true }
    public var uploadsAreAtomic: Bool { true }

    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        let target = try await entry(for: path)
        var c = URLComponents(url: Self.api.appending(path: "files/\(target.id)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "fields", value: "sha1")]
        return (try await call("GET", c.url!)["sha1"] as? String).map { Checksum(.sha1, $0) }
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let target = try await entry(for: path)
        try await session.download(URLRequest(url: Self.api.appending(path: "files/\(target.id)/content")), to: local, offset: offset, progress: progress)
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let parent = try await entry(for: RemotePath.parent(path))
        let existing = try? await entry(for: path)
        if size <= Self.simpleUploadLimit {
            // multipart/form-data: "attributes" (JSON) + "file".
            let boundary = "wormlink-\(UUID().uuidString)"
            var attributes: [String: Any] = ["name": RemotePath.name(path)]
            if existing == nil { attributes["parent"] = ["id": parent.id] }
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attributes\"\r\n\r\n".utf8))
            body.append(try JSONSerialization.data(withJSONObject: attributes))
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(try Data(contentsOf: local))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: Self.upload.appending(path: existing.map { "files/\($0.id)/content" } ?? "files/content"))
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.send(request, body: body, delegate: CloudUploadProgress(progress))
            let json = try cloudJSON(data, response, expect: [200, 201])
            if let id = (json["entries"] as? [[String: Any]])?.first?["id"] as? String { await ids.set(RemotePath.normalize(path), id) }
            return
        }
        try await chunkedUpload(local, size: size, to: path, parent: parent.id, existing: existing?.id, progress: progress)
    }

    /// Sessão de envio em partes (arquivos grandes): cada parte leva o SHA-1, e o arquivo inteiro também.
    private func chunkedUpload(_ local: URL, size: Int64, to path: String, parent: String, existing: String?,
                               progress: @escaping @Sendable (Int64) -> Void) async throws {
        let sessionJSON = try await call("POST", Self.upload.appending(path: existing.map { "files/\($0)/upload_sessions" } ?? "files/upload_sessions"),
                                         json: existing == nil ? ["folder_id": parent, "file_size": size, "file_name": RemotePath.name(path)]
                                                               : ["file_size": size], expect: [201])
        guard let id = sessionJSON["id"] as? String, let partSize = (sessionJSON["part_size"] as? NSNumber)?.intValue else {
            throw WormlinkError.invalidResponse
        }
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        var whole = Insecure.SHA1()
        var parts: [[String: Any]] = []
        var offset: Int64 = 0
        while let chunk = try reader.read(upToCount: partSize), !chunk.isEmpty {
            try Task.checkCancellation()
            whole.update(data: chunk)
            var request = URLRequest(url: Self.upload.appending(path: "files/upload_sessions/\(id)"))
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            request.setValue("sha=\(Data(Insecure.SHA1.hash(data: chunk)).base64EncodedString())", forHTTPHeaderField: "Digest")
            let (data, response) = try await session.send(request, body: chunk)
            if let part = try cloudJSON(data, response)["part"] as? [String: Any] { parts.append(part) }
            offset += Int64(chunk.count)
            progress(offset)
        }
        var commit = URLRequest(url: Self.upload.appending(path: "files/upload_sessions/\(id)/commit"))
        commit.httpMethod = "POST"
        commit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        commit.setValue("sha=\(Data(whole.finalize()).base64EncodedString())", forHTTPHeaderField: "Digest")
        let body = try JSONSerialization.data(withJSONObject: ["parts": parts])
        // 202: o Box ainda está juntando as partes; tenta de novo depois do Retry-After.
        for _ in 0..<30 {
            let (data, response) = try await session.send(commit, body: body)
            guard response.statusCode == 202 else {
                _ = try cloudJSON(data, response, expect: [201])
                return
            }
            try await Task.sleep(for: .seconds(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2))
        }
        throw WormlinkError.timedOut
    }

    public func disconnect() async {}
}
