import CryptoKit
import Foundation
import Network

/// Configuração OAuth 2 de um provedor de nuvem. O Client ID é do app que o usuário cadastrou.
public struct OAuthProvider: Sendable {
    public let name: String
    public let authorizeURL: URL
    public let tokenURL: URL
    public let scopes: [String]
    public let extraAuthorizeParameters: [String: String]
    public let defaultsKey: String

    public static let redirectPort: UInt16 = 53682
    public static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/" }

    /// Client ID (e segredo, quando o provedor exige) guardados em Ajustes › Nuvens.
    public var clientID: String { UserDefaults.standard.string(forKey: "oauth.\(defaultsKey).clientID")?.trimmingCharacters(in: .whitespaces) ?? "" }
    public var clientSecret: String? {
        UserDefaults.standard.string(forKey: "oauth.\(defaultsKey).clientSecret").flatMap { $0.isEmpty ? nil : $0 }
    }

    public static let dropbox = OAuthProvider(
        name: "Dropbox",
        authorizeURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
        tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
        scopes: ["files.metadata.read", "files.content.read", "files.content.write", "account_info.read",
                 "sharing.read", "sharing.write"],
        extraAuthorizeParameters: ["token_access_type": "offline"],
        defaultsKey: "dropbox")

    public static let googleDrive = OAuthProvider(
        name: "Google Drive",
        authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        scopes: ["https://www.googleapis.com/auth/drive"],
        extraAuthorizeParameters: ["access_type": "offline", "prompt": "consent"],
        defaultsKey: "google")

    /// Box exige o segredo do app na troca do código.
    public static let box = OAuthProvider(
        name: "Box",
        authorizeURL: URL(string: "https://account.box.com/api/oauth2/authorize")!,
        tokenURL: URL(string: "https://api.box.com/oauth2/token")!,
        scopes: ["root_readwrite"],
        extraAuthorizeParameters: [:],
        defaultsKey: "box")

    /// SharePoint usa o mesmo app do OneDrive, com acesso aos sites.
    public static let sharePoint = OAuthProvider(
        name: "SharePoint",
        authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        scopes: ["offline_access", "Files.ReadWrite.All", "Sites.ReadWrite.All", "User.Read"],
        extraAuthorizeParameters: [:],
        defaultsKey: "onedrive")

    public static let oneDrive = OAuthProvider(
        name: "OneDrive",
        authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        scopes: ["offline_access", "Files.ReadWrite.All", "User.Read"],
        extraAuthorizeParameters: [:],
        defaultsKey: "onedrive")
}

/// Tokens guardados no Chaves (no lugar da senha do favorito), em JSON.
public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expires: Date

    var isExpired: Bool { expires.timeIntervalSinceNow < 60 }

    static func decode(_ text: String?) -> OAuthTokens? {
        text.flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: Data($0.utf8)) }
    }

    var encoded: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
}

/// Abre o navegador para o login (fornecido pelo app).
public typealias BrowserOpener = @Sendable (URL) async -> Void

/// Fluxo "authorization code" com PKCE e retorno num servidor HTTP local de uma requisição só.
public enum OAuthFlow {
    public static func authorize(_ provider: OAuthProvider, open: BrowserOpener) async throws -> OAuthTokens {
        guard !provider.clientID.isEmpty else { throw WormlinkError.missingClientID(provider.name) }
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)
        var c = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var query = [
            "client_id": provider.clientID, "response_type": "code", "redirect_uri": OAuthProvider.redirectURI,
            "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
            "scope": provider.scopes.joined(separator: " "),
        ]
        provider.extraAuthorizeParameters.forEach { query[$0.key] = $0.value }
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        let receiver = try LoopbackReceiver(port: OAuthProvider.redirectPort)
        await open(c.url!)
        let params = try await receiver.waitForCallback(timeout: 300)
        guard params["state"] == state else { throw WormlinkError.server(status: 400, message: "Resposta de login inválida (state).") }
        guard let code = params["code"] else {
            throw WormlinkError.server(status: 401, message: params["error_description"] ?? params["error"] ?? "Login cancelado.")
        }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": OAuthProvider.redirectURI,
                    "client_id": provider.clientID, "code_verifier": verifier]
        if let secret = provider.clientSecret { form["client_secret"] = secret }
        return try await token(provider, form: form, previousRefresh: nil)
    }

    public static func refresh(_ provider: OAuthProvider, _ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = tokens.refreshToken else { throw WormlinkError.authenticationFailed }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": provider.clientID]
        if let secret = provider.clientSecret { form["client_secret"] = secret }
        if provider.defaultsKey == "onedrive" || provider.defaultsKey == "box" { form["scope"] = provider.scopes.joined(separator: " ") }
        return try await token(provider, form: form, previousRefresh: refresh)
    }

    private static func token(_ provider: OAuthProvider, form: [String: String], previousRefresh: String?) async throws -> OAuthTokens {
        var request = URLRequest(url: provider.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            if json["error"] as? String == "invalid_grant" { throw WormlinkError.authenticationFailed }
            throw WormlinkError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                       message: json["error_description"] as? String ?? json["error"] as? String ?? "Falha ao obter o token.")
        }
        let lifetime = (json["expires_in"] as? Double) ?? (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        return OAuthTokens(accessToken: access, refreshToken: json["refresh_token"] as? String ?? previousRefresh,
                           expires: Date().addingTimeInterval(lifetime))
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(generator.next() % UInt64(chars.count))] })
    }
}

