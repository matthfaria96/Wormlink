import CryptoKit
import Foundation

// Recursos avançados do S3 (aba S3 do Info do Cyberduck): URLs assinadas, ACL, classe de armazenamento,
// criptografia, metadados, versões, opções do bucket, ciclo de vida e CloudFront.

/// ACLs prontas ("canned") do S3.
public enum S3CannedACL: String, CaseIterable, Sendable {
    case `private` = "private"
    case publicRead = "public-read"
    case publicReadWrite = "public-read-write"
    case authenticatedRead = "authenticated-read"
    case bucketOwnerFullControl = "bucket-owner-full-control"

    public var title: String {
        switch self {
        case .private: "Privado"
        case .publicRead: "Leitura pública"
        case .publicReadWrite: "Leitura e gravação públicas"
        case .authenticatedRead: "Leitura por usuários AWS"
        case .bucketOwnerFullControl: "Controle total do dono do bucket"
        }
    }

    /// Lê as concessões (`Grant`) de um GET ?acl e devolve a ACL pronta equivalente.
    static func from(grants: [[String: String]]) -> S3CannedACL {
        let allUsers = grants.filter { $0["URI"]?.hasSuffix("/global/AllUsers") == true }.compactMap { $0["Permission"] }
        let authenticated = grants.filter { $0["URI"]?.hasSuffix("/global/AuthenticatedUsers") == true }.compactMap { $0["Permission"] }
        if allUsers.contains("WRITE") || allUsers.contains("FULL_CONTROL") { return .publicReadWrite }
        if allUsers.contains("READ") { return .publicRead }
        if authenticated.contains("READ") { return .authenticatedRead }
        return .private
    }
}

public enum S3StorageClass {
    public static let all: [(id: String, title: String)] = [
        ("STANDARD", "Padrão"), ("INTELLIGENT_TIERING", "Inteligente"), ("STANDARD_IA", "Infrequente"),
        ("ONEZONE_IA", "Infrequente, 1 zona"), ("GLACIER_IR", "Glacier Instantâneo"),
        ("GLACIER", "Glacier Flexível"), ("DEEP_ARCHIVE", "Glacier Profundo"), ("REDUCED_REDUNDANCY", "Redundância reduzida"),
    ]

    public static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? id }
}

public enum S3Encryption {
    public static let all: [(id: String, title: String)] = [("", "Nenhuma"), ("AES256", "AES-256"), ("aws:kms", "AWS KMS")]
}

public struct S3ObjectInfo: Sendable, Equatable {
    public var storageClass = "STANDARD"
    public var encryption: String?
    public var kmsKeyID: String?
    public var contentType: String?
    public var cacheControl: String?
    public var versionID: String?
    public var etag: String?
    /// Metadados do usuário (x-amz-meta-*), sem o prefixo.
    public var metadata: [String: String] = [:]
    public var acl: S3CannedACL?
}

public struct S3Version: Identifiable, Sendable, Hashable {
    public var id: String { versionID }
    public let versionID: String
    public let isLatest: Bool
    public let isDeleteMarker: Bool
    public let modified: Date?
    public let size: Int64?
}

public struct S3BucketOptions: Sendable, Equatable {
    /// "Enabled", "Suspended" ou nil (nunca ligado).
    public var versioning: String?
    public var requesterPays = false
    /// "Enabled", "Suspended" ou nil. Só existe na AWS.
    public var acceleration: String?
    public var lifecycle = S3Lifecycle()
}

/// A regra de ciclo de vida que o Wormlink administra (como o Cyberduck): mover para outra classe e/ou apagar depois de N dias.
public struct S3Lifecycle: Sendable, Equatable {
    public var transitionDays: Int?
    public var transitionClass = "GLACIER"
    public var expirationDays: Int?
    public init(transitionDays: Int? = nil, transitionClass: String = "GLACIER", expirationDays: Int? = nil) {
        self.transitionDays = transitionDays
        self.transitionClass = transitionClass
        self.expirationDays = expirationDays
    }
    public var isEmpty: Bool { transitionDays == nil && expirationDays == nil }
}

public struct CloudFrontDistribution: Identifiable, Sendable, Hashable {
    public let id: String
    public let domainName: String
    public let status: String
    public let enabled: Bool
    public let origin: String
    public let aliases: [String]
}

extension S3FileSystem {
    // MARK: URLs assinadas

