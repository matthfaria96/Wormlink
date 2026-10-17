import CryptoKit
import Foundation

/// Amazon S3 e compatíveis (MinIO, Wasabi, R2, DigitalOcean Spaces…).
/// A raiz lista os buckets; `/bucket/pasta/arquivo` mapeia para a chave `pasta/arquivo`.
public final class S3FileSystem: FileSystem {
    public let title: String
    public let homePath: String
    let endpoint: String
    private let port: Int
    public let isAWS: Bool
    private let scheme: String
    let credentials: AWSCredentials
    let session: URLSession
    /// Cabeçalhos de arquivos novos: classe de armazenamento, criptografia e ACL padrão do servidor.
    public let uploadHeaders: [String: String]
    /// "Requester pays": quem baixa paga a transferência (cabeçalho em todas as requisições).
    public let requesterPays: Bool
    /// Transfer Acceleration (só AWS, buckets sem ponto no nome).
    public let accelerate: Bool
    private let regions = RegionCache()

    /// Acima disso o envio é em partes (multipart upload), como no Cyberduck.
    static let multipartThreshold: Int64 = 64 * 1024 * 1024
    static let partSize = 16 * 1024 * 1024

    /// Conecta resolvendo as credenciais (chaves, perfil da AWS CLI, AssumeRole com MFA).
    public static func connect(_ bookmark: Bookmark, secret: String, trust: ConnectionTrust) async throws -> S3FileSystem {
        let credentials = try await AWSCredentials.resolve(bookmark, secret: secret, trust: trust)
        return try S3FileSystem(bookmark: bookmark, credentials: credentials)
    }

    public convenience init(bookmark: Bookmark, secretKey: String) throws {
        guard !bookmark.username.isEmpty else { throw WormlinkError.authenticationFailed }
        try self.init(bookmark: bookmark, credentials: AWSCredentials(signer: S3Signer(accessKey: bookmark.username, secretKey: secretKey)))
    }

    init(bookmark: Bookmark, credentials: AWSCredentials, endpoint override: String? = nil) throws {
        title = bookmark.displayName
        homePath = RemotePath.normalize(bookmark.path)
        endpoint = override ?? (bookmark.hostname.isEmpty ? "s3.amazonaws.com" : bookmark.hostname.lowercased())
        port = bookmark.port
        isAWS = endpoint.hasSuffix("amazonaws.com")
        scheme = bookmark.plainHTTP ? "http" : "https"
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Wormlink/1.0"]
        if let timeout = bookmark.timeout { config.timeoutIntervalForRequest = TimeInterval(timeout) }
        session = URLSession(configuration: config)
        var headers: [String: String] = [:]
        if let value = bookmark.s3StorageClass, !value.isEmpty { headers["x-amz-storage-class"] = value }
        if let value = bookmark.s3Encryption, !value.isEmpty { headers["x-amz-server-side-encryption"] = value }
        if let value = bookmark.s3ACL, !value.isEmpty { headers["x-amz-acl"] = value }
        uploadHeaders = headers
        requesterPays = bookmark.s3RequesterPays ?? false
        accelerate = bookmark.s3Accelerate ?? false
    }

    /// Cabeçalhos comuns a toda requisição de objeto.
    func common(_ request: inout URLRequest) {
        if requesterPays { request.setValue("requester", forHTTPHeaderField: "x-amz-request-payer") }
    }

    // MARK: Caminhos

    func split(_ path: String) -> (bucket: String, key: String)? {
        let parts = RemotePath.normalize(path).dropFirst().split(separator: "/", maxSplits: 1)
        guard let bucket = parts.first else { return nil }
        return (String(bucket), parts.count > 1 ? String(parts[1]) : "")
    }