/// Servidor HTTP mínimo em 127.0.0.1 que recebe o redirecionamento do login e responde uma página simples.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: .global())
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        defer { listener.cancel() }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finish(.failure(WormlinkError.timedOut))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let result { continuation.resume(with: result) } else { self.continuation = continuation }
            }
        }
    }

    private func finish(_ value: Result<[String: String], Error>) {
        let waiting: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: value)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /?code=…&state=… HTTP/1.1"
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            let params = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
            let ok = params["code"] != nil
            let body = """
            <html><head><meta charset="utf-8"><title>Wormlink</title></head>
            <body style="font-family:-apple-system;text-align:center;padding:60px">
            <h2>\(ok ? "Pronto! Pode voltar ao Wormlink." : "O login não foi concluído.")</h2></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if !params.isEmpty { self?.finish(.success(params)) }
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// Requisições autenticadas com renovação automática do token (e gravação no Chaves).
actor CloudSession {
    let provider: OAuthProvider
    private var tokens: OAuthTokens
    private let bookmark: Bookmark
    let urlSession: URLSession
    let label: String

    init(provider: OAuthProvider, tokens: OAuthTokens, bookmark: Bookmark) {
        self.provider = provider
        self.tokens = tokens
        self.bookmark = bookmark
        label = bookmark.displayName
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Wormlink/1.0"]
        WormlinkTesting.apply(config)
        urlSession = URLSession(configuration: config)
    }

    private func validToken() async throws -> String {
        if tokens.isExpired {
            tokens = try await OAuthFlow.refresh(provider, tokens)
            Keychain.setPassword(tokens.encoded, for: bookmark)
        }
        return tokens.accessToken
    }

    /// Envia a requisição com o token; num 401 renova uma vez e repete.
    func send(_ request: URLRequest, body: Data? = nil, file: URL? = nil,
              delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            var r = request
            r.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            let (data, response): (Data, URLResponse)
            if let file, r.useThrottledBody(from: file) {
                let reporter = delegate as? CloudUploadProgress
                (data, response) = try await urlSession.data(for: r, delegate: StreamUpload(file: file, progress: { reporter?.report($0) }))
            } else if let file {
                (data, response) = try await urlSession.upload(for: r, fromFile: file, delegate: delegate)
            } else if let body {
                await BandwidthLimiter.shared.throttle(body.count, .upload)
                (data, response) = try await urlSession.upload(for: r, from: body, delegate: delegate)
            } else {
                (data, response) = try await urlSession.data(for: r, delegate: delegate)
            }
            let http = response as! HTTPURLResponse
            Transcript.log(label, "\(r.httpMethod ?? "GET") \(r.url?.path(percentEncoded: false) ?? "") → \(http.statusCode)")
            if http.statusCode == 401 && attempt == 0 {
                tokens.expires = .distantPast
                continue
            }
            return (data, http)
        }
        throw WormlinkError.authenticationFailed
    }

    /// Baixa em fluxo para um arquivo local, com Range para retomar.
    func download(_ request: URLRequest, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var r = request
        r.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if offset > 0 { r.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await urlSession.bytes(for: r)
        let http = response as! HTTPURLResponse
        Transcript.log(label, "GET \(r.url?.path(percentEncoded: false) ?? "") → \(http.statusCode)")
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw WormlinkError.server(status: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
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
}

/// Lê JSON de resposta, transformando erros HTTP em `WormlinkError`.
func cloudJSON(_ data: Data, _ response: HTTPURLResponse, expect: Set<Int> = [200, 201]) throws -> [String: Any] {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard expect.contains(response.statusCode) else {
        let message = (json["error_summary"] as? String)
            ?? ((json["error"] as? [String: Any])?["message"] as? String)
            ?? (json["error"] as? String)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        if response.statusCode == 404 || message.contains("not_found") { throw WormlinkError.notFound(message) }
        if response.statusCode == 401 { throw WormlinkError.authenticationFailed }
        throw WormlinkError.server(status: response.statusCode, message: message)
    }
    return json
}

/// Progresso de envio vindo do URLSession.
final class CloudUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let base: Int64
    let report: @Sendable (Int64) -> Void
    init(base: Int64 = 0, _ report: @escaping @Sendable (Int64) -> Void) { self.base = base; self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { report(base + totalBytesSent) }
}

func parseISODate(_ text: String?) -> Date? {
    guard let text else { return nil }
    return (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
}
