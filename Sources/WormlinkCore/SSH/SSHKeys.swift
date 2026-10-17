@preconcurrency import Citadel
import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Autenticação SSH no estilo do Cyberduck/OpenSSH: primeiro a chave escolhida no favorito,
/// depois as chaves padrão de `~/.ssh` (sem senha), por fim a senha.
final class SSHUserAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]
    private let username: String
    private let lock = NSLock()

    init(username: String, password: String?, keys: [NIOSSHPrivateKey], interactive: InteractiveResponder? = nil) {
        self.username = username
        var offers = keys.map { NIOSSHUserAuthenticationOffer.Offer.privateKey(.init(privateKey: $0)) }
        if let password { offers.append(.password(.init(password: password))) }
        // Por último o keyboard-interactive (PAM, 2FA), como o OpenSSH quando a senha comum não é aceita.
        if let interactive { offers.append(.keyboardInteractive(.init(responder: interactive))) }
        self.offers = offers
    }

    /// Monta as ofertas na ordem do OpenSSH: chave do favorito e IdentityFile do ~/.ssh/config, chaves do
    /// agente, chaves padrão de ~/.ssh (salvo `IdentitiesOnly yes`) e, por último, a senha.
    /// Pede a frase secreta das chaves cifradas (e lembra no Chaves se o usuário quiser).
    static func make(username: String, password: String?, keyFile: String?, config: SSHConfig.Resolved = .init(),
                     agent: SSHAgent? = nil, passphrase prompt: KeyPassphrasePrompt,
                     interactive: InteractiveResponder? = nil) async -> SSHUserAuth {
        var explicit = [keyFile].compactMap { $0 }.filter { !$0.isEmpty } + config.identityFiles
        explicit = explicit.map { ($0 as NSString).expandingTildeInPath }
        var keys: [NIOSSHPrivateKey] = []
        for url in keyFiles(preferred: explicit, includeDefaults: false) {
            if let key = await load(url, prompt: prompt) { keys.append(key) }
        }
        if let agent, let identities = try? agent.identities() {
            // Com IdentitiesOnly, só as chaves do agente que correspondem às IdentityFile.
            let allowed = Set(explicit.compactMap { try? String(contentsOfFile: $0 + ".pub", encoding: .utf8) }
                .compactMap { $0.split(separator: " ").dropFirst().first.flatMap { Data(base64Encoded: String($0)) } })
            for identity in identities where !config.identitiesOnly || allowed.contains(identity.blob) {
                if let key = agent.privateKey(for: identity) { keys.append(key) }
            }
        }
        if !config.identitiesOnly {
            for url in keyFiles(preferred: [], includeDefaults: true) where !explicit.contains(url.path) {
                if let key = await load(url, prompt: prompt) { keys.append(key) }
            }
        }
        return SSHUserAuth(username: username, password: password, keys: keys, interactive: interactive)
    }

    private static func load(_ url: URL, prompt: KeyPassphrasePrompt) async -> NIOSSHPrivateKey? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if let key = loadKey(text, passphrase: nil) { return key }
        guard isEncrypted(text) else { return nil }
        if let saved = Keychain.keyPassphrase(for: url.path), let key = loadKey(text, passphrase: saved) { return key }
        var retry = false
        while let answer = await prompt(PassphraseRequest(keyPath: url.path, retry: retry)) {
            if let key = loadKey(text, passphrase: answer.passphrase) {
                if answer.remember { Keychain.setKeyPassphrase(answer.passphrase, for: url.path) }
                return key
            }
            retry = true
        }
        return nil
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let next: NIOSSHUserAuthenticationOffer.Offer? = lock.withLock {
            while !offers.isEmpty {
                let offer = offers.removeFirst()
                switch offer {
                case .privateKey where availableMethods.contains(.publicKey): return offer
                case .password where availableMethods.contains(.password): return offer
                case .keyboardInteractive where availableMethods.contains(.keyboardInteractive): return offer
                default: continue
                }
            }
            return nil
        }
        guard let next else { return nextChallengePromise.fail(WormlinkError.authenticationFailed) }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: next))
    }

    static func keyFiles(preferred: [String], includeDefaults: Bool) -> [URL] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        var files = preferred.map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
        if includeDefaults { files += ["id_ed25519", "id_ecdsa", "id_rsa"].map { ssh.appending(path: $0) } }
        var seen = Set<String>()
        return files.filter { FileManager.default.isReadableFile(atPath: $0.path) && seen.insert($0.path).inserted }
    }

    /// Chave do favorito, IdentityFile do ~/.ssh/config e as padrão (para a extensão do Finder).
    static func keyFiles(for bookmark: Bookmark) -> [URL] {
        let config = SSHConfig.load().resolve(bookmark.hostname)
        return keyFiles(preferred: [bookmark.keyFile].compactMap { $0 } + config.identityFiles, includeDefaults: !config.identitiesOnly)
    }

    /// Chaves OpenSSH Ed25519, RSA e ECDSA, com ou sem frase secreta (bcrypt + aes256-ctr, padrão do ssh-keygen).
    static func loadKey(_ text: String, passphrase: String?) -> NIOSSHPrivateKey? {
        let secret = passphrase.map { Data($0.utf8) }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: secret) { return NIOSSHPrivateKey(ed25519Key: key) }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: secret) {
            return NIOSSHPrivateKey(custom: Insecure.RSA.SHA512PrivateKey(key))
        }
        if let key = try? P256.Signing.PrivateKey(sshECDSA: text, decryptionKey: secret) { return NIOSSHPrivateKey(p256Key: key) }
        if let key = try? P384.Signing.PrivateKey(sshECDSA: text, decryptionKey: secret) { return NIOSSHPrivateKey(p384Key: key) }
        if let key = try? P521.Signing.PrivateKey(sshECDSA: text, decryptionKey: secret) { return NIOSSHPrivateKey(p521Key: key) }
        return nil
    }

    /// Chave no formato openssh-key-v1 com cifra diferente de "none".
    static func isEncrypted(_ text: String) -> Bool {
        let body = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body), data.count > 40 else { return false }
        // Depois de "openssh-key-v1\0" vem o nome da cifra (string SSH).
        let start = 15
        let length = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, start + 4 + length <= data.count else { return false }
        return String(decoding: data[(start + 4)..<(start + 4 + length)], as: UTF8.self) != "none"
    }
}

