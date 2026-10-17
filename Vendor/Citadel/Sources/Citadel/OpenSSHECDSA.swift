import Crypto
import Foundation
import NIO

// Wormlink: leitura de chaves ECDSA (nistp256/384/521) no formato openssh-key-v1, com ou sem frase secreta.
// Pública: string curva, string ponto Q (não comprimido). Privada: string curva, string Q, mpint d.

private protocol ECDSAKeyPair {
    static var curveName: String { get }
    static var scalarLength: Int { get }
    init(rawScalar: Data) throws
    var publicPoint: Data { get }
}

extension ByteBuffer {
    fileprivate mutating func readECDSAPublicPoint(curve: String) throws -> Data {
        guard readSSHString() == curve, var point = readSSHBuffer(), let bytes = point.readBytes(length: point.readableBytes) else {
            throw InvalidOpenSSHKey.invalidLayout
        }
        return Data(bytes)
    }

    /// mpint SSH: big-endian, com um 0x00 na frente quando o bit mais alto está ligado.
    fileprivate mutating func readECDSAScalar(length: Int) throws -> Data {
        guard var mpint = readSSHBuffer(), var bytes = mpint.readBytes(length: mpint.readableBytes) else {
            throw InvalidOpenSSHKey.invalidLayout
        }
        while bytes.count > length, bytes.first == 0 { bytes.removeFirst() }
        guard bytes.count <= length else { throw InvalidOpenSSHKey.invalidLayout }
        return Data(repeating: 0, count: length - bytes.count) + bytes
    }
}

private func readPrivate<Key: ECDSAKeyPair>(_ type: Key.Type, consuming buffer: inout ByteBuffer) throws -> Key {
    let point = try buffer.readECDSAPublicPoint(curve: Key.curveName)
    let key = try Key(rawScalar: buffer.readECDSAScalar(length: Key.scalarLength))
    guard key.publicPoint == point else { throw InvalidOpenSSHKey.invalidPublicKeyInPrivateKey }
    return key
}

extension P256.Signing.PrivateKey: ECDSAKeyPair, OpenSSHPrivateKey {
    fileprivate static var curveName: String { "nistp256" }
    fileprivate static var scalarLength: Int { 32 }
    fileprivate init(rawScalar: Data) throws { try self.init(rawRepresentation: rawScalar) }
    fileprivate var publicPoint: Data { publicKey.x963Representation }

    typealias PublicKey = P256.Signing.PublicKey
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp256" }
    static var privateKeyPrefix: String { "ecdsa-sha2-nistp256" }
    static var keyType: OpenSSH.KeyType { .ecdsaP256 }

    static func read(consuming buffer: inout ByteBuffer) throws -> Self { try readPrivate(Self.self, consuming: &buffer) }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }

    public init(sshECDSA key: String, decryptionKey: Data? = nil) throws {
        self = try OpenSSH.PrivateKey<P256.Signing.PrivateKey>(string: key, decryptionKey: decryptionKey).privateKey
    }
}

extension P256.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try Self(x963Representation: buffer.readECDSAPublicPoint(curve: "nistp256"))
    }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }
}

extension P384.Signing.PrivateKey: ECDSAKeyPair, OpenSSHPrivateKey {
    fileprivate static var curveName: String { "nistp384" }
    fileprivate static var scalarLength: Int { 48 }
    fileprivate init(rawScalar: Data) throws { try self.init(rawRepresentation: rawScalar) }
    fileprivate var publicPoint: Data { publicKey.x963Representation }

    typealias PublicKey = P384.Signing.PublicKey
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp384" }
    static var privateKeyPrefix: String { "ecdsa-sha2-nistp384" }
    static var keyType: OpenSSH.KeyType { .ecdsaP384 }

    static func read(consuming buffer: inout ByteBuffer) throws -> Self { try readPrivate(Self.self, consuming: &buffer) }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }

    public init(sshECDSA key: String, decryptionKey: Data? = nil) throws {
        self = try OpenSSH.PrivateKey<P384.Signing.PrivateKey>(string: key, decryptionKey: decryptionKey).privateKey
    }
}

extension P384.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try Self(x963Representation: buffer.readECDSAPublicPoint(curve: "nistp384"))
    }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }
}

extension P521.Signing.PrivateKey: ECDSAKeyPair, OpenSSHPrivateKey {
    fileprivate static var curveName: String { "nistp521" }
    fileprivate static var scalarLength: Int { 66 }
    fileprivate init(rawScalar: Data) throws { try self.init(rawRepresentation: rawScalar) }
    fileprivate var publicPoint: Data { publicKey.x963Representation }

    typealias PublicKey = P521.Signing.PublicKey
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp521" }
    static var privateKeyPrefix: String { "ecdsa-sha2-nistp521" }
    static var keyType: OpenSSH.KeyType { .ecdsaP521 }

    static func read(consuming buffer: inout ByteBuffer) throws -> Self { try readPrivate(Self.self, consuming: &buffer) }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }

    public init(sshECDSA key: String, decryptionKey: Data? = nil) throws {
        self = try OpenSSH.PrivateKey<P521.Signing.PrivateKey>(string: key, decryptionKey: decryptionKey).privateKey
    }
}

extension P521.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try Self(x963Representation: buffer.readECDSAPublicPoint(curve: "nistp521"))
    }
    func write(to buffer: inout ByteBuffer) -> Int { 0 }
}
