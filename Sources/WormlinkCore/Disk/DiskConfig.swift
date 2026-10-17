import Foundation
import Security

/// Tudo o que a extensão do Finder (sandbox, sem acesso a ~/.ssh nem aos dados do app) precisa para
/// abrir um servidor: o favorito, a senha ou tokens, as chaves SSH e as confianças já aceitas no app.
public struct DiskConfig: Codable, Sendable {
    public var bookmark: Bookmark
    public var secret: String?
    /// Chaves privadas OpenSSH (texto) e suas frases secretas.
    public var keys: [Key]
    /// Linhas `host tipo chave` aceitas para este servidor.
    public var hostKeys: [String]
    /// Impressões digitais SHA-256 de certificados aceitos.
    public var certificates: [String]

    public struct Key: Codable, Sendable {
        public var text: String
        public var passphrase: String?
    }

    public init(bookmark: Bookmark, secret: String?, keys: [Key], hostKeys: [String], certificates: [String]) {
        self.bookmark = bookmark
        self.secret = secret
        self.keys = keys
        self.hostKeys = hostKeys
        self.certificates = certificates
    }

    /// Reúne a configuração no app (que pode ler ~/.ssh, o Chaves e as confianças).
    public static func collect(for bookmark: Bookmark) -> DiskConfig {
        var keys: [Key] = []
        if bookmark.connectionProtocol == .sftp {
            for url in SSHUserAuth.keyFiles(for: bookmark) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                keys.append(Key(text: text, passphrase: Keychain.keyPassphrase(for: url.path)))
            }
        }
        return DiskConfig(bookmark: bookmark, secret: Keychain.password(for: bookmark), keys: keys,
                          hostKeys: KnownHosts.entries(host: bookmark.hostname, port: bookmark.port),
                          certificates: CertificateTrustStore.fingerprints(host: bookmark.hostname))
    }

    // MARK: Chaves (Keychain) — item próprio, liberado para o app e a extensão

    static let service = "Wormlink Disk"

    /// Grava a configuração no Chaves com acesso para os apps indicados (o app e a extensão).
    public func store(trusting applications: [String]) throws {
        let data = try JSONEncoder().encode(self)
        let account = bookmark.id.uuidString
        Self.remove(account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Wormlink Disk: \(bookmark.displayName)",
            kSecValueData as String: data,
        ]
        if let access = Self.access(trusting: applications, label: "Wormlink Disk: \(bookmark.displayName)") {
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WormlinkError.server(status: Int(status), message: SecCopyErrorMessageString(status, nil) as String? ?? "Chaves")
        }
    }

    public static func load(_ account: String) -> DiskConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(DiskConfig.self, from: data)
    }

    public static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    /// ACL do Chaves de arquivo: só o app e a extensão leem sem pedir permissão.
    /// (SecAccess é obsoleto, mas é o único jeito de liberar um item a outro executável sem um Team ID;
    /// com assinatura Developer ID dá para trocar por um grupo de acesso do Chaves.)
    private static func access(trusting paths: [String], label: String) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        for path in paths {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    // MARK: Dentro da extensão

    /// Prepara o sandbox da extensão: chaves em arquivos próprios e confianças nos arquivos do núcleo.
    /// Devolve o favorito com `keyFile` apontando para a chave gravada.
    public func install(in directory: URL) throws -> Bookmark {
        WormlinkPaths.dataDirectory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bookmark = bookmark
        for (index, key) in keys.enumerated() {
            let file = directory.appending(path: "key-\(index)")
            try key.text.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            if index == 0 { bookmark.keyFile = file.path }
            if let passphrase = key.passphrase { Keychain.setKeyPassphrase(passphrase, for: file.path) }
        }
        try (hostKeys.joined(separator: "\n") + "\n").write(to: KnownHosts.wormlinkFile, atomically: true, encoding: .utf8)
        for fingerprint in certificates { CertificateTrustStore.remember(host: bookmark.hostname, fingerprint: fingerprint) }
        return bookmark
    }
}

extension KnownHosts {
    /// Chaves aceitas para o servidor, como linhas `[host]:porta tipo chave` (inclusive das entradas em hash).
    public static func entries(host: String, port: Int) -> [String] {
        let name = hostPattern(host, port)
        var result: [String] = []
        for file in [wormlinkFile, openSSHFile] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ")
                guard fields.count >= 3, !line.hasPrefix("#"), !line.hasPrefix("@"), matches(String(fields[0]), name) else { continue }
                result.append("\(name) \(fields[1]) \(fields[2])")
            }
        }
        return Array(Set(result))
    }
}

extension CertificateTrustStore {
    static func fingerprints(host: String) -> [String] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0] == host.lowercased() ? String(parts[1]) : nil
        }
    }
}
