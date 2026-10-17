import CryptoKit
import Foundation

/// Assinatura AWS Signature Version 4 para requisições S3.
struct S3Signer: Sendable {
    let accessKey: String
    let secretKey: String
    /// Credenciais temporárias (STS, SSO, perfis com sessão) trazem um token que também é assinado.
    var sessionToken: String?
    /// Serviço AWS da assinatura ("s3", "sts"…).
    var service = "s3"

    static let emptyHash = sha256Hex(Data())
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Codificação URI da AWS: só `A-Za-z0-9-._~` ficam como estão.
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Assina `request` (já com URL, método e cabeçalhos próprios) para a `region`.
    func sign(_ request: inout URLRequest, region: String, payloadHash: String, date: Date = Date()) {
        guard let url = request.url, let host = url.host() else { return }
        let stamp = Self.formatter("yyyyMMdd'T'HHmmss'Z'").string(from: date)
        let day = String(stamp.prefix(8))
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        if service == "s3" { request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256") }
        if let sessionToken { request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token") }

        var headers: [String: String] = ["host": hostHeader]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let k = key.lowercased()
            if k.hasPrefix("x-amz-") || k == "content-type" || k == "content-md5" || k == "range" {
                headers[k] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalHeaders = headers.keys.sorted().map { "\($0):\(headers[$0]!)\n" }.joined()

        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        var pairs: [(String, String)] = []
        for item in items {
            let name = item.name.removingPercentEncoding ?? item.name
            let value = (item.value ?? "").removingPercentEncoding ?? (item.value ?? "")
            pairs.append((Self.encode(name), Self.encode(value)))
        }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let query = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let canonical = [request.httpMethod ?? "GET", path, query, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.sha256Hex(Data(canonical.utf8))].joined(separator: "\n")

        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        var key = hmac(Data("AWS4\(secretKey)".utf8), day)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        let signature = hmac(key, toSign).map { String(format: "%02x", $0) }.joined()
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
}
