import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSL
import Security

/// Certificado TLS que o sistema não considera confiável (autoassinado, expirado, nome errado…).
public struct CertificateChallenge: Sendable {
    public let host: String
    public let summary: String
    /// SHA-256 do certificado do servidor, em pares hexadecimais.
    public let fingerprint: String
    public let reason: String
}

public typealias CertificateTrust = @Sendable (CertificateChallenge) async -> Bool

/// Perguntas do keyboard-interactive (RFC 4256).
public struct InteractiveChallenge: Sendable {
    public struct Prompt: Sendable {
        public let text: String
        /// Falso para senhas (a resposta não aparece na tela).
        public let echo: Bool
    }
    public let host: String
    public let user: String
    public let name: String
    public let instruction: String
    public let prompts: [Prompt]
}

public typealias InteractivePrompt = @Sendable (InteractiveChallenge) async -> [String]?

/// Pedido de frase secreta: caminho da chave e se uma tentativa anterior falhou.
public struct PassphraseRequest: Sendable {
    public let keyPath: String
    public let retry: Bool
}

/// Resposta: a frase e se deve ser guardada no Chaves.
public typealias KeyPassphrasePrompt = @Sendable (PassphraseRequest) async -> (passphrase: String, remember: Bool)?

/// Perguntas de confiança que uma conexão pode precisar fazer ao usuário.
public struct ConnectionTrust: Sendable {
    public var hostKey: HostKeyTrust
    public var certificate: CertificateTrust
    /// Pede a frase secreta de uma chave SSH cifrada (nil = cancelar e seguir sem ela).
    public var passphrase: KeyPassphrasePrompt
    /// Abre o navegador para o login das nuvens (OAuth).
    public var openBrowser: BrowserOpener
    /// Perguntas do servidor no login keyboard-interactive (código 2FA, OTP…); nil = cancelar.
    public var interactive: InteractivePrompt

    public init(hostKey: @escaping HostKeyTrust, certificate: @escaping CertificateTrust,
                passphrase: @escaping KeyPassphrasePrompt = { _ in nil }, openBrowser: @escaping BrowserOpener = { _ in },
                interactive: @escaping InteractivePrompt = { _ in nil }) {
        self.hostKey = hostKey
        self.certificate = certificate
        self.passphrase = passphrase
        self.openBrowser = openBrowser
        self.interactive = interactive
    }

    /// Recusa tudo o que não for confiável por padrão.
    public static let strict = ConnectionTrust(hostKey: { _ in false }, certificate: { _ in false })
}

/// Avalia certificados com o SecTrust do sistema e lembra exceções aceitas pelo usuário.
public enum CertificateTrustStore {
    static var file: URL { WormlinkPaths.dataDirectory.appending(path: "certificates") }

    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func isRemembered(host: String, fingerprint: String) -> Bool {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).contains { $0 == "\(host.lowercased()) \(fingerprint)" }
    }

    static func remember(host: String, fingerprint: String) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (old + "\(host.lowercased()) \(fingerprint)\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Avalia a cadeia (DER, folha primeiro). Devolve `nil` se confiável, ou o desafio a apresentar.
    static func evaluate(chain: [Data], host: String) -> CertificateChallenge? {
        let certs = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = certs.first else {
            return CertificateChallenge(host: host, summary: "", fingerprint: "", reason: "O servidor não enviou certificado.")
        }
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        var error: CFError?
        if let trust, SecTrustEvaluateWithError(trust, &error) { return nil }
        let fp = fingerprint(chain[0])
        if isRemembered(host: host, fingerprint: fp) { return nil }
        let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? host
        let reason = (error.map { CFErrorCopyDescription($0) as String }) ?? "O certificado não é confiável."
        return CertificateChallenge(host: host, summary: summary, fingerprint: fp, reason: reason)
    }

    /// Avalia e, se preciso, pergunta; aceito pelo usuário, fica lembrado.
    static func check(chain: [Data], host: String, trust: CertificateTrust) async -> Bool {
        guard let challenge = evaluate(chain: chain, host: host) else { return true }
        guard await trust(challenge) else { return false }
        remember(host: host, fingerprint: challenge.fingerprint)
        return true
    }

    /// Callback de verificação para o NIOSSL (substitui a verificação do BoringSSL pela do sistema).
    static func nioCallback(host: String, trust: @escaping CertificateTrust)
        -> @Sendable ([NIOSSLCertificate], EventLoopPromise<NIOSSLVerificationResult>) -> Void {
        { certificates, promise in
            let chain = certificates.compactMap { try? Data($0.toDERBytes()) }
            Task {
                promise.succeed(await check(chain: chain, host: host, trust: trust) ? .certificateVerified : .failed)
            }
        }
    }
}

extension SecTrust {
    /// Cadeia em DER (folha primeiro), para `CertificateTrustStore`.
    var derChain: [Data] {
        (SecTrustCopyCertificateChain(self) as? [SecCertificate] ?? []).map { SecCertificateCopyData($0) as Data }
    }
}
