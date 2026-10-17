import Foundation

/// Sistemas que criam um link público de compartilhamento ("Copiar Link Compartilhado" do Cyberduck).
public protocol SharesLinks: Sendable {
    /// Cria (ou reaproveita) um link de leitura para o arquivo ou pasta.
    func sharedLink(_ path: String) async throws -> URL
}

/// Só para testes: classes de URLProtocol injetadas nas sessões HTTP das nuvens e do WebDAV.
public enum WormlinkTesting {
    nonisolated(unsafe) public static var protocolClasses: [AnyClass]?

    static func apply(_ config: URLSessionConfiguration) {
        if let protocolClasses { config.protocolClasses = protocolClasses + (config.protocolClasses ?? []) }
    }
}

private func link(_ text: Any?) throws -> URL {
    guard let text = text as? String, let url = URL(string: text) else { throw WormlinkError.invalidResponse }
    return url
}

extension DropboxFileSystem: SharesLinks {
    /// create_shared_link_with_settings; se o link já existe (409), devolve o existente.
    public func sharedLink(_ path: String) async throws -> URL {
        let target = Self.dropboxPath(path)
        var request = URLRequest(url: Self.api.appending(path: "sharing/create_shared_link_with_settings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["path": target, "settings": ["requested_visibility": "public"]])
        let (data, response) = try await session.send(request, body: body)
        if response.statusCode == 409, String(decoding: data, as: UTF8.self).contains("shared_link_already_exists") {
            var list = URLRequest(url: Self.api.appending(path: "sharing/list_shared_links"))
            list.httpMethod = "POST"
            list.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (listData, listResponse) = try await session.send(list, body: try JSONSerialization.data(withJSONObject: ["path": target, "direct_only": true]))
            let links = try cloudJSON(listData, listResponse)["links"] as? [[String: Any]]
            return try link(links?.first?["url"])
        }
        return try link(try cloudJSON(data, response)["url"])
    }
}

extension GoogleDriveFileSystem: SharesLinks {
    /// Permissão "qualquer pessoa com o link pode ver" e o webViewLink do item.
    public func sharedLink(_ path: String) async throws -> URL {
        let id = try await id(for: path)
        var permission = URLRequest(url: Self.api.appending(path: "files/\(id)/permissions"))
        permission.httpMethod = "POST"
        permission.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.send(permission, body: try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"]))
        _ = try cloudJSON(data, response)
        var c = URLComponents(url: Self.api.appending(path: "files/\(id)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "fields", value: "webViewLink")]
        let (fileData, fileResponse) = try await session.send(URLRequest(url: c.url!))
        return try link(try cloudJSON(fileData, fileResponse)["webViewLink"])
    }
}

extension OneDriveFileSystem: SharesLinks {
    /// createLink anônimo; contas corporativas que proíbem links anônimos recebem um link da organização.
    public func sharedLink(_ path: String) async throws -> URL {
        for scope in ["anonymous", "organization"] {
            var request = URLRequest(url: itemURL(path, suffix: "createLink"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.send(request, body: try JSONSerialization.data(withJSONObject: ["type": "view", "scope": scope]))
            if scope == "anonymous", [400, 403].contains(response.statusCode) { continue }
            let json = try cloudJSON(data, response)
            return try link((json["link"] as? [String: Any])?["webUrl"])
        }
        throw WormlinkError.invalidResponse
    }
}

extension BoxFileSystem: SharesLinks {
    /// shared_link com acesso "open" (qualquer pessoa com o link).
    public func sharedLink(_ path: String) async throws -> URL {
        let entry = try await entry(for: path)
        var c = URLComponents(url: Self.api.appending(path: (entry.isFolder ? "folders/" : "files/") + entry.id), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "fields", value: "shared_link")]
        var request = URLRequest(url: c.url!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.send(request, body: try JSONSerialization.data(withJSONObject: ["shared_link": ["access": "open"]]))
        return try link((try cloudJSON(data, response)["shared_link"] as? [String: Any])?["url"])
    }
}

extension WebDAVFileSystem: SharesLinks {
    /// Caminho dentro da conta no Nextcloud/ownCloud ("/remote.php/dav/files/ana/Fotos" → "/Fotos"), ou nil.
    static func nextcloudPath(_ path: String) -> String? {
        let p = RemotePath.normalize(path)
        let parts = p.split(separator: "/").map(String.init)
        if parts.count >= 4, parts[0] == "remote.php", parts[1] == "dav", parts[2] == "files" {
            return "/" + parts.dropFirst(4).joined(separator: "/")
        }
        if parts.count >= 2, parts[0] == "remote.php", parts[1] == "webdav" {
            return "/" + parts.dropFirst(2).joined(separator: "/")
        }
        return nil
    }

    /// Só Nextcloud e ownCloud têm API de compartilhamento (OCS).
    public var canShareLinks: Bool { Self.nextcloudPath(homePath) != nil }

    /// OCS Share API: compartilhamento público (shareType 3).
    public func sharedLink(_ path: String) async throws -> URL {
        guard let inside = Self.nextcloudPath(path) else {
            throw WormlinkError.unsupportedOperation("Links compartilhados (só Nextcloud e ownCloud)")
        }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = "/ocs/v2.php/apps/files_sharing/api/v1/shares"
        c.queryItems = [URLQueryItem(name: "format", value: "json")]
        var request = URLRequest(url: c.url!)
        request.httpMethod = "POST"
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "path", value: inside.isEmpty ? "/" : inside), URLQueryItem(name: "shareType", value: "3"),
                           URLQueryItem(name: "permissions", value: "1")]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        Transcript.log(title, "POST OCS share \(inside) → \(http.statusCode)")
        let json = try cloudJSON(data, http, expect: [200])
        let ocs = json["ocs"] as? [String: Any]
        if let meta = ocs?["meta"] as? [String: Any], let code = (meta["statuscode"] as? NSNumber)?.intValue, code != 200, code != 100 {
            throw WormlinkError.server(status: code, message: meta["message"] as? String ?? "Compartilhamento recusado")
        }
        return try link((ocs?["data"] as? [String: Any])?["url"])
    }
}
