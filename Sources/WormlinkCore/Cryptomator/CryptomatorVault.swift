import CryptoKit
import Foundation

public enum CryptomatorError: LocalizedError, Equatable {
    case wrongPassword
    case unsupportedVault(String)
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: String(localized: "Senha do cofre incorreta.")
        case .unsupportedVault(let detail): String(localized: "Este cofre do Cryptomator não é suportado: \(detail)")
        case .damaged(let name): String(localized: "“\(name)” está danificado ou não pertence a este cofre.")
        }
    }
}

/// Chaves e formato de um cofre do Cryptomator (formatos 7 e 8: nomes .c9r/.c9s, pastas em d/XX/…).
public struct CryptomatorVault: Sendable {
    public enum Cipher: String, Sendable {
        case gcm = "SIV_GCM"         // padrão desde o formato 8
        case ctrMac = "SIV_CTRMAC"   // formato 7 e cofres antigos migrados
    }

    public static let masterkeyFile = "masterkey.cryptomator"
    public static let configFile = "vault.cryptomator"
    static let chunkSize = 32 * 1024

    let encKey: Data
    let macKey: Data
    public let cipher: Cipher
    public let shorteningThreshold: Int

    init(encKey: Data, macKey: Data, cipher: Cipher, shorteningThreshold: Int = 220) {
        self.encKey = encKey
        self.macKey = macKey
        self.cipher = cipher
        self.shorteningThreshold = shorteningThreshold
    }

    // MARK: Abrir e criar

    private struct Masterkey: Codable {
        var version: Int
        var scryptSalt: String
        var scryptCostParam: Int
        var scryptBlockSize: Int
        var primaryMasterKey: String
        var hmacMasterKey: String
        var versionMac: String
    }

    /// Nome do arquivo de chaves indicado no vault.cryptomator ("masterkeyfile:masterkey.cryptomator").
    public static func masterkeyName(config: Data?) throws -> String {
        guard let config else { return masterkeyFile }
        let header = try jwtPart(config, 0)
        guard let kid = header["kid"] as? String, kid.hasPrefix("masterkeyfile:") else {
            throw CryptomatorError.unsupportedVault(String(localized: "chaves guardadas fora do cofre (Cryptomator Hub)"))
        }
        return String(kid.dropFirst("masterkeyfile:".count))
    }

    /// Desbloqueia com a senha: `config` é o vault.cryptomator (nil nos cofres de formato 7).
    public static func unlock(masterkey: Data, config: Data?, password: String) throws -> CryptomatorVault {
        guard let file = try? JSONDecoder().decode(Masterkey.self, from: masterkey),
              let salt = Data(base64Flexible: file.scryptSalt),
              let wrappedEnc = Data(base64Flexible: file.primaryMasterKey),
              let wrappedMac = Data(base64Flexible: file.hmacMasterKey) else {
            throw CryptomatorError.damaged(masterkeyFile)
        }
        let kek = SymmetricKey(data: Scrypt.derive(password: Data(password.precomposedStringWithCanonicalMapping.utf8), salt: salt,
                                                   n: file.scryptCostParam, r: file.scryptBlockSize, p: 1, length: 32))
        guard let enc = try? AES.KeyWrap.unwrap(wrappedEnc, using: kek), let mac = try? AES.KeyWrap.unwrap(wrappedMac, using: kek) else {
            throw CryptomatorError.wrongPassword
        }
        let encKey = enc.withUnsafeBytes { Data($0) }, macKey = mac.withUnsafeBytes { Data($0) }
        var versionBytes = Data()
        withUnsafeBytes(of: UInt32(file.version).bigEndian) { versionBytes.append(contentsOf: $0) }
        guard Data(HMAC<SHA256>.authenticationCode(for: versionBytes, using: SymmetricKey(data: macKey))) == Data(base64Flexible: file.versionMac) else {
            throw CryptomatorError.damaged(masterkeyFile)
        }

        guard let config else {
            // Sem vault.cryptomator: só o formato 7 tem a mesma estrutura de pastas.
            guard file.version == 7 else { throw CryptomatorError.unsupportedVault(String(localized: "formato \(file.version)")) }
            return CryptomatorVault(encKey: encKey, macKey: macKey, cipher: .ctrMac)
        }
        let header = try jwtPart(config, 0), payload = try jwtPart(config, 1)
        try verifyJWT(config, algorithm: header["alg"] as? String, key: encKey + macKey)
        let format = payload["format"] as? Int ?? 0
        guard format == 8 else { throw CryptomatorError.unsupportedVault(String(localized: "formato \(format)")) }
        guard let combo = (payload["cipherCombo"] as? String).flatMap(Cipher.init) else {
            throw CryptomatorError.unsupportedVault(payload["cipherCombo"] as? String ?? "?")
        }
        return CryptomatorVault(encKey: encKey, macKey: macKey, cipher: combo,
                                shorteningThreshold: payload["shorteningThreshold"] as? Int ?? 220)
    }