    func url(bucket: String?, key: String = "", query: [String: String] = [:], region: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        if port != (scheme == "https" ? 443 : 80) { c.port = port }
        let encodedKey = S3Signer.encode(key, keepSlash: true)
        if let bucket, isAWS, !bucket.contains("."), accelerate, !key.isEmpty {
            c.host = "\(bucket).s3-accelerate.amazonaws.com"
            c.percentEncodedPath = "/" + encodedKey
        } else if let bucket, isAWS, !bucket.contains(".") {
            c.host = "\(bucket).s3.\(region).amazonaws.com"
            c.percentEncodedPath = "/" + encodedKey
        } else if let bucket {
            c.host = isAWS ? "s3.\(region).amazonaws.com" : endpoint
            c.percentEncodedPath = "/\(S3Signer.encode(bucket))/" + encodedKey
        } else {
            c.host = endpoint
            c.percentEncodedPath = "/"
        }
        if !query.isEmpty {
            c.percentEncodedQuery = query.sorted { $0.key < $1.key }
                .map { $0.value.isEmpty ? S3Signer.encode($0.key) : "\(S3Signer.encode($0.key))=\(S3Signer.encode($0.value))" }
                .joined(separator: "&")
        }
        return c.url!
    }

    /// Região do bucket (cabeçalho `x-amz-bucket-region`, que vem até em respostas de erro).
    /// Região para a assinatura em provedores compatíveis (B2 e Wasabi exigem a certa):
    /// "auto" no R2 e no Google; "aa-bbbb-N" no endereço; "s3.<região>.provedor"; "<região>.provedor" (Spaces, Hetzner).
    static func region(forEndpoint host: String) -> String {
        if host.hasSuffix("r2.cloudflarestorage.com") || host == "storage.googleapis.com" { return "auto" }
        if host == "localhost" || host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return "us-east-1" }
        if let match = host.firstMatch(of: /[a-z]{2}-[a-z]+-\d+/) { return String(match.output) }
        let parts = host.split(separator: ".").map(String.init)
        if parts.count >= 4, parts[0] == "s3" { return parts[1] }
        if parts.count >= 3, parts[0] != "s3", parts[0].contains(where: \.isNumber) { return parts[0] }
        return "us-east-1"
    }

    func region(of bucket: String) async throws -> String {
        if !isAWS { return Self.region(forEndpoint: endpoint) }
        if let cached = await regions.get(bucket) { return cached }
        var request = URLRequest(url: url(bucket: bucket, region: "us-east-1"))
        request.httpMethod = "HEAD"
        try await credentials.current().sign(&request, region: "us-east-1", payloadHash: S3Signer.emptyHash)
        let (_, response) = try await session.data(for: request)
        let region = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-amz-bucket-region") ?? "us-east-1"
        await regions.set(bucket, region)
        return region
    }

    @discardableResult
    func send(_ method: String, bucket: String?, key: String = "", query: [String: String] = [:],
                      body: Data? = nil, headers: [String: String] = [:], expect: Set<Int> = [200, 204]) async throws -> (Data, HTTPURLResponse) {
        var region = Self.region(forEndpoint: endpoint)
        if let bucket { region = try await self.region(of: bucket) }
        var request = URLRequest(url: url(bucket: bucket, key: key, query: query, region: region))
        request.httpMethod = method
        common(&request)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = body
        try await credentials.current().sign(&request, region: region, payloadHash: S3Signer.sha256Hex(body ?? Data()))
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        Transcript.log(title, "\(method) /\(bucket ?? "")/\(key)\(query.isEmpty ? "" : "?" + query.keys.sorted().joined(separator: "&")) → \(http.statusCode)")
        guard expect.contains(http.statusCode) else { throw Self.error(http.statusCode, data) }
        return (data, http)
    }

    static func error(_ status: Int, _ data: Data) -> WormlinkError {
        let xml = S3XML.parse(data)
        let code = xml.first { $0.name == "Code" }?.text ?? ""
        let message = xml.first { $0.name == "Message" }?.text ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "AccessDenied" where status == 403:
            return code == "AccessDenied" ? .server(status: status, message: message) : .authenticationFailed
        case "NoSuchKey", "NoSuchBucket": return .notFound(message)
        default: return .server(status: status, message: message)
        }
    }

    // MARK: Listagem

    public func list(_ path: String) async throws -> [FileItem] {
        guard let (bucket, key) = split(path) else {
            let (data, _) = try await send("GET", bucket: nil)
            let dates = S3Signer.formatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
            return S3XML.groups(S3XML.parse(data), named: "Bucket").compactMap { bucket in
                bucket["Name"].map { FileItem(path: "/" + $0, isDirectory: true, modified: bucket["CreationDate"].flatMap(dates.date(from:))) }
            }
        }
        let prefix = key.isEmpty ? "" : (key.hasSuffix("/") ? key : key + "/")
        var items: [FileItem] = []
        var token: String?
        let dates = S3Signer.formatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
        repeat {
            var query = ["list-type": "2", "delimiter": "/", "prefix": prefix]
            if let token { query["continuation-token"] = token }
            let (data, _) = try await send("GET", bucket: bucket, query: query)
            let nodes = S3XML.parse(data)
            for entry in S3XML.groups(nodes, named: "CommonPrefixes") {
                if let p = entry["Prefix"] { items.append(FileItem(path: RemotePath.join("/" + bucket, p), isDirectory: true)) }
            }
            for entry in S3XML.groups(nodes, named: "Contents") {
                guard let k = entry["Key"], k != prefix else { continue }   // marcador da própria pasta
                items.append(FileItem(path: RemotePath.join("/" + bucket, k), isDirectory: false,
                                      size: entry["Size"].flatMap(Int64.init),
                                      modified: entry["LastModified"].flatMap { dates.date(from: $0) }))
            }
            token = nodes.first { $0.name == "IsTruncated" }?.text == "true" ? nodes.first { $0.name == "NextContinuationToken" }?.text : nil
        } while token != nil
        return items
    }

    /// Todas as chaves sob um prefixo (sem delimitador), para apagar ou mover pastas.
    private func allKeys(bucket: String, prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            var query = ["list-type": "2", "prefix": prefix]
            if let token { query["continuation-token"] = token }
            let (data, _) = try await send("GET", bucket: bucket, query: query)
            let nodes = S3XML.parse(data)
            keys += S3XML.groups(nodes, named: "Contents").compactMap { $0["Key"] }
            token = nodes.first { $0.name == "IsTruncated" }?.text == "true" ? nodes.first { $0.name == "NextContinuationToken" }?.text : nil
        } while token != nil
        return keys
    }

    // MARK: Operações

    public func createDirectory(_ path: String) async throws {
        guard let (bucket, key) = split(path) else { return }
        if key.isEmpty {
            // Novo bucket.
            let region = isAWS ? "us-east-1" : Self.region(forEndpoint: endpoint)
            var request = URLRequest(url: url(bucket: bucket, region: region))
            request.httpMethod = "PUT"
            try await credentials.current().sign(&request, region: region, payloadHash: S3Signer.emptyHash)
            let (data, response) = try await session.data(for: request)
            let status = (response as! HTTPURLResponse).statusCode
            guard status == 200 else { throw Self.error(status, data) }
        } else {
            try await send("PUT", bucket: bucket, key: key.hasSuffix("/") ? key : key + "/", body: Data())
        }
    }

    public func delete(_ item: FileItem) async throws {
        guard let (bucket, key) = split(item.path) else { return }
        if key.isEmpty {
            try await send("DELETE", bucket: bucket)
        } else if item.isDirectory {
            let keys = try await allKeys(bucket: bucket, prefix: key + "/")
            for batch in stride(from: 0, to: keys.count, by: 1000).map({ Array(keys[$0..<min($0 + 1000, keys.count)]) }) {
                let objects = batch.map { "<Object><Key>\(S3XML.escape($0))</Key></Object>" }.joined()
                let body = Data("<Delete><Quiet>true</Quiet>\(objects)</Delete>".utf8)
                let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
                let (reply, _) = try await send("POST", bucket: bucket, query: ["delete": ""], body: body,
                                                headers: ["Content-MD5": md5, "Content-Type": "application/xml"])
                // Em modo silencioso o 200 só lista o que falhou.
                let nodes = S3XML.parse(reply)
                if let failed = nodes.first(where: { $0.name == "Key" })?.text, nodes.contains(where: { $0.name == "Error" }) {
                    throw WormlinkError.server(status: 200, message: (nodes.first { $0.name == "Message" }?.text ?? "") + " (\(failed))")
                }
            }
            _ = try? await send("DELETE", bucket: bucket, key: key + "/")
        } else {
            try await send("DELETE", bucket: bucket, key: key)
        }
    }

    public func move(_ path: String, to newPath: String) async throws {
        guard let (bucket, key) = split(path), let (newBucket, newKey) = split(newPath), !key.isEmpty else {
            throw WormlinkError.unsupportedOperation("Renomear buckets")
        }
        // Uma "pasta" é um prefixo: move cada chave dentro dele.
        let children = try await allKeys(bucket: bucket, prefix: key + "/")
        let pairs = children.isEmpty ? [(key, newKey)] : children.map { ($0, newKey + "/" + $0.dropFirst(key.count + 1)) }
        for (from, to) in pairs {
            try await send("PUT", bucket: newBucket, key: to,
                           headers: ["x-amz-copy-source": "/\(bucket)/\(S3Signer.encode(from, keepSlash: true))"])
            try await send("DELETE", bucket: bucket, key: from)
        }
    }

    // MARK: Transferências

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public var canResumeDownloads: Bool { true }   // Range; envios recomeçam do zero

    public func upload(_ local: URL, to path: String, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await upload(local, to: path, progress: progress)
    }

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let (bucket, key) = split(path) else { throw WormlinkError.notFound(path) }
        let region = try await region(of: bucket)
        var request = URLRequest(url: url(bucket: bucket, key: key, region: region))
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        common(&request)
        try await credentials.current().sign(&request, region: region, payloadHash: S3Signer.emptyHash)
        Transcript.log(title, "GET \(path)")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        guard status == 200 || (offset > 0 && status == 206) else { throw Self.error(status, Data()) }
        let offset = LocalAppend.effectiveOffset(offset, response as! HTTPURLResponse)
        try LocalAppend.prepare(local, offset: offset)
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var buffer = Data(capacity: 1 << 18)
        var total: Int64 = offset
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
        guard let (bucket, key) = split(path), !key.isEmpty else { throw WormlinkError.unsupportedOperation(String(localized: "Enviar para a raiz")) }
        let size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let region = try await region(of: bucket)
        if size <= Self.multipartThreshold {
            var request = URLRequest(url: url(bucket: bucket, key: key, region: region))
            request.httpMethod = "PUT"
            common(&request)
            uploadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            if let type = Self.contentType(key) { request.setValue(type, forHTTPHeaderField: "Content-Type") }
            try await credentials.current().sign(&request, region: region, payloadHash: S3Signer.unsignedPayload)
            let (data, response) = request.useThrottledBody(from: local)
                ? try await session.data(for: request, delegate: StreamUpload(file: local, progress: progress))
                : try await session.upload(for: request, fromFile: local, delegate: S3UploadProgress(progress))
            let status = (response as! HTTPURLResponse).statusCode
            guard status == 200 else { throw Self.error(status, data) }
            return
        }
        try await multipartUpload(local, size: size, bucket: bucket, key: key, progress: progress)
    }

    private func multipartUpload(_ local: URL, size: Int64, bucket: String, key: String,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws {
        var initiate = uploadHeaders
        if let type = Self.contentType(key) { initiate["Content-Type"] = type }
        let (data, _) = try await send("POST", bucket: bucket, key: key, query: ["uploads": ""], headers: initiate)
        guard let uploadId = S3XML.parse(data).first(where: { $0.name == "UploadId" })?.text else { throw WormlinkError.invalidResponse }
        // O S3 aceita no máximo 10.000 partes: arquivos enormes usam partes maiores (múltiplos de 1 MiB).
        let mebibyte = 1024 * 1024
        let partSize = max(Self.partSize, Int((size + 9_999) / 10_000 + Int64(mebibyte) - 1) / mebibyte * mebibyte)
        let parts = Int((size + Int64(partSize) - 1) / Int64(partSize))
        let counter = ProgressSum(progress)
        do {
            var etags = [Int: String]()
            // Quatro partes em paralelo.
            for batch in stride(from: 1, through: parts, by: 4) {
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    for number in batch..<min(batch + 4, parts + 1) {
                        group.addTask {
                            let reader = try FileHandle(forReadingFrom: local)
                            defer { try? reader.close() }
                            try reader.seek(toOffset: UInt64(number - 1) * UInt64(partSize))
                            let chunk = try reader.read(upToCount: partSize) ?? Data()
                            await BandwidthLimiter.shared.throttle(chunk.count, .upload)
                            let (_, response) = try await self.send("PUT", bucket: bucket, key: key,
                                                                    query: ["partNumber": "\(number)", "uploadId": uploadId], body: chunk)
                            counter.add(Int64(chunk.count))
                            return (number, response.value(forHTTPHeaderField: "ETag") ?? "")
                        }
                    }
                    for try await (number, etag) in group { etags[number] = etag }
                }
            }
            let body = "<CompleteMultipartUpload>" + (1...parts).map {
                "<Part><PartNumber>\($0)</PartNumber><ETag>\(S3XML.escape(etags[$0] ?? ""))</ETag></Part>"
            }.joined() + "</CompleteMultipartUpload>"
            try await send("POST", bucket: bucket, key: key, query: ["uploadId": uploadId], body: Data(body.utf8))
        } catch {
            // Fora da tarefa cancelada, senão o URLSession cancela o próprio pedido de abortar.
            await Task.detached { _ = try? await self.send("DELETE", bucket: bucket, key: key, query: ["uploadId": uploadId]) }.value
            throw error
        }
    }

    public var uploadsAreAtomic: Bool { true }

    /// ETag de envio simples é o MD5 do conteúdo (envios em partes têm "-" e não servem).
    public func remoteChecksum(_ path: String) async throws -> Checksum? {
        guard let (bucket, key) = split(path), !key.isEmpty else { return nil }
        let (_, response) = try await send("HEAD", bucket: bucket, key: key)
        // Com SSE-KMS ou SSE-C o ETag não é o MD5 do conteúdo.
        if response.value(forHTTPHeaderField: "x-amz-server-side-encryption")?.hasPrefix("aws:kms") == true
            || response.value(forHTTPHeaderField: "x-amz-server-side-encryption-customer-algorithm") != nil { return nil }
        guard let etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              etag.count == 32, !etag.contains("-") else { return nil }
        return Checksum(.md5, etag)
    }

    /// HTTP não tem sessão aberta para fechar. Invalidar aqui derrubaria o app: editor, fila e miniaturas
    /// ainda usam este objeto depois que o painel desconecta (criar tarefa numa sessão invalidada é exceção).
    public func disconnect() async {}

    deinit { session.finishTasksAndInvalidate() }
}

