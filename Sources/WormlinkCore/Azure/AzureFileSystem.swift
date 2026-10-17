import CryptoKit
import Foundation

/// Azure Blob Storage (REST). A raiz lista os contêineres; `/contêiner/pasta/arquivo` é o blob `pasta/arquivo`.
/// Autenticação por Shared Key (conta + chave) ou SAS (token no lugar da senha), como no Cyberduck e no Transmit.
public final class AzureFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    private let account: String
    private let key: Data?
    private let sas: String?
    private let base: URL
    /// Emulador (Azurite) e endereços por IP usam o nome da conta no caminho.
    private let pathStyle: Bool
    private let session: URLSession
    static let version = "2021-08-06"
    static let singleUploadLimit: Int64 = 256 * 1024 * 1024
    static let blockSize = 8 * 1024 * 1024

    public init(bookmark: Bookmark, secret: String) throws {
        guard !bookmark.username.isEmpty else { throw WormlinkError.authenticationFailed }
        title = bookmark.displayName
        homePath = RemotePath.normalize(bookmark.path)
        account = bookmark.username
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("?") || trimmed.hasPrefix("sv=") || trimmed.contains("&sig=") {
            sas = trimmed.hasPrefix("?") ? String(trimmed.dropFirst()) : trimmed
            key = nil
        } else {
            guard let decoded = Data(base64Encoded: trimmed) else { throw WormlinkError.authenticationFailed }
            key = decoded
            sas = nil
        }
        let host = bookmark.hostname.isEmpty ? "\(account).blob.core.windows.net" : bookmark.hostname
        pathStyle = host == "localhost" || host.allSatisfy { $0.isNumber || $0 == "." }
        var c = URLComponents()
        c.scheme = bookmark.plainHTTP ? "http" : "https"
        c.host = host
        if bookmark.port != (bookmark.plainHTTP ? 80 : 443) { c.port = bookmark.port }
        c.path = pathStyle ? "/\(account)" : ""
        guard let url = c.url else { throw WormlinkError.invalidBookmark }
        base = url
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Wormlink/1.0"]
        session = URLSession(configuration: config)
    }

    // MARK: Requisições

    private func split(_ path: String) -> (container: String, blob: String)? {
        let parts = RemotePath.normalize(path).dropFirst().split(separator: "/", maxSplits: 1)
        guard let container = parts.first else { return nil }
        return (String(container), parts.count > 1 ? String(parts[1]) : "")
    }

    static func encode(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        allowed.remove("/")
        return text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
    }

    func url(container: String? = nil, blob: String = "", query: [String: String] = [:]) -> URL {
        var path = base.path(percentEncoded: true)
        if let container { path += "/" + Self.encode(container) }
        if !blob.isEmpty { path += "/" + Self.encode(blob) }
        if path.isEmpty { path = "/" }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        var items = query.sorted { $0.key < $1.key }.map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }
        if let sas { items.append(sas) }
        c.percentEncodedQuery = items.isEmpty ? nil : items.joined(separator: "&")
        return c.url!
    }

    /// Shared Key: HMAC-SHA256 da representação canônica da requisição (versão 2015-02-21 ou posterior).
    func sign(_ request: inout URLRequest, contentLength: Int64? = nil) {
        request.setValue(Self.version, forHTTPHeaderField: "x-ms-version")
        request.setValue(Self.rfc1123.string(from: Date()), forHTTPHeaderField: "x-ms-date")
        guard let key, let url = request.url else { return }
        let headers = request.allHTTPHeaderFields ?? [:]
        func header(_ name: String) -> String { headers.first { $0.key.lowercased() == name }?.value ?? "" }
        let length = contentLength.map { $0 == 0 ? "" : String($0) } ?? header("content-length")
        let canonicalHeaders = headers.filter { $0.key.lowercased().hasPrefix("x-ms-") }
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)\n" }.joined()
        // Recurso canônico: /conta + caminho (o emulador repete a conta, que já está no caminho).
        var resource = "/\(account)" + url.path(percentEncoded: true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let grouped = Dictionary(grouping: items, by: { $0.name.lowercased() })
        for name in grouped.keys.sorted() {
            resource += "\n\(name):" + grouped[name]!.compactMap(\.value).sorted().joined(separator: ",")
        }
        let toSign = [request.httpMethod ?? "GET", header("content-encoding"), header("content-language"), length,
                      header("content-md5"), header("content-type"), "", header("if-modified-since"), header("if-match"),
                      header("if-none-match"), header("if-unmodified-since"), header("range")].joined(separator: "\n")
            + "\n" + canonicalHeaders + resource
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: key))).base64EncodedString()
        request.setValue("SharedKey \(account):\(signature)", forHTTPHeaderField: "Authorization")
    }

    static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    @discardableResult
    private func send(_ method: String, container: String? = nil, blob: String = "", query: [String: String] = [:],
                      headers: [String: String] = [:], body: Data? = nil, expect: Set<Int> = [200, 201, 202]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(container: container, blob: blob, query: query))
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body { request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
        sign(&request, contentLength: body.map { Int64($0.count) } ?? (["PUT", "POST", "DELETE"].contains(method) ? 0 : nil))
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        let http = response as! HTTPURLResponse
        Transcript.log(title, "\(method) /\(container ?? "")\(blob.isEmpty ? "" : "/" + blob) → \(http.statusCode)")
        guard expect.contains(http.statusCode) else { throw Self.error(http.statusCode, data) }
        return (data, http)
    }

    static func error(_ status: Int, _ data: Data) -> WormlinkError {
        let nodes = S3XML.parse(data)
        let code = nodes.first { $0.name == "Code" }?.text ?? ""
        let message = nodes.first { $0.name == "Message" }?.text.components(separatedBy: "\n").first
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch (status, code) {
        case (403, "AuthenticationFailed"), (403, "AuthorizationFailure"): return .authenticationFailed
        case (404, _): return .notFound(message)
        default: return .server(status: status, message: message)
        }
    }

    // MARK: Listagem

    public func list(_ path: String) async throws -> [FileItem] {
        guard let (container, blob) = split(path) else {
            var items: [FileItem] = []
            var marker: String?
            repeat {
                var query = ["comp": "list"]
                if let marker { query["marker"] = marker }
                let (data, _) = try await send("GET", query: query)
                let nodes = S3XML.parse(data)
                items += S3XML.groups(nodes, named: "Container").compactMap { c in
                    c["Name"].map { FileItem(path: "/" + $0, isDirectory: true, modified: c["Last-Modified"].flatMap(Self.rfc1123.date(from:))) }
                }
                marker = nodes.first { $0.name == "NextMarker" }?.text.nilIfEmpty
            } while marker != nil
            return items
        }
        let prefix = blob.isEmpty ? "" : (blob.hasSuffix("/") ? blob : blob + "/")
        var items: [FileItem] = []
        var marker: String?
        repeat {
            var query = ["restype": "container", "comp": "list", "delimiter": "/", "prefix": prefix]
            if let marker { query["marker"] = marker }
            let (data, _) = try await send("GET", container: container, query: query)
            let nodes = S3XML.parse(data)
            for entry in S3XML.groups(nodes, named: "BlobPrefix") {
                if let name = entry["Name"] { items.append(FileItem(path: RemotePath.join("/" + container, name), isDirectory: true)) }
            }
            for entry in S3XML.groups(nodes, named: "Blob") {
                guard let name = entry["Name"], name != prefix else { continue }   // marcador da própria pasta
                items.append(FileItem(path: RemotePath.join("/" + container, name), isDirectory: false,
                                      size: entry["Content-Length"].flatMap(Int64.init),
                                      modified: entry["Last-Modified"].flatMap(Self.rfc1123.date(from:))))
            }
            marker = nodes.first { $0.name == "NextMarker" }?.text.nilIfEmpty
        } while marker != nil
        return items
    }

    private func allBlobs(_ container: String, prefix: String) async throws -> [String] {
        var names: [String] = []
        var marker: String?
        repeat {
            var query = ["restype": "container", "comp": "list", "prefix": prefix]
            if let marker { query["marker"] = marker }
            let (data, _) = try await send("GET", container: container, query: query)
            let nodes = S3XML.parse(data)
            names += S3XML.groups(nodes, named: "Blob").compactMap { $0["Name"] }
            marker = nodes.first { $0.name == "NextMarker" }?.text.nilIfEmpty
        } while marker != nil
        return names
    }

    // MARK: Operações

    public func createDirectory(_ path: String) async throws {
        guard let (container, blob) = split(path) else { return }
        if blob.isEmpty {
            try await send("PUT", container: container, query: ["restype": "container"], expect: [201])
        } else {
            // Pastas não existem em blobs: um blob vazio "pasta/" marca o lugar.
            try await send("PUT", container: container, blob: blob.hasSuffix("/") ? blob : blob + "/",
                           headers: ["x-ms-blob-type": "BlockBlob"], body: Data(), expect: [201])
        }
    }

    public func delete(_ item: FileItem) async throws {
        guard let (container, blob) = split(item.path) else { return }
        if blob.isEmpty {
            try await send("DELETE", container: container, query: ["restype": "container"], expect: [202])
        } else if item.isDirectory {
            for name in try await allBlobs(container, prefix: blob + "/") {
                try await send("DELETE", container: container, blob: name, expect: [202, 404])
            }
        } else {
            try await send("DELETE", container: container, blob: blob, expect: [202])
        }
    }

    public func move(_ path: String, to newPath: String) async throws {
        guard let (container, blob) = split(path), let (newContainer, newBlob) = split(newPath), !blob.isEmpty else {
            throw WormlinkError.unsupportedOperation("Renomear contêineres")
        }
        let children = try await allBlobs(container, prefix: blob + "/")
        let pairs = children.isEmpty ? [(blob, newBlob)] : children.map { ($0, newBlob + "/" + $0.dropFirst(blob.count + 1)) }
        for (from, to) in pairs {
            try await send("PUT", container: newContainer, blob: to,
                           headers: ["x-ms-copy-source": url(container: container, blob: from).absoluteString], expect: [202, 201])
            try await send("DELETE", container: container, blob: from, expect: [202])
        }
    }

    public var canResumeDownloads: Bool { true }
    public var uploadsAreAtomic: Bool { true }

    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        guard let (container, blob) = split(path), !blob.isEmpty else { return nil }
        let (_, response) = try await send("HEAD", container: container, blob: blob)
        guard let md5 = response.value(forHTTPHeaderField: "Content-MD5").flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return Checksum(.md5, md5.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Transferências

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let (container, blob) = split(path), !blob.isEmpty else { throw WormlinkError.notFound(path) }
        var request = URLRequest(url: url(container: container, blob: blob))
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "x-ms-range") }
        sign(&request)
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as! HTTPURLResponse
        Transcript.log(title, "GET /\(container)/\(blob) → \(http.statusCode)")
        guard http.statusCode == 200 || http.statusCode == 206 else { throw Self.error(http.statusCode, Data()) }
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

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let (container, blob) = split(path), !blob.isEmpty else { throw WormlinkError.unsupportedOperation("Enviar para a raiz") }
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        if size <= Self.singleUploadLimit {
            let data = try reader.readToEnd() ?? Data()
            await BandwidthLimiter.shared.throttle(data.count, .upload)
            let md5 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()
            try await send("PUT", container: container, blob: blob,
                           headers: ["x-ms-blob-type": "BlockBlob", "Content-MD5": md5, "x-ms-blob-content-md5": md5], body: data, expect: [201])
            progress(size)
            return
        }
        // Blocos de 8 MB e depois a lista de blocos (Put Block / Put Block List).
        var ids: [String] = []
        var sent: Int64 = 0
        while let chunk = try reader.read(upToCount: Self.blockSize), !chunk.isEmpty {
            try Task.checkCancellation()
            let id = Data(String(format: "bloco-%08d", ids.count).utf8).base64EncodedString()
            await BandwidthLimiter.shared.throttle(chunk.count, .upload)
            try await send("PUT", container: container, blob: blob, query: ["comp": "block", "blockid": id], body: chunk, expect: [201])
            ids.append(id)
            sent += Int64(chunk.count)
            progress(sent)
        }
        let list = "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>" + ids.map { "<Latest>\($0)</Latest>" }.joined() + "</BlockList>"
        try await send("PUT", container: container, blob: blob, query: ["comp": "blocklist"], body: Data(list.utf8), expect: [201])
    }

    public func disconnect() async { session.invalidateAndCancel() }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
