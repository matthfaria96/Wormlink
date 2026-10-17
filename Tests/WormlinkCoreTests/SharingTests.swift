import Foundation
import Testing
@testable import WormlinkCore

/// Respostas falsas para as APIs das nuvens. Só intercepta os hosts abaixo; o resto segue para a rede.
final class CloudStub: URLProtocol, @unchecked Sendable {
    struct Call { let method: String; let url: URL; let body: String; let headers: [String: String] }
    static let hosts: Set<String> = ["api.dropboxapi.com", "www.googleapis.com", "graph.microsoft.com", "api.box.com", "nuvem.exemplo"]
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var calls: [Call] = []
    static let lock = NSLock()

    static func route(_ method: String, _ path: String, _ status: Int, _ json: String) {
        lock.withLock { routes["\(method) \(path)"] = (status, json) }
    }

    static func calls(to path: String) -> [Call] { lock.withLock { calls.filter { $0.url.path == path } } }

    override class func canInit(with request: URLRequest) -> Bool { hosts.contains(request.url?.host() ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let url = request.url!
        let (status, json) = Self.lock.withLock { () -> (Int, String) in
            Self.calls.append(Call(method: request.httpMethod ?? "GET", url: url, body: String(decoding: body, as: UTF8.self),
                                   headers: request.allHTTPHeaderFields ?? [:]))
            return Self.routes["\(request.httpMethod ?? "GET") \(url.path)"] ?? (404, "{}")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let stubInstalled: Void = { WormlinkTesting.protocolClasses = [CloudStub.self] }()

private func session(_ provider: OAuthProvider) -> CloudSession {
    _ = stubInstalled
    return CloudSession(provider: provider, tokens: OAuthTokens(accessToken: "tok", refreshToken: nil, expires: .distantFuture),
                        bookmark: Bookmark(nickname: "Nuvem"))
}

@Test func dropboxSharedLinkCreatesOrReuses() async throws {
    let fs = DropboxFileSystem(bookmark: Bookmark(connectionProtocol: .dropbox), session: session(.dropbox))
    CloudStub.route("POST", "/2/sharing/create_shared_link_with_settings", 200, #"{"url":"https://www.dropbox.com/s/novo/a.pdf?dl=0"}"#)
    #expect(try await fs.sharedLink("/Docs/a.pdf").absoluteString == "https://www.dropbox.com/s/novo/a.pdf?dl=0")
    let call = try #require(CloudStub.calls(to: "/2/sharing/create_shared_link_with_settings").last)
    #expect(call.body.contains("\"path\":\"\\/Docs\\/a.pdf\"") && call.headers["Authorization"] == "Bearer tok")

    CloudStub.route("POST", "/2/sharing/create_shared_link_with_settings", 409,
                    #"{"error_summary":"shared_link_already_exists/..","error":{".tag":"shared_link_already_exists"}}"#)
    CloudStub.route("POST", "/2/sharing/list_shared_links", 200, #"{"links":[{"url":"https://www.dropbox.com/s/antigo/a.pdf?dl=0"}]}"#)
    #expect(try await fs.sharedLink("/Docs/a.pdf").absoluteString == "https://www.dropbox.com/s/antigo/a.pdf?dl=0")
}

@Test func googleDriveSharedLink() async throws {
    let fs = GoogleDriveFileSystem(bookmark: Bookmark(connectionProtocol: .googleDrive), session: session(.googleDrive))
    CloudStub.route("GET", "/drive/v3/files", 200, #"{"files":[{"id":"ID123","name":"Relatorio.pdf","mimeType":"application/pdf"}]}"#)
    CloudStub.route("POST", "/drive/v3/files/ID123/permissions", 200, #"{"id":"anyoneWithLink"}"#)
    CloudStub.route("GET", "/drive/v3/files/ID123", 200, #"{"webViewLink":"https://drive.google.com/file/d/ID123/view"}"#)
    #expect(try await fs.sharedLink("/Relatorio.pdf").absoluteString == "https://drive.google.com/file/d/ID123/view")
    #expect(CloudStub.calls(to: "/drive/v3/files/ID123/permissions").last?.body.contains("anyone") == true)
}

@Test func oneDriveSharedLinkAnonymous() async throws {
    let fs = OneDriveFileSystem(bookmark: Bookmark(connectionProtocol: .oneDrive), session: session(.oneDrive), drive: "https://graph.microsoft.com/v1.0/drives/D1")
    let path = "/v1.0/drives/D1/root:/Equipe/plano.xlsx:/createLink"
    CloudStub.route("POST", path, 200, #"{"link":{"webUrl":"https://1drv.ms/x/abc"}}"#)
    #expect(try await fs.sharedLink("/Equipe/plano.xlsx").absoluteString == "https://1drv.ms/x/abc")
    #expect(CloudStub.calls(to: path).last?.body.contains("anonymous") == true)
}

@Test func boxSharedLinkForFolder() async throws {
    let fs = BoxFileSystem(bookmark: Bookmark(connectionProtocol: .box), session: session(.box))
    CloudStub.route("GET", "/2.0/folders/0/items", 200, #"{"total_count":1,"entries":[{"type":"folder","id":"77","name":"Projetos"}]}"#)
    CloudStub.route("PUT", "/2.0/folders/77", 200, #"{"shared_link":{"url":"https://app.box.com/s/xyz"}}"#)
    #expect(try await fs.sharedLink("/Projetos").absoluteString == "https://app.box.com/s/xyz")
    #expect(CloudStub.calls(to: "/2.0/folders/77").last?.body.contains("open") == true)
}

@Test func nextcloudSharedLinkViaOCS() async throws {
    _ = stubInstalled
    var bookmark = Bookmark(connectionProtocol: .webdavs, hostname: "nuvem.exemplo", username: "ana", path: "/remote.php/dav/files/ana")
    bookmark.preset = "nextcloud"
    let fs = try WebDAVFileSystem(bookmark: bookmark, password: "x")
    #expect(fs.canShareLinks)
    CloudStub.route("POST", "/ocs/v2.php/apps/files_sharing/api/v1/shares", 200,
                    #"{"ocs":{"meta":{"status":"ok","statuscode":200},"data":{"url":"https://nuvem.exemplo/s/AbC123"}}}"#)
    #expect(try await fs.sharedLink("/remote.php/dav/files/ana/Fotos/praia 1+1.jpg").absoluteString == "https://nuvem.exemplo/s/AbC123")
    let call = try #require(CloudStub.calls(to: "/ocs/v2.php/apps/files_sharing/api/v1/shares").last)
    #expect(call.body.contains("path=/Fotos/praia%201%2B1.jpg") && call.body.contains("shareType=3") && call.headers["OCS-APIRequest"] == "true")
    #expect(WebDAVFileSystem.nextcloudPath("/remote.php/webdav/a") == "/a" && WebDAVFileSystem.nextcloudPath("/dav/a") == nil)
}