    /// Cofre novo no formato 8 (SIV_GCM), como o Cryptomator 1.6+ cria.
    public static func create(password: String, scryptCost: Int = 32768) -> (vault: CryptomatorVault, masterkey: Data, config: Data) {
        let vault = CryptomatorVault(encKey: random(32), macKey: random(32), cipher: .gcm)
        let salt = random(8)
        let kek = SymmetricKey(data: Scrypt.derive(password: Data(password.precomposedStringWithCanonicalMapping.utf8), salt: salt,
                                                   n: scryptCost, r: 8, p: 1, length: 32))
        var versionBytes = Data()
        withUnsafeBytes(of: UInt32(999).bigEndian) { versionBytes.append(contentsOf: $0) }
        let file = Masterkey(
            version: 999, scryptSalt: salt.base64EncodedString(), scryptCostParam: scryptCost, scryptBlockSize: 8,
            primaryMasterKey: try! AES.KeyWrap.wrap(SymmetricKey(data: vault.encKey), using: kek).base64EncodedString(),
            hmacMasterKey: try! AES.KeyWrap.wrap(SymmetricKey(data: vault.macKey), using: kek).base64EncodedString(),
            versionMac: Data(HMAC<SHA256>.authenticationCode(for: versionBytes, using: SymmetricKey(data: vault.macKey))).base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let masterkey = try! encoder.encode(file)

        func part(_ object: [String: Any]) -> String {
            let json = try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            return json.base64URLEncoded.replacingOccurrences(of: "=", with: "")
        }
        let signed = part(["kid": "masterkeyfile:\(masterkeyFile)", "typ": "JWT", "alg": "HS256"]) + "."
            + part(["jti": UUID().uuidString.lowercased(), "format": 8, "cipherCombo": Cipher.gcm.rawValue, "shorteningThreshold": 220])
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(signed.utf8), using: SymmetricKey(data: vault.encKey + vault.macKey)))
        let config = Data((signed + "." + signature.base64URLEncoded.replacingOccurrences(of: "=", with: "")).utf8)
        return (vault, masterkey, config)
    }

    private static func jwtPart(_ token: Data, _ index: Int) throws -> [String: Any] {
        let parts = String(decoding: token, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, let data = Data(base64Flexible: parts[index]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CryptomatorError.damaged(configFile)
        }
        return object
    }

    private static func verifyJWT(_ token: Data, algorithm: String?, key: Data) throws {
        let text = String(decoding: token, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = text.lastIndex(of: "."), let signature = Data(base64Flexible: text[text.index(after: dot)...]) else {
            throw CryptomatorError.damaged(configFile)
        }
        let signed = Data(text[..<dot].utf8), symmetric = SymmetricKey(data: key)
        let valid = switch algorithm {
        case "HS256": HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: signed, using: symmetric)
        case "HS384": HMAC<SHA384>.isValidAuthenticationCode(signature, authenticating: signed, using: symmetric)
        case "HS512": HMAC<SHA512>.isValidAuthenticationCode(signature, authenticating: signed, using: symmetric)
        default: false
        }
        guard valid else { throw CryptomatorError.damaged(configFile) }
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: Nomes e pastas

    /// "d/XX/YYYY…": pasta cifrada que guarda o conteúdo da pasta com este ID ("" é a raiz).
    public func directoryPath(for dirID: String) -> String {
        let encrypted = AESSIV.encrypt(macKey: macKey, ctrKey: encKey, Data(dirID.utf8))
        let hash = Data(Insecure.SHA1.hash(data: encrypted)).base32Encoded
        return "d/\(hash.prefix(2))/\(hash.dropFirst(2))"
    }

    /// Nome cifrado com a extensão .c9r (o ID da pasta-mãe entra como dado associado).
    public func encryptName(_ name: String, dirID: String) -> String {
        AESSIV.encrypt(macKey: macKey, ctrKey: encKey, Data(name.precomposedStringWithCanonicalMapping.utf8),
                       associatedData: [Data(dirID.utf8)]).base64URLEncoded + ".c9r"
    }

    public func decryptName(_ encrypted: String, dirID: String) -> String? {
        guard encrypted.hasSuffix(".c9r"), let data = Data(base64Flexible: encrypted.dropLast(4)),
              let plain = AESSIV.decrypt(macKey: macKey, ctrKey: encKey, data, associatedData: [Data(dirID.utf8)]) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Nomes cifrados longos demais viram "<sha1>.c9s" (uma pasta com name.c9s e o conteúdo).
    public func shortened(_ encrypted: String) -> String? {
        encrypted.count > shorteningThreshold ? Data(Insecure.SHA1.hash(data: Data(encrypted.utf8))).base64URLEncoded + ".c9s" : nil
    }

    // MARK: Conteúdo

    private var headerSize: Int { cipher == .gcm ? 68 : 88 }
    private var chunkOverhead: Int { cipher == .gcm ? 28 : 48 }

    /// Tamanho real de um arquivo a partir do tamanho cifrado (nil se o tamanho for impossível).
    public func cleartextSize(_ size: Int64) -> Int64? {
        let payload = size - Int64(headerSize)
        guard payload >= 0 else { return nil }
        let full = Int64(Self.chunkSize + chunkOverhead)
        let rest = payload % full
        guard rest == 0 || rest > Int64(chunkOverhead) else { return nil }
        return payload / full * Int64(Self.chunkSize) + (rest == 0 ? 0 : rest - Int64(chunkOverhead))
    }

    public func encrypt(_ data: Data) throws -> Data {
        var output = Data()
        try encrypt(read: { offset in data.count > offset ? data.subdata(in: offset..<min(data.count, offset + Self.chunkSize)) : Data() },
                    write: { output.append($0) })
        return output
    }

    public func decrypt(_ data: Data, name: String = "dirid.c9r") throws -> Data {
        var output = Data(), offset = 0
        try decrypt(name: name, read: { count in
            defer { offset = min(data.count, offset + count) }
            return data.subdata(in: offset..<min(data.count, offset + count))
        }, write: { output.append($0) })
        return output
    }

    public func encryptFile(_ source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try encrypt(read: { _ in try input.read(upToCount: Self.chunkSize) ?? Data() }, write: { try output.write(contentsOf: $0) })
    }

    public func decryptFile(_ source: URL, to destination: URL, name: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try decrypt(name: name, read: { try input.read(upToCount: $0) ?? Data() }, write: { try output.write(contentsOf: $0) })
    }

    private func encrypt(read: (Int) throws -> Data, write: (Data) throws -> Void) throws {
        let contentKey = Self.random(32)
        let headerPayload = Data(repeating: 0xFF, count: 8) + contentKey
        let headerNonce: Data
        switch cipher {
        case .gcm:
            headerNonce = Self.random(12)
            let box = try AES.GCM.seal(headerPayload, using: SymmetricKey(data: encKey), nonce: AES.GCM.Nonce(data: headerNonce))
            try write(headerNonce + box.ciphertext + box.tag)
        case .ctrMac:
            headerNonce = Self.random(16)
            let encrypted = AESBlockCipher(key: encKey).ctr(iv: Array(headerNonce), headerPayload)
            try write(headerNonce + encrypted + mac(headerNonce + encrypted))
        }
        let content = AESBlockCipher(key: contentKey)
        var index: UInt64 = 0, offset = 0
        while true {
            let chunk = try read(offset)
            if chunk.isEmpty { break }
            offset += chunk.count
            try write(try sealChunk(chunk, index: index, headerNonce: headerNonce, contentKey: contentKey, cipher: content))
            index += 1
        }
    }

    private func decrypt(name: String, read: (Int) throws -> Data, write: (Data) throws -> Void) throws {
        let header = try read(headerSize)
        guard header.count == headerSize else { throw CryptomatorError.damaged(name) }
        let headerNonce: Data, payload: Data
        switch cipher {
        case .gcm:
            headerNonce = header.prefix(12)
            guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: headerNonce), ciphertext: header.subdata(in: 12..<52),
                                                   tag: header.subdata(in: 52..<68)),
                  let plain = try? AES.GCM.open(box, using: SymmetricKey(data: encKey)) else { throw CryptomatorError.damaged(name) }
            payload = plain
        case .ctrMac:
            headerNonce = header.prefix(16)
            let encrypted = header.subdata(in: 16..<56)
            guard mac(headerNonce + encrypted) == header.subdata(in: 56..<88) else { throw CryptomatorError.damaged(name) }
            payload = AESBlockCipher(key: encKey).ctr(iv: Array(headerNonce), encrypted)
        }
        let contentKey = payload.suffix(32)
        let content = AESBlockCipher(key: contentKey)
        var index: UInt64 = 0
        while true {
            let chunk = try read(Self.chunkSize + chunkOverhead)
            if chunk.isEmpty { break }
            try write(try openChunk(chunk, index: index, headerNonce: headerNonce, contentKey: contentKey, cipher: content, name: name))
            index += 1
        }
    }

    private func sealChunk(_ chunk: Data, index: UInt64, headerNonce: Data, contentKey: Data, cipher: AESBlockCipher) throws -> Data {
        var number = Data()
        withUnsafeBytes(of: index.bigEndian) { number.append(contentsOf: $0) }
        switch self.cipher {
        case .gcm:
            let nonce = Self.random(12)
            let box = try AES.GCM.seal(chunk, using: SymmetricKey(data: contentKey), nonce: AES.GCM.Nonce(data: nonce),
                                       authenticating: number + headerNonce)
            return nonce + box.ciphertext + box.tag
        case .ctrMac:
            let nonce = Self.random(16)
            let encrypted = cipher.ctr(iv: Array(nonce), chunk)
            return nonce + encrypted + mac(headerNonce + number + nonce + encrypted)
        }
    }

    private func openChunk(_ chunk: Data, index: UInt64, headerNonce: Data, contentKey: Data, cipher: AESBlockCipher, name: String) throws -> Data {
        var number = Data()
        withUnsafeBytes(of: index.bigEndian) { number.append(contentsOf: $0) }
        guard chunk.count > chunkOverhead else { throw CryptomatorError.damaged(name) }
        let bytes = Data(chunk)
        switch self.cipher {
        case .gcm:
            guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: bytes.prefix(12)), ciphertext: bytes.subdata(in: 12..<bytes.count - 16),
                                                   tag: bytes.suffix(16)),
                  let plain = try? AES.GCM.open(box, using: SymmetricKey(data: contentKey), authenticating: number + headerNonce) else {
                throw CryptomatorError.damaged(name)
            }
            return plain
        case .ctrMac:
            let nonce = bytes.prefix(16), encrypted = bytes.subdata(in: 16..<bytes.count - 32)
            guard mac(headerNonce + number + nonce + encrypted) == bytes.suffix(32) else { throw CryptomatorError.damaged(name) }
            return cipher.ctr(iv: Array(nonce), encrypted)
        }
    }

    private func mac(_ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: macKey)))
    }
}