// MARK: - Apoio

private actor RegionCache {
    private var regions: [String: String] = [:]
    func get(_ bucket: String) -> String? { regions[bucket] }
    func set(_ bucket: String, _ region: String) { regions[bucket] = region }
}

private final class ProgressSum: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func add(_ n: Int64) { report(lock.withLock { total += n; return total }) }
}

private final class S3UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { report(totalBytesSent) }
}

/// Leitor mínimo das respostas XML do S3: lista plana de elementos com caminho e texto.
enum S3XML {
    /// Elementos que agrupam outros (S3 e Azure).
    static let groupNames: Set<String> = ["Contents", "CommonPrefixes", "Bucket", "Container", "Blob", "BlobPrefix",
                                          "Version", "DeleteMarker", "Grant", "Rule", "DistributionSummary"]

    struct Node { let name: String; let path: String; let text: String }

    static func parse(_ data: Data) -> [Node] {
        let d = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.parse()
        return d.nodes
    }

    /// Agrupa os filhos de cada ocorrência de `name` (ex.: cada `Contents`) num dicionário.
    static func groups(_ nodes: [Node], named name: String) -> [[String: String]] {
        var result: [[String: String]] = []
        var current: [String: String]?
        var depth = ""
        for node in nodes {
            if node.name == name { if let current { result.append(current) }; current = [:]; depth = node.path; continue }
            if current != nil, node.path.hasPrefix(depth + "/") { current?[node.name] = node.text }
            else if let c = current { result.append(c); current = nil }
        }
        if let current { result.append(current) }
        return result
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var nodes: [Node] = []
        private var stack: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            stack.append(name)
            text = ""
            // Elementos de grupo entram já na abertura, para `groups` saber onde começa cada um.
            if S3XML.groupNames.contains(name) {
                nodes.append(Node(name: name, path: stack.joined(separator: "/"), text: ""))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if !S3XML.groupNames.contains(name) {
                nodes.append(Node(name: name, path: stack.joined(separator: "/"), text: text.allSatisfy(\.isWhitespace) ? "" : text))  // nomes podem começar ou terminar com espaço
            }
            stack.removeLast()
            text = ""
        }
    }
}
