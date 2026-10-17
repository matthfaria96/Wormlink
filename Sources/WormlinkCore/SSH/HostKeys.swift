import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Chave apresentada por um servidor SSH que ainda não é conhecida (ou mudou).
public struct HostKeyChallenge: Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    /// Impressão digital `SHA256:…`, como o `ssh` mostra.
    public let fingerprint: String
    /// Havia outra chave salva para este servidor: possível ataque ou servidor reinstalado.
    public let changed: Bool
    let openSSHKey: String
}

/// Decide se uma chave desconhecida deve ser aceita (normalmente perguntando ao usuário).
public typealias HostKeyTrust = @Sendable (HostKeyChallenge) async -> Bool

/// Chaves de servidores confiáveis. Lê o `~/.ssh/known_hosts` do OpenSSH (inclusive linhas com
/// nome em hash) e grava as novas em `Application Support/Wormlink/known_hosts`, no mesmo formato.
public enum KnownHosts {
    static var wormlinkFile: URL { WormlinkPaths.dataDirectory.appending(path: "known_hosts") }
    static var openSSHFile: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/known_hosts") }

    enum Match { case trusted, unknown, changed }

    /// Nome do servidor como o OpenSSH grava: `host` na porta 22, `[host]:porta` nas outras.
    static func hostPattern(_ host: String, _ port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    static func check(host: String, port: Int, key: String) -> Match {
        let name = hostPattern(host, port)
        let parts = key.split(separator: " ")
        guard parts.count >= 2 else { return .unknown }
        let (type, blob) = (parts[0], parts[1])
        var sawSameType = false
        for file in [wormlinkFile, openSSHFile] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ")
                guard fields.count >= 3, !line.hasPrefix("#"), !line.hasPrefix("@") else { continue }
                guard matches(String(fields[0]), name) else { continue }
                guard fields[1] == type else { continue }
                if fields[2] == blob { return .trusted }
                sawSameType = true
            }
        }
        return sawSameType ? .changed : .unknown
    }

    /// Aceita listas separadas por vírgula e o formato em hash `|1|sal|hmac`.
    static func matches(_ field: String, _ name: String) -> Bool {
        if field.hasPrefix("|1|") {
            let parts = field.split(separator: "|")
            guard parts.count == 3, let salt = Data(base64Encoded: String(parts[1])),
                  let hash = Data(base64Encoded: String(parts[2])) else { return false }
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
            return Data(mac) == hash
        }
        return field.split(separator: ",").contains { $0.lowercased() == name }
    }

    static func remember(host: String, port: Int, key: String) {
        let file = wormlinkFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let name = hostPattern(host, port)
        // Troca a linha antiga deste servidor, se houver.
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let kept = old.split(whereSeparator: \.isNewline).filter { !matches(String($0.split(separator: " ").first ?? ""), name) }
        let text = (kept.map(String.init) + ["\(name) \(key)"]).joined(separator: "\n") + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    static func fingerprint(of key: String) -> String {
        let blob = key.split(separator: " ").dropFirst().first.flatMap { Data(base64Encoded: String($0)) } ?? Data()
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + digest
    }
}

/// Validador entregue ao NIOSSH: confere a chave e, se preciso, pergunta via `trust`.
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int
    let trust: HostKeyTrust

    init(host: String, port: Int, trust: @escaping HostKeyTrust) {
        self.host = host
        self.port = port
        self.trust = trust
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        let match = KnownHosts.check(host: host, port: port, key: key)
        if match == .trusted { return validationCompletePromise.succeed() }
        let challenge = HostKeyChallenge(host: host, port: port, keyType: String(key.split(separator: " ").first ?? ""),
                                         fingerprint: KnownHosts.fingerprint(of: key), changed: match == .changed,
                                         openSSHKey: key)
        let (host, port, trust) = (host, port, trust)
        Task {
            if await trust(challenge) {
                KnownHosts.remember(host: host, port: port, key: key)
                validationCompletePromise.succeed()
            } else {
                validationCompletePromise.fail(WormlinkError.hostKeyRejected)
            }
        }
    }
}