    /// Link temporário para baixar sem credenciais (até 7 dias, o máximo da SigV4).
    public func presignedURL(_ path: String, expires: TimeInterval) async throws -> URL {
        guard let (bucket, key) = split(path), !key.isEmpty else { throw WormlinkError.unsupportedOperation("Assinar uma pasta") }
        let region = try await region(of: bucket)
        let seconds = Int(min(max(expires, 1), 604_800))
        return try await credentials.current().presign(url(bucket: bucket, key: key, region: region), region: region, expires: seconds)
    }

    // MARK: Objeto

    public func objectInfo(_ path: String) async throws -> S3ObjectInfo {
        guard let (bucket, key) = split(path), !key.isEmpty else { throw WormlinkError.notFound(path) }
        let (_, response) = try await send("HEAD", bucket: bucket, key: key)
        var info = S3ObjectInfo()
        info.storageClass = response.value(forHTTPHeaderField: "x-amz-storage-class") ?? "STANDARD"
        info.encryption = response.value(forHTTPHeaderField: "x-amz-server-side-encryption")
        info.kmsKeyID = response.value(forHTTPHeaderField: "x-amz-server-side-encryption-aws-kms-key-id")
        info.contentType = response.value(forHTTPHeaderField: "Content-Type")
        info.cacheControl = response.value(forHTTPHeaderField: "Cache-Control")
        info.versionID = response.value(forHTTPHeaderField: "x-amz-version-id")
        info.etag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        for (name, value) in response.allHeaderFields {
            guard let name = (name as? String)?.lowercased(), name.hasPrefix("x-amz-meta-") else { continue }
            info.metadata[String(name.dropFirst("x-amz-meta-".count))] = "\(value)"
        }
        // Nem todo compatível tem ACL (R2, B2…): sem ela, fica nil.
        if let (data, _) = try? await send("GET", bucket: bucket, key: key, query: ["acl": ""]) {
            info.acl = S3CannedACL.from(grants: S3XML.groups(S3XML.parse(data), named: "Grant"))
        }
        return info
    }

    public func setACL(_ path: String, _ acl: S3CannedACL) async throws {
        guard let (bucket, key) = split(path) else { return }
        try await send("PUT", bucket: bucket, key: key, query: ["acl": ""], headers: ["x-amz-acl": acl.rawValue])
    }

    /// Classe, criptografia, tipo, cache e metadados mudam copiando o objeto sobre ele mesmo (REPLACE).
    public func update(_ path: String, _ info: S3ObjectInfo) async throws {
        guard let (bucket, key) = split(path), !key.isEmpty else { return }
        var headers = ["x-amz-copy-source": "/\(bucket)/\(S3Signer.encode(key, keepSlash: true))",
                       "x-amz-metadata-directive": "REPLACE", "x-amz-storage-class": info.storageClass]
        if let encryption = info.encryption, !encryption.isEmpty {
            headers["x-amz-server-side-encryption"] = encryption
            if encryption == "aws:kms", let kms = info.kmsKeyID, !kms.isEmpty { headers["x-amz-server-side-encryption-aws-kms-key-id"] = kms }
        }
        if let type = info.contentType, !type.isEmpty { headers["Content-Type"] = type }
        if let cache = info.cacheControl, !cache.isEmpty { headers["Cache-Control"] = cache }
        for (name, value) in info.metadata where !name.isEmpty { headers["x-amz-meta-" + name.lowercased()] = value }
        try await send("PUT", bucket: bucket, key: key, headers: headers)
    }

    // MARK: Versões

