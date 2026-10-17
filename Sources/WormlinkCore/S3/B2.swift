import Foundation

/// Backblaze B2: o login nativo (b2_authorize_account) informa o endpoint S3 da região da conta;
/// daí em diante tudo passa pela API compatível com S3, já testada.
enum B2 {
    static func connect(_ bookmark: Bookmark, applicationKey: String, trust: ConnectionTrust) async throws -> S3FileSystem {
        var request = URLRequest(url: URL(string: "https://api.backblazeb2.com/b2api/v3/b2_authorize_account")!)
        let basic = Data("\(bookmark.username):\(applicationKey)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Transcript.log(bookmark.displayName, "b2_authorize_account → \(status)")
        guard status == 200 else { throw status == 401 ? WormlinkError.authenticationFailed : WormlinkError.invalidResponse }
        guard let endpoint = s3Endpoint(fromAuthorization: data) else { throw WormlinkError.invalidResponse }
        let credentials = AWSCredentials(signer: S3Signer(accessKey: bookmark.username, secretKey: applicationKey))
        return try S3FileSystem(bookmark: bookmark, credentials: credentials, endpoint: endpoint)
    }

    /// "https://s3.us-west-004.backblazeb2.com" → "s3.us-west-004.backblazeb2.com" (v3 e v2 da resposta).
    static func s3Endpoint(fromAuthorization data: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let storage = ((json["apiInfo"] as? [String: Any])?["storageApi"] as? [String: Any]) ?? json
        return (storage["s3ApiUrl"] as? String).flatMap { URL(string: $0)?.host() }
    }
}
