import Foundation

/// WebDAV (RFC 4918) sobre URLSession: PROPFIND, MKCOL, MOVE, DELETE, GET e PUT.
/// Autenticação Basic e Digest ficam a cargo do URLSession, via `URLCredential`.
public final class WebDAVFileSystem: FileSystem {
    public let title: String
    public let homePath: String
    let base: URL
    let session: URLSession

    public init(bookmark: Bookmark, password: String?, certificateTrust: @escaping CertificateTrust = { _ in false }) throws {
        var c = URLComponents()
        c.scheme = bookmark.connectionProtocol.scheme
        c.host = bookmark.hostname
        if bookmark.port != bookmark.connectionProtocol.defaultPort { c.port = bookmark.port }
        guard let base = c.url else { throw WormlinkError.invalidBookmark }
        self.base = base
        title = bookmark.displayName
        homePath = RemotePath.normalize(bookmark.path)
        let credential = bookmark.username.isEmpty ? nil
            : URLCredential(user: bookmark.username, password: password ?? "", persistence: .forSession)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let timeout = bookmark.timeout { config.timeoutIntervalForRequest = TimeInterval(timeout) }
        config.httpAdditionalHeaders = ["User-Agent": "Wormlink/1.0"]
        WormlinkTesting.apply(config)
        session = URLSession(configuration: config, delegate: AuthDelegate(credential: credential, certificateTrust: certificateTrust),
                             delegateQueue: nil)
    }

    // MARK: Operações

    public func list(_ path: String) async throws -> [FileItem] {
        let dir = RemotePath.normalize(path)
        var request = request(dir, method: "PROPFIND", directory: true)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>
            """.utf8)
        let (data, _) = try await perform(request, expect: [207])
        return PropfindParser.parse(data).filter { RemotePath.normalize($0.path) != dir }
    }

    public func createDirectory(_ path: String) async throws {
        _ = try await perform(request(path, method: "MKCOL", directory: true), expect: [201])
    }

    public func delete(_ item: FileItem) async throws {
        _ = try await perform(request(item.path, method: "DELETE", directory: item.isDirectory), expect: [200, 204])
    }

    public func move(_ path: String, to newPath: String) async throws {
        var r = request(path, method: "MOVE")
        r.setValue(url(for: newPath).absoluteString, forHTTPHeaderField: "Destination")
        r.setValue("F", forHTTPHeaderField: "Overwrite")
        _ = try await perform(r, expect: [201, 204])
    }

    public func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await download(path, to: local, offset: 0, progress: progress)
    }

    public var canResumeDownloads: Bool { true }   // Range; envios recomeçam do zero

    public func download(_ path: String, to local: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var r = request(path, method: "GET")
        if offset > 0 { r.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        Transcript.log(title, "GET \(path)" + (offset > 0 ? " Range: bytes=\(offset)-" : ""))
        let (bytes, response) = try await session.bytes(for: r)
        try check(response, expect: offset > 0 ? [200, 206] : [200], body: nil)
        let offset = (response as? HTTPURLResponse).map { LocalAppend.effectiveOffset(offset, $0) } ?? 0
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

    public func upload(_ local: URL, to path: String, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await upload(local, to: path, progress: progress)   // sem retomada de envio no WebDAV
    }

    public func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        Transcript.log(title, "PUT \(path)")
        var throttled = request(path, method: "PUT")
        if throttled.useThrottledBody(from: local) {
            let (data, response) = try await session.data(for: throttled, delegate: StreamUpload(file: local, progress: progress))
            try check(response, expect: [200, 201, 204], body: data)
            return
        }
        let (data, response) = try await session.upload(for: request(path, method: "PUT"), fromFile: local,
                                                        delegate: UploadProgress(progress))
        try check(response, expect: [200, 201, 204], body: data)
    }

    public func disconnect() async { session.invalidateAndCancel() }

    // MARK: HTTP

    private func url(for path: String, directory: Bool = false) -> URL {
        var p = RemotePath.normalize(path)
        if directory && p != "/" { p += "/" }
        return base.appending(path: p, directoryHint: directory ? .isDirectory : .notDirectory)
    }

    private func request(_ path: String, method: String, directory: Bool = false) -> URLRequest {
        var r = URLRequest(url: url(for: path, directory: directory))
        r.httpMethod = method
        return r
    }

    private func perform(_ request: URLRequest, expect: Set<Int>) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        Transcript.log(title, "\(request.httpMethod ?? "") \(request.url?.path(percentEncoded: false) ?? "") → \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        try check(response, expect: expect, body: data)
        return (data, response as! HTTPURLResponse)
    }

    private func check(_ response: URLResponse, expect: Set<Int>, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw WormlinkError.invalidResponse }
        guard !expect.contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401: throw WormlinkError.authenticationFailed
        case 404: throw WormlinkError.notFound(response.url?.path ?? "")
        default:
            throw WormlinkError.server(status: http.statusCode,
                                       message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }
}

// MARK: - Delegados

private final class AuthDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let credential: URLCredential?
    let certificateTrust: CertificateTrust
    init(credential: URLCredential?, certificateTrust: @escaping CertificateTrust) {
        self.credential = credential
        self.certificateTrust = certificateTrust
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            let ok = await CertificateTrustStore.check(chain: trust.derChain, host: challenge.protectionSpace.host,
                                                       trust: certificateTrust)
            return ok ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            // Uma tentativa só: senha errada vira erro 401 em vez de repetir para sempre.
            guard let credential, challenge.previousFailureCount == 0 else { return (.rejectProtectionSpace, nil) }
            return (.useCredential, credential)
        default:
            return (.performDefaultHandling, nil)
        }
    }
}

/// Envio com corpo em fluxo (limite de velocidade): recria o fluxo se a autenticação pedir para reenviar.
final class StreamUpload: NSObject, URLSessionTaskDelegate, Sendable {
    let file: URL
    let progress: @Sendable (Int64) -> Void
    init(file: URL, progress: @escaping @Sendable (Int64) -> Void) { self.file = file; self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(ThrottledFileStream(fileAt: file))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { progress(totalBytesSent) }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
}

// MARK: - PROPFIND

/// Lê a resposta `multistatus` de um PROPFIND.
enum PropfindParser {
    static func parse(_ data: Data) -> [FileItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [FileItem] = []
        private var text = ""
        private var href: String?
        private var isCollection = false
        private var size: Int64?
        private var modified: Date?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "response": href = nil; isCollection = false; size = nil; modified = nil
            case "collection": isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href": href = value
            case "getcontentlength": size = Int64(value)
            case "getlastmodified": modified = PropfindParser.httpDate.date(from: value)
            case "response":
                // `href` pode vir como caminho ou URL completa, sempre com escape de URL.
                guard let href, let raw = URL(string: href)?.path(percentEncoded: true) ?? Optional(href) else { break }
                let path = RemotePath.normalize(raw.removingPercentEncoding ?? raw)
                items.append(FileItem(path: path, isDirectory: isCollection, size: isCollection ? nil : size, modified: modified))
            default: break
            }
            text = ""
        }
    }
}