    public func versions(_ path: String) async throws -> [S3Version] {
        guard let (bucket, key) = split(path), !key.isEmpty else { return [] }
        let (data, _) = try await send("GET", bucket: bucket, query: ["versions": "", "prefix": key])
        let dates = S3Signer.formatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
        let nodes = S3XML.parse(data)
        func read(_ group: String, deleted: Bool) -> [S3Version] {
            S3XML.groups(nodes, named: group).compactMap { entry in
                guard entry["Key"] == key, let id = entry["VersionId"] else { return nil }
                return S3Version(versionID: id, isLatest: entry["IsLatest"] == "true", isDeleteMarker: deleted,
                                 modified: entry["LastModified"].flatMap(dates.date(from:)), size: entry["Size"].flatMap(Int64.init))
            }
        }
        return (read("Version", deleted: false) + read("DeleteMarker", deleted: true))
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Baixa uma versão antiga.
    public func download(_ path: String, version: String, to local: URL) async throws {
        guard let (bucket, key) = split(path) else { throw WormlinkError.notFound(path) }
        let (data, _) = try await send("GET", bucket: bucket, key: key, query: ["versionId": version])
        try data.write(to: local, options: .atomic)
    }

    /// Torna uma versão antiga a atual (cópia dela sobre a chave, como o "Reverter" do Cyberduck).
    public func restore(_ path: String, version: String) async throws {
        guard let (bucket, key) = split(path) else { return }
        try await send("PUT", bucket: bucket, key: key,
                       headers: ["x-amz-copy-source": "/\(bucket)/\(S3Signer.encode(key, keepSlash: true))?versionId=\(version)"])
    }

    public func deleteVersion(_ path: String, version: String) async throws {
        guard let (bucket, key) = split(path) else { return }
        try await send("DELETE", bucket: bucket, key: key, query: ["versionId": version])
    }

    // MARK: Bucket

    public func bucketOptions(_ bucket: String) async throws -> S3BucketOptions {
        var options = S3BucketOptions()
        if let (data, _) = try? await send("GET", bucket: bucket, query: ["versioning": ""]) {
            options.versioning = S3XML.parse(data).first { $0.name == "Status" }?.text
        }
        if let (data, _) = try? await send("GET", bucket: bucket, query: ["requestPayment": ""]) {
            options.requesterPays = S3XML.parse(data).first { $0.name == "Payer" }?.text == "Requester"
        }
        if isAWS, let (data, _) = try? await send("GET", bucket: bucket, query: ["accelerate": ""]) {
            options.acceleration = S3XML.parse(data).first { $0.name == "Status" }?.text
        }
        if let (data, _) = try? await send("GET", bucket: bucket, query: ["lifecycle": ""]) {
            options.lifecycle = Self.lifecycle(from: S3XML.parse(data))
        }
        return options
    }

    public func setVersioning(_ bucket: String, enabled: Bool) async throws {
        let body = "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Status>\(enabled ? "Enabled" : "Suspended")</Status></VersioningConfiguration>"
        try await sendXML("PUT", bucket: bucket, query: ["versioning": ""], body)
    }

    public func setRequesterPays(_ bucket: String, enabled: Bool) async throws {
        let body = "<RequestPaymentConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Payer>\(enabled ? "Requester" : "BucketOwner")</Payer></RequestPaymentConfiguration>"
        try await sendXML("PUT", bucket: bucket, query: ["requestPayment": ""], body)
    }

    public func setAcceleration(_ bucket: String, enabled: Bool) async throws {
        let body = "<AccelerateConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Status>\(enabled ? "Enabled" : "Suspended")</Status></AccelerateConfiguration>"
        try await sendXML("PUT", bucket: bucket, query: ["accelerate": ""], body)
    }

    public func setLifecycle(_ bucket: String, _ lifecycle: S3Lifecycle) async throws {
        guard !lifecycle.isEmpty else {
            try await send("DELETE", bucket: bucket, query: ["lifecycle": ""])
            return
        }
        var rule = "<Rule><ID>Wormlink</ID><Filter><Prefix></Prefix></Filter><Status>Enabled</Status>"
        if let days = lifecycle.transitionDays {
            rule += "<Transition><Days>\(days)</Days><StorageClass>\(S3XML.escape(lifecycle.transitionClass))</StorageClass></Transition>"
        }
        if let days = lifecycle.expirationDays { rule += "<Expiration><Days>\(days)</Days></Expiration>" }
        rule += "</Rule>"
        try await sendXML("PUT", bucket: bucket, query: ["lifecycle": ""],
                          "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(rule)</LifecycleConfiguration>")
    }

    /// A primeira regra ativa: dias e classe da transição, dias da expiração.
    static func lifecycle(from nodes: [S3XML.Node]) -> S3Lifecycle {
        var result = S3Lifecycle()
        for node in nodes {
            if node.path.hasSuffix("Rule/Transition/Days"), result.transitionDays == nil { result.transitionDays = Int(node.text) }
            if node.path.hasSuffix("Rule/Transition/StorageClass") { result.transitionClass = node.text }
            if node.path.hasSuffix("Rule/Expiration/Days"), result.expirationDays == nil { result.expirationDays = Int(node.text) }
        }
        return result
    }

    private func sendXML(_ method: String, bucket: String, query: [String: String], _ xml: String) async throws {
        let body = Data(xml.utf8)
        let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        try await send(method, bucket: bucket, query: query, body: body, headers: ["Content-MD5": md5, "Content-Type": "application/xml"])
    }

    // MARK: CloudFront

    static let cloudFrontVersion = "2020-05-31"

    /// API do CloudFront (global, assinada em us-east-1). Em provedores locais de teste, o mesmo endereço do S3.
    private func cloudFront(_ method: String, _ path: String, query: [String: String] = [:], body: String? = nil,
                            headers: [String: String] = [:], expect: Set<Int> = [200, 201]) async throws -> (Data, HTTPURLResponse) {
        var c = URLComponents()
        if isAWS {
            c.scheme = "https"
            c.host = "cloudfront.amazonaws.com"
        } else {
            let base = url(bucket: nil, region: "us-east-1")
            c.scheme = base.scheme
            c.host = base.host()
            c.port = base.port
        }
        c.path = "/\(Self.cloudFrontVersion)/" + path
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: c.url!)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let data = body.map { Data($0.utf8) }
        if let data { request.httpBody = data; request.setValue("application/xml", forHTTPHeaderField: "Content-Type") }
        var signer = try await credentials.current()
        signer.service = "cloudfront"
        signer.sign(&request, region: "us-east-1", payloadHash: S3Signer.sha256Hex(data ?? Data()))
        let (result, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        Transcript.log(title, "CloudFront \(method) \(path) → \(http.statusCode)")
        guard expect.contains(http.statusCode) else { throw Self.error(http.statusCode, result) }
        return (result, http)
    }

    /// Origem S3 de um bucket (o CloudFront só aceita buckets da AWS como origem S3).
    func originDomain(_ bucket: String) -> String { "\(bucket).s3.amazonaws.com" }

    /// Distribuições cuja origem é o bucket.
    public func distributions(for bucket: String) async throws -> [CloudFrontDistribution] {
        let (data, _) = try await cloudFront("GET", "distribution")
        let nodes = S3XML.parse(data)
        var result: [CloudFrontDistribution] = []
        var current: [S3XML.Node] = []
        func flush() {
            guard !current.isEmpty else { return }
            func value(_ suffix: String) -> String? { current.first { $0.path.hasSuffix(suffix) }?.text }
            let origins = current.filter { $0.path.hasSuffix("Origins/Items/Origin/DomainName") }.map(\.text)
            if let id = value("DistributionSummary/Id"), let origin = origins.first(where: { $0.hasPrefix(bucket + ".") }) {
                result.append(CloudFrontDistribution(
                    id: id, domainName: value("DistributionSummary/DomainName") ?? "", status: value("DistributionSummary/Status") ?? "",
                    enabled: value("DistributionSummary/Enabled") == "true", origin: origin,
                    aliases: current.filter { $0.path.hasSuffix("Aliases/Items/CNAME") }.map(\.text)))
            }
            current = []
        }
        for node in nodes {
            if node.name == "DistributionSummary" { flush(); current = [node]; continue }
            if !current.isEmpty { current.append(node) }
        }
        flush()
        return result
    }

    /// Cria uma distribuição simples (HTTPS, cache padrão) para o bucket.
    @discardableResult
    public func createDistribution(for bucket: String, comment: String = "Criada pelo Wormlink") async throws -> CloudFrontDistribution {
        let origin = originDomain(bucket)
        let reference = "wormlink-\(UUID().uuidString)"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DistributionConfig xmlns="http://cloudfront.amazonaws.com/doc/\(Self.cloudFrontVersion)/">
          <CallerReference>\(reference)</CallerReference>
          <Aliases><Quantity>0</Quantity></Aliases>
          <DefaultRootObject>index.html</DefaultRootObject>
          <Origins><Quantity>1</Quantity><Items><Origin>
            <Id>\(S3XML.escape(origin))</Id><DomainName>\(S3XML.escape(origin))</DomainName>
            <S3OriginConfig><OriginAccessIdentity></OriginAccessIdentity></S3OriginConfig>
          </Origin></Items></Origins>
          <DefaultCacheBehavior>
            <TargetOriginId>\(S3XML.escape(origin))</TargetOriginId>
            <ViewerProtocolPolicy>redirect-to-https</ViewerProtocolPolicy>
            <CachePolicyId>658327ea-f89d-4fab-a63d-7e88639e58f6</CachePolicyId>
          </DefaultCacheBehavior>
          <Comment>\(S3XML.escape(comment))</Comment>
          <Enabled>true</Enabled>
        </DistributionConfig>
        """
        let (data, _) = try await cloudFront("POST", "distribution", body: xml)
        let nodes = S3XML.parse(data)
        // Filhos diretos da raiz (<Distribution> na AWS; alguns emuladores usam outro nome).
        func value(_ name: String) -> String? { nodes.first { $0.name == name && $0.path.split(separator: "/").count == 2 }?.text }
        guard let id = value("Id") else { throw WormlinkError.invalidResponse }
        return CloudFrontDistribution(id: id, domainName: value("DomainName") ?? "", status: value("Status") ?? "",
                                      enabled: true, origin: origin, aliases: [])
    }

    /// Liga ou desliga uma distribuição (lê a configuração com o ETag e devolve com Enabled trocado).
    public func setDistribution(_ id: String, enabled: Bool) async throws {
        let (data, response) = try await cloudFront("GET", "distribution/\(id)/config")
        guard let etag = response.value(forHTTPHeaderField: "ETag"), var xml = String(data: data, encoding: .utf8) else {
            throw WormlinkError.invalidResponse
        }
        xml = xml.replacingOccurrences(of: #"<Enabled>(true|false)</Enabled>(?![\s\S]*<Enabled>)"#,
                                       with: "<Enabled>\(enabled)</Enabled>", options: .regularExpression)
        try await cloudFront("PUT", "distribution/\(id)/config", body: xml, headers: ["If-Match": etag])
    }

    /// Invalida caminhos no cache da distribuição ("/pasta/*", "/arquivo.html"…). Devolve o id da invalidação.
    @discardableResult
    public func invalidate(_ id: String, paths: [String]) async throws -> String {
        let items = paths.map { "<Path>\(S3XML.escape($0.hasPrefix("/") ? $0 : "/" + $0))</Path>" }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <InvalidationBatch xmlns="http://cloudfront.amazonaws.com/doc/\(Self.cloudFrontVersion)/">
          <Paths><Quantity>\(paths.count)</Quantity><Items>\(items)</Items></Paths>
          <CallerReference>wormlink-\(UUID().uuidString)</CallerReference>
        </InvalidationBatch>
        """
        let (data, _) = try await cloudFront("POST", "distribution/\(id)/invalidation", body: xml)
        return S3XML.parse(data).first { $0.path.hasSuffix("Invalidation/Id") }?.text ?? ""
    }

    /// Caminho do objeto dentro da distribuição (sem o bucket).
    public func distributionPath(_ path: String) -> String {
        guard let (_, key) = split(path) else { return "/" }
        return "/" + key
    }

    // MARK: Tipo de conteúdo

    /// Content-Type pela extensão, para o navegador abrir os arquivos (HTML, imagens…) em vez de baixar.
    static func contentType(_ key: String) -> String? {
        let ext = (key as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return mimeTypes[ext]
    }

    static let mimeTypes: [String: String] = [
        "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "xml": "application/xml", "txt": "text/plain", "md": "text/markdown", "csv": "text/csv",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "ico": "image/x-icon", "avif": "image/avif", "heic": "image/heic",
        "pdf": "application/pdf", "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar",
        "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm", "mp3": "audio/mpeg", "m4a": "audio/mp4",
        "wav": "audio/wav", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "wasm": "application/wasm",
    ]
}

extension S3Signer {
    /// URL pré-assinada (SigV4 na query string).
    func presign(_ url: URL, method: String = "GET", region: String, expires: Int, date: Date = Date()) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = url.host() else { return url }
        let stamp = Self.formatter("yyyyMMdd'T'HHmmss'Z'").string(from: date)
        let day = String(stamp.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        var pairs: [(String, String)] = (components.percentEncodedQueryItems ?? []).map {
            (Self.encode($0.name.removingPercentEncoding ?? $0.name), Self.encode(($0.value ?? "").removingPercentEncoding ?? ""))
        }
        var auth = [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(accessKey)/\(scope)"),
                    ("X-Amz-Date", stamp), ("X-Amz-Expires", String(expires)), ("X-Amz-SignedHeaders", "host")]
        if let sessionToken { auth.append(("X-Amz-Security-Token", sessionToken)) }
        pairs += auth.map { (Self.encode($0.0), Self.encode($0.1)) }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let query = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let canonical = [method, path, query, "host:\(hostHeader)\n", "host", Self.unsignedPayload].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        var key = hmac(Data("AWS4\(secretKey)".utf8), day)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()
        components.percentEncodedQuery = query + "&X-Amz-Signature=" + signature
        return components.url ?? url
    }
}
