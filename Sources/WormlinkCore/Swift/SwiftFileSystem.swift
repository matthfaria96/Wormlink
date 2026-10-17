import Foundation

/// OpenStack Swift (e Rackspace Cloud Files): Keystone v3, v2 ou v1/TempAuth.
/// A raiz lista os contêineres; pastas são prefixos com "/" (e marcadores application/directory).
public final class SwiftFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    private let storage: URL
    private let token: String
    private let session: URLSession

    init(title: String, homePath: String, storage: URL, token: String) {
        self.title = title
        self.homePath = homePath
        self.storage = storage
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Wormlink/1.0"]
        session = URLSession(configuration: config)
    }

    /// Endereço de autenticação: `https://host[:porta]/v3` (Keystone 3), `/v2.0` ou `/auth/v1.0`.
    /// Usuário no formato do Cyberduck: `projeto:usuário` (ou `domínio:projeto:usuário` no v3).
    public static func connect(_ bookmark: Bookmark, password: String) async throws -> SwiftFileSystem {
        var c = URLComponents()
        c.scheme = bookmark.plainHTTP ? "http" : "https"
        c.host = bookmark.hostname
        if bookmark.port != (bookmark.plainHTTP ? 80 : 443) { c.port = bookmark.port }
        let authPath = bookmark.swiftAuthPath ?? "/v3"
        c.path = authPath
        guard let authURL = c.url else { throw WormlinkError.invalidBookmark }
        let parts = bookmark.username.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let (storage, token): (URL, String)
        if authPath.contains("v3") {
            (storage, token) = try await keystone3(authURL, parts: parts, password: password, region: bookmark.swiftRegion)
        } else if authPath.contains("v2") {
            (storage, token) = try await keystone2(authURL, parts: parts, password: password, region: bookmark.swiftRegion)
        } else {
            (storage, token) = try await tempAuth(authURL, user: bookmark.username, key: password)
        }
        Transcript.log(bookmark.displayName, "Swift: armazenamento em \(storage.absoluteString)")
        return SwiftFileSystem(title: bookmark.displayName, homePath: RemotePath.normalize(bookmark.path), storage: storage, token: token)
    }

    static func tempAuth(_ url: URL, user: String, key: String) async throws -> (URL, String) {
        var request = URLRequest(url: url)
        request.setValue(user, forHTTPHeaderField: "X-Auth-User")
        request.setValue(key, forHTTPHeaderField: "X-Auth-Key")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode), let storage = http.value(forHTTPHeaderField: "X-Storage-Url").flatMap(URL.init(string:)),
              let token = http.value(forHTTPHeaderField: "X-Auth-Token") else {
            throw http.statusCode == 401 ? WormlinkError.authenticationFailed : WormlinkError.invalidResponse
        }
        return (storage, token)
    }

    static func keystone2(_ url: URL, parts: [String], password: String, region: String?) async throws -> (URL, String) {
        let (tenant, user) = parts.count >= 2 ? (parts[0], parts[1]) : ("", parts.first ?? "")
        var request = URLRequest(url: url.appending(path: "tokens"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var auth: [String: Any] = ["passwordCredentials": ["username": user, "password": password]]
        if !tenant.isEmpty { auth["tenantName"] = tenant }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["auth": auth])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as! HTTPURLResponse).statusCode == 200 else { throw WormlinkError.authenticationFailed }
        let access = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["access"] as? [String: Any] ?? [:]
        guard let token = (access["token"] as? [String: Any])?["id"] as? String,
              let storage = endpoint(in: access["serviceCatalog"] as? [[String: Any]] ?? [], region: region, v3: false) else {
            throw WormlinkError.invalidResponse
        }
        return (storage, token)
    }

    static func keystone3(_ url: URL, parts: [String], password: String, region: String?) async throws -> (URL, String) {
        let domain = parts.count >= 3 ? parts[0] : "Default"
        let project = parts.count >= 2 ? parts[parts.count - 2] : ""
        let user = parts.last ?? ""
        var request = URLRequest(url: url.appending(path: "auth/tokens"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var auth: [String: Any] = ["identity": ["methods": ["password"],
                                                "password": ["user": ["name": user, "domain": ["name": domain], "password": password]]]]
        if !project.isEmpty { auth["scope"] = ["project": ["name": project, "domain": ["name": domain]]] }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["auth": auth])
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 201 || http.statusCode == 200, let token = http.value(forHTTPHeaderField: "X-Subject-Token") else {
            throw http.statusCode == 401 ? WormlinkError.authenticationFailed : WormlinkError.invalidResponse
        }
        let body = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? [String: Any] ?? [:]
        guard let storage = endpoint(in: body["catalog"] as? [[String: Any]] ?? [], region: region, v3: true) else {
            throw WormlinkError.invalidResponse
        }
        return (storage, token)
    }

    /// Endpoint público do serviço "object-store" (na região pedida, quando há várias).
    static func endpoint(in catalog: [[String: Any]], region: String?, v3: Bool) -> URL? {
        guard let service = catalog.first(where: { $0["type"] as? String == "object-store" }),
              let endpoints = service["endpoints"] as? [[String: Any]] else { return nil }
        let candidates = endpoints.filter { region == nil || ($0["region"] as? String ?? $0["region_id"] as? String) == region }
        if v3 {
            return candidates.first { $0["interface"] as? String == "public" }.flatMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
        }
        return candidates.first.flatMap { ($0["publicURL"] as? String).flatMap(URL.init(string:)) }
    }

    // MARK: Requisições

    private func split(_ path: String) -> (container: String, object: String)? {
        let parts = RemotePath.normalize(path).dropFirst().split(separator: "/", maxSplits: 1)
        guard let container = parts.first else { return nil }
        return (String(container), parts.count > 1 ? String(parts[1]) : "")
    }

    func url(container: String? = nil, object: String = "", query: [String: String] = [:]) -> URL {
        var url = storage
        if let container { url.append(path: container) }
        if !object.isEmpty { url.append(path: object) }
        if !query.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.setQuery(query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
            url = c.url ?? url
        }
        return url
    }

    @discardableResult
    private func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil,
                      expect: Set<Int> = [200, 201, 202, 204]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        let http = response as! HTTPURLResponse
        Transcript.log(title, "\(method) \(url.path(percentEncoded: false)) → \(http.statusCode)")
        guard expect.contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw WormlinkError.authenticationFailed
            case 404: throw WormlinkError.notFound(url.path(percentEncoded: false))
            default: throw WormlinkError.server(status: http.statusCode, message: String(decoding: data.prefix(200), as: UTF8.self))
            }
        }
        return (data, http)
    }

    static func lastModified(_ text: String?) -> Date? {
        guard let text else { return nil }
        return parseISODate(text) ?? parseISODate(text + "Z")
    }

    // MARK: Listagem

    public func list(_ path: String) async throws -> [FileItem] {
        guard let (container, object) = split(path) else {
            let (data, _) = try await send("GET", url(query: ["format": "json"]))
            let containers = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            return containers.compactMap { ($0["name"] as? String).map { FileItem(path: "/" + $0, isDirectory: true) } }
        }
        let prefix = object.isEmpty ? "" : (object.hasSuffix("/") ? object : object + "/")
        var items: [FileItem] = []
        var marker: String?
        repeat {
            var query = ["format": "json", "delimiter": "/", "prefix": prefix, "limit": "10000"]
            if let marker { query["marker"] = marker }
            let (data, _) = try await send("GET", url(container: container, query: query))
            let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            for entry in entries {
                if let subdir = entry["subdir"] as? String {
                    // A mesma pasta pode vir como marcador e como prefixo: uma entrada só.
                    let path = RemotePath.join("/" + container, subdir)
                    if !items.contains(where: { $0.path == path }) { items.append(FileItem(path: path, isDirectory: true)) }
                } else if let name = entry["name"] as? String, name != prefix {
                    // Marcadores de pasta (application/directory) aparecem como pasta.
                    let isMarker = entry["content_type"] as? String == "application/directory"
                    if items.contains(where: { $0.path == RemotePath.join("/" + container, name) }) { continue }
                    items.append(FileItem(path: RemotePath.join("/" + container, name), isDirectory: isMarker,
                                          size: isMarker ? nil : (entry["bytes"] as? NSNumber)?.int64Value,
                                          modified: Self.lastModified(entry["last_modified"] as? String)))
                }
            }
            marker = entries.count == 10000 ? (entries.last?["name"] as? String ?? entries.last?["subdir"] as? String) : nil
        } while marker != nil
        return items
    }

    private func allObjects(_ container: String, prefix: String) async throws -> [String] {
        var names: [String] = []
        var marker: String?
        repeat {
            var query = ["format": "json", "prefix": prefix, "limit": "10000"]
            if let marker { query["marker"] = marker }
            let (data, _) = try await send("GET", url(container: container, query: query))
            let page = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            names += page
            marker = page.count == 10_000 ? page.last : nil
        } while marker != nil
        return names
    }

    // MARK: Operações

    public func createDirectory(_ path: String) async throws {
        guard let (container, object) = split(path) else { return }
        if object.isEmpty {
            try await send("PUT", url(container: container), expect: [201, 202])
        } else {
            try await send("PUT", url(container: container, object: object.hasSuffix("/") ? object : object + "/"),
                           headers: ["Content-Type": "application/directory"], body: Data(), expect: [201])
        }
    }

    public func delete(_ item: FileItem) async throws {
        guard let (container, object) = split(item.path) else { return }
        if object.isEmpty {
            try await send("DELETE", url(container: container), expect: [204, 404])
        } else if item.isDirectory {
            for name in try await allObjects(container, prefix: object + "/") {
                try await send("DELETE", url(container: container, object: name), expect: [204, 404])
            }
            try await send("DELETE", url(container: container, object: object + "/"), expect: [204, 404])
            try await send("DELETE", url(container: container, object: object), expect: [204, 404])
        } else {
            let (_, head) = try await send("HEAD", url(container: container, object: object), expect: [200, 204])
            if head.value(forHTTPHeaderField: "X-Static-Large-Object")?.lowercased() == "true" {
                try await send("DELETE", url(container: container, object: object, query: ["multipart-manifest": "delete"]), expect: [200, 204])
            } else {
                try await send("DELETE", url(container: container, object: object), expect: [204])
            }
        }
    }

    public func move(_ path: String, to newPath: String) async throws {
        guard let (container, object) = split(path), let (newContainer, newObject) = split(newPath), !object.isEmpty else {
            throw WormlinkError.unsupportedOperation(String(localized: "Renomear contêineres"))
        }
        let children = try await allObjects(container, prefix: object + "/")
        let pairs = children.isEmpty ? [(object, newObject)] : children.map { ($0, newObject + "/" + $0.dropFirst(object.count + 1)) }
        for (from, to) in pairs {
            let source = "/\(container)/\(from)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(container)/\(from)"
            // multipart-manifest=get: num SLO copia o manifesto, não os gigabytes (objetos comuns ignoram).
            try await send("PUT", url(container: newContainer, object: to, query: ["multipart-manifest": "get"]),
                           headers: ["X-Copy-From": source], body: Data(), expect: [201])
            try await send("DELETE", url(container: container, object: from), expect: [204])
        }
    }

    public var canResumeDownloads: Bool { true }
    public var uploadsAreAtomic: Bool { true }

    /// O ETag de objetos comuns é o MD5 do conteúdo.
    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        guard let (container, object) = split(path), !object.isEmpty else { return nil }
        let (_, response) = try await send("HEAD", url(container: container, object: object))
        guard let etag = response.value(forHTTPHeaderField: "Etag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              etag.count == 32 else { return nil }
        return Checksum(.md5, etag)
    }

    // MARK: Transferências

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let (container, object) = split(path), !object.isEmpty else { throw WormlinkError.notFound(path) }
        var request = URLRequest(url: url(container: container, object: object))
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 || http.statusCode == 206 else { throw WormlinkError.server(status: http.statusCode, message: "GET") }
        let start = LocalAppend.effectiveOffset(offset, http)
        try LocalAppend.prepare(local, offset: start)
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var buffer = Data(capacity: 1 << 18)
        var total = start
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 18 {
                try handle.write(contentsOf: buffer)
                await BandwidthLimiter.shared.throttle(buffer.count, .download)
                total += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(total)
            }
        }
        try handle.write(contentsOf: buffer)
        progress(total + Int64(buffer.count))
    }

    /// O Swift recusa objetos acima de 5 GB num PUT só: acima disso vai em segmentos com um manifesto (SLO).
    nonisolated(unsafe) static var largeObjectThreshold: Int64 = 5 * 1024 * 1024 * 1024
    nonisolated(unsafe) static var segmentSize: Int64 = 1024 * 1024 * 1024

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let (container, object) = split(path), !object.isEmpty else { throw WormlinkError.unsupportedOperation(String(localized: "Enviar para a raiz")) }
        let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if size > Self.largeObjectThreshold { return try await uploadLarge(local, size: size, container: container, object: object, progress: progress) }
        var request = URLRequest(url: url(container: container, object: object))
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        let (data, response) = request.useThrottledBody(from: local)
            ? try await session.data(for: request, delegate: StreamUpload(file: local, progress: progress))
            : try await session.upload(for: request, fromFile: local, delegate: CloudUploadProgress(progress))
        let status = (response as! HTTPURLResponse).statusCode
        Transcript.log(title, "PUT /\(container)/\(object) → \(status)")
        guard status == 201 else { throw WormlinkError.server(status: status, message: String(decoding: data.prefix(200), as: UTF8.self)) }
    }

    /// Segmentos em ".file-segments/<objeto>/<data>/<tamanho>/<n>" (o mesmo esquema do Cyberduck) e o manifesto no lugar do objeto.
    private func uploadLarge(_ local: URL, size: Int64, container: String, object: String,
                             progress: @escaping @Sendable (Int64) -> Void) async throws {
        let prefix = ".file-segments/\(object)/\(Int(Date().timeIntervalSince1970))/\(size)"
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        var manifest: [[String: Any]] = []
        var sent: Int64 = 0, index = 0
        while sent < size {
            try Task.checkCancellation()
            let name = prefix + String(format: "/%08d", index)
            let length = min(Self.segmentSize, size - sent)
            // Cada segmento sai de um arquivo temporário (o envio por arquivo não lê tudo na memória).
            let part = FileManager.default.temporaryDirectory.appending(path: "Wormlink-segmento-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: part) }
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let output = try FileHandle(forWritingTo: part)
            var copied: Int64 = 0
            while copied < length {
                guard let block = try input.read(upToCount: Int(min(8 * 1024 * 1024, length - copied))), !block.isEmpty else { break }
                try output.write(contentsOf: block)
                copied += Int64(block.count)
            }
            try output.close()
            var request = URLRequest(url: url(container: container, object: name))
            request.httpMethod = "PUT"
            request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
            let base = sent
            let (data, response) = try await session.upload(for: request, fromFile: part, delegate: CloudUploadProgress { progress(base + $0) })
            let http = response as! HTTPURLResponse
            Transcript.log(title, "PUT /\(container)/\(name) → \(http.statusCode)")
            guard http.statusCode == 201 else { throw WormlinkError.server(status: http.statusCode, message: String(decoding: data.prefix(200), as: UTF8.self)) }
            manifest.append(["path": "/\(container)/\(name)", "etag": http.value(forHTTPHeaderField: "Etag") ?? "", "size_bytes": copied])
            sent += copied
            index += 1
        }
        try await send("PUT", url(container: container, object: object, query: ["multipart-manifest": "put"]),
                       body: try JSONSerialization.data(withJSONObject: manifest), expect: [201])
        progress(size)
    }

    /// HTTP não tem sessão aberta para fechar. Invalidar aqui derrubaria o app: editor, fila e miniaturas
    /// ainda usam este objeto depois que o painel desconecta (criar tarefa numa sessão invalidada é exceção).
    public func disconnect() async {}

    deinit { session.finishTasksAndInvalidate() }
}
