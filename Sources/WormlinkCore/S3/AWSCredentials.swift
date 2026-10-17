import Foundation

/// Perfis da AWS CLI (`~/.aws/credentials` e `~/.aws/config`), como o Cyberduck e o Transmit leem.
public struct AWSProfiles: Sendable {
    public struct Profile: Sendable, Equatable {
        public var accessKey: String?
        public var secretKey: String?
        public var sessionToken: String?
        public var region: String?
        public var roleARN: String?
        public var sourceProfile: String?
        public var externalID: String?
        public var mfaSerial: String?
        public var duration: Int?
    }

    var sections: [String: [String: String]]

    /// Caminhos substituíveis nos testes.
    nonisolated(unsafe) public static var credentialsFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws/credentials")
    nonisolated(unsafe) public static var configFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws/config")

    public init(credentials: String, config: String) {
        var sections: [String: [String: String]] = [:]
        func parse(_ text: String, isConfig: Bool) {
            var current: String?
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
                if line.hasPrefix("["), line.hasSuffix("]") {
                    var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    // No config os perfis são "[profile nome]" (menos o default).
                    if isConfig, name.hasPrefix("profile ") { name = String(name.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                    current = name
                    continue
                }
                guard let current, let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                // Credenciais têm prioridade sobre o config.
                if isConfig, sections[current]?[key] != nil { continue }
                sections[current, default: [:]][key] = value
            }
        }
        parse(credentials, isConfig: false)
        parse(config, isConfig: true)
        self.sections = sections
    }

    public static func load() -> AWSProfiles {
        AWSProfiles(credentials: (try? String(contentsOf: credentialsFile, encoding: .utf8)) ?? "",
                    config: (try? String(contentsOf: configFile, encoding: .utf8)) ?? "")
    }

    public var names: [String] { sections.keys.sorted() }

    public func profile(_ name: String) -> Profile? {
        guard let s = sections[name] else { return nil }
        return Profile(accessKey: s["aws_access_key_id"], secretKey: s["aws_secret_access_key"], sessionToken: s["aws_session_token"],
                       region: s["region"], roleARN: s["role_arn"], sourceProfile: s["source_profile"],
                       externalID: s["external_id"], mfaSerial: s["mfa_serial"], duration: s["duration_seconds"].flatMap(Int.init))
    }
}

/// Credenciais de S3 em uso, renovando as temporárias do STS antes de expirarem.
actor AWSCredentials {
    private var signer: S3Signer
    private var expires: Date?
    private let refresh: (@Sendable () async throws -> (S3Signer, Date?))?

    init(signer: S3Signer, expires: Date? = nil, refresh: (@Sendable () async throws -> (S3Signer, Date?))? = nil) {
        self.signer = signer
        self.expires = expires
        self.refresh = refresh
    }

    func current() async throws -> S3Signer {
        if let expires, let refresh, expires.timeIntervalSinceNow < 120 {
            (signer, self.expires) = try await refresh()
        }
        return signer
    }

    /// Monta as credenciais do favorito: chaves digitadas, perfil da AWS CLI e/ou papel IAM (AssumeRole).
    static func resolve(_ bookmark: Bookmark, secret: String, trust: ConnectionTrust) async throws -> AWSCredentials {
        var base = S3Signer(accessKey: bookmark.username, secretKey: secret)
        var role = bookmark.roleARN.flatMap { $0.isEmpty ? nil : $0 }
        var externalID = bookmark.externalID
        var mfaSerial = bookmark.mfaSerial
        var duration = 3_600
        if let name = bookmark.awsProfile, !name.isEmpty {
            let profiles = AWSProfiles.load()
            guard let profile = profiles.profile(name) else { throw WormlinkError.awsProfileNotFound(name) }
            // Perfil com papel: as chaves vêm do source_profile.
            let keys = profile.roleARN != nil ? profile.sourceProfile.flatMap(profiles.profile) : profile
            guard let access = keys?.accessKey, let secretKey = keys?.secretKey else { throw WormlinkError.awsProfileNotFound(name) }
            base = S3Signer(accessKey: access, secretKey: secretKey, sessionToken: keys?.sessionToken)
            role = role ?? profile.roleARN
            externalID = externalID ?? profile.externalID
            mfaSerial = mfaSerial ?? profile.mfaSerial
            duration = profile.duration ?? duration
        }
        guard let role else { return AWSCredentials(signer: base) }

        let endpoint = bookmark.stsEndpoint.flatMap { $0.isEmpty ? nil : $0 } ?? "https://sts.amazonaws.com"
        let assume: @Sendable () async throws -> (S3Signer, Date?) = { [base, externalID, mfaSerial, duration] in
            var code: String?
            if let mfaSerial, !mfaSerial.isEmpty {
                let answer = await trust.interactive(InteractiveChallenge(
                    host: "AWS", user: mfaSerial, name: String(localized: "Código MFA da AWS"),
                    instruction: String(localized: "Digite o código do dispositivo MFA \(mfaSerial) para assumir o papel \(role)."),
                    prompts: [.init(text: String(localized: "Código MFA:"), echo: true)]))
                guard let first = answer?.first, !first.isEmpty else { throw WormlinkError.authenticationFailed }
                code = first
            }
            return try await STS.assumeRole(role, using: base, endpoint: endpoint, externalID: externalID,
                                            mfaSerial: mfaSerial, code: code, duration: duration)
        }
        let (signer, expires) = try await assume()
        // Com MFA a renovação pede um código novo (como a AWS CLI); sem ela tudo falharia depois de uma hora.
        return AWSCredentials(signer: signer, expires: expires, refresh: assume)
    }
}

/// AWS Security Token Service: AssumeRole (o "Amazon S3 with IAM Role" do Transmit).
enum STS {
    static func assumeRole(_ role: String, using base: S3Signer, endpoint: String, externalID: String?, mfaSerial: String?,
                           code: String?, duration: Int) async throws -> (S3Signer, Date?) {
        var form = ["Action": "AssumeRole", "Version": "2011-06-15", "RoleArn": role,
                    "RoleSessionName": "wormlink-\(Int(Date().timeIntervalSince1970))", "DurationSeconds": String(duration)]
        if let externalID, !externalID.isEmpty { form["ExternalId"] = externalID }
        if let mfaSerial, let code { form["SerialNumber"] = mfaSerial; form["TokenCode"] = code }
        guard let url = URL(string: endpoint.hasSuffix("/") ? endpoint : endpoint + "/") else { throw WormlinkError.invalidBookmark }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        request.httpBody = body
        var signer = base
        signer.service = "sts"
        let region = url.host()?.split(separator: ".").dropFirst().first.map(String.init).flatMap { $0 == "amazonaws" ? nil : $0 } ?? "us-east-1"
        signer.sign(&request, region: region, payloadHash: S3Signer.sha256Hex(body))
        let (data, response) = try await URLSession.shared.data(for: request)
        let nodes = S3XML.parse(data)
        func value(_ name: String) -> String? { nodes.first { $0.name == name }?.text }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = value("AccessKeyId"),
              let secret = value("SecretAccessKey"), let token = value("SessionToken") else {
            throw WormlinkError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                       message: value("Message") ?? "AssumeRole falhou.")
        }
        Transcript.log("AWS STS", "AssumeRole \(role) → \(access)")
        return (S3Signer(accessKey: access, secretKey: secret, sessionToken: token), value("Expiration").flatMap(parseISODate))
    }
}