/// Responde ao keyboard-interactive: a pergunta única oculta ("Password:") recebe a senha do favorito
/// uma vez; as demais (código 2FA, OTP…) vão para o usuário.
final class InteractiveResponder: NIOSSHKeyboardInteractiveResponder, @unchecked Sendable {
    private let host: String
    private let user: String
    private let password: String?
    private let prompt: InteractivePrompt
    private let lock = NSLock()
    private var usedPassword = false

    init(host: String, user: String, password: String?, prompt: @escaping InteractivePrompt) {
        self.host = host
        self.user = user
        self.password = password
        self.prompt = prompt
    }

    func respond(to challenge: NIOSSHKeyboardInteractiveChallenge, promise: EventLoopPromise<[String]>) {
        if challenge.prompts.isEmpty { return promise.succeed([]) }
        let autoPassword: String? = lock.withLock {
            guard let password, !usedPassword, challenge.prompts.count == 1, !challenge.prompts[0].echo else { return nil }
            usedPassword = true
            return password
        }
        if let autoPassword { return promise.succeed([autoPassword]) }
        let question = InteractiveChallenge(host: host, user: user, name: challenge.name, instruction: challenge.instruction,
                                            prompts: challenge.prompts.map { .init(text: $0.text, echo: $0.echo) })
        let prompt = prompt
        Task {
            if let answers = await prompt(question) { promise.succeed(answers) } else { promise.fail(WormlinkError.authenticationFailed) }
        }
    }
}
