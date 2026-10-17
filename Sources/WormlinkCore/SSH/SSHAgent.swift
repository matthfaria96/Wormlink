import Darwin
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Cliente do protocolo do agente SSH (draft-miller-ssh-agent) por socket Unix:
/// lista as chaves e pede assinaturas. Funciona com o ssh-agent do macOS, 1Password, Secretive etc.
public final class SSHAgent: @unchecked Sendable {
    public let socketPath: String
    private let lock = NSLock()

    public struct Identity: Sendable {
        public let blob: Data
        public let comment: String
        /// "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"…
        public let type: String
    }

    enum Message: UInt8 {
        case failure = 5, requestIdentities = 11, identitiesAnswer = 12, signRequest = 13, signResponse = 14
    }

    static let rsaSHA512Flag: UInt32 = 4

    public init(socketPath: String) { self.socketPath = socketPath }

    /// Agente indicado pelo `IdentityAgent` do ~/.ssh/config, ou o de `SSH_AUTH_SOCK`.
    public static func `default`(identityAgent: String? = nil) -> SSHAgent? {
        if identityAgent == "none" { return nil }
        let path = identityAgent ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return SSHAgent(socketPath: path)
    }

    public func identities() throws -> [Identity] {
        var reply = try request(.requestIdentities, payload: Data())
        guard reply.type == Message.identitiesAnswer.rawValue else { throw WormlinkError.invalidResponse }
        let count = try reply.body.readUInt32()
        var result: [Identity] = []
        for _ in 0..<count {
            let blob = try reply.body.readString()
            let comment = String(decoding: try reply.body.readString(), as: UTF8.self)
            var copy = blob
            let type = String(decoding: try copy.readString(), as: UTF8.self)
            result.append(Identity(blob: blob, comment: comment, type: type))
        }
        return result
    }

    /// Assinatura no formato do agente: (nome do algoritmo, bytes da assinatura).
    func sign(_ data: Data, with identity: Identity) throws -> (String, Data) {
        var payload = Data()
        payload.appendString(identity.blob)
        payload.appendString(data)
        payload.appendUInt32(identity.type == "ssh-rsa" ? Self.rsaSHA512Flag : 0)
        var reply = try request(.signRequest, payload: payload)
        guard reply.type == Message.signResponse.rawValue else { throw WormlinkError.authenticationFailed }
        var signature = try reply.body.readString()
        let format = String(decoding: try signature.readString(), as: UTF8.self)
        return (format, try signature.readString())
    }

    private func request(_ type: Message, payload: Data) throws -> (type: UInt8, body: Data) {
        try lock.withLock {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw WormlinkError.connectionClosed }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketPath.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw WormlinkError.connectionClosed }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                path.withUnsafeBytes { buffer.copyMemory(from: $0) }
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw WormlinkError.connectionClosed }
            var message = Data()
            message.appendUInt32(UInt32(payload.count + 1))
            message.append(type.rawValue)
            message.append(payload)
            try Self.writeAll(fd, message)
            var header = try Self.readExactly(fd, 4)
            let length = Int(try header.readUInt32())
            guard length > 0, length < 256 * 1024 else { throw WormlinkError.invalidResponse }
            var body = try Self.readExactly(fd, length)
            let replyType = body.removeFirst()
            return (replyType, body)
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw WormlinkError.connectionClosed }
                offset += n
            }
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                let n = read(fd, raw.baseAddress! + offset, count - offset)
                guard n > 0 else { throw WormlinkError.connectionClosed }
                offset += n
            }
        }
        return data
    }

    // MARK: Chaves do agente para o NIOSSH

    /// Chave privada que nunca sai do agente: o NIOSSH só pede assinaturas.
    func privateKey(for identity: Identity) -> NIOSSHPrivateKey? {
        switch identity.type {
        case "ssh-ed25519": NIOSSHPrivateKey(custom: AgentPrivateKey<Ed25519Algorithm>(agent: self, identity: identity))
        case "ssh-rsa": NIOSSHPrivateKey(custom: AgentPrivateKey<RSAAlgorithm>(agent: self, identity: identity))
        case "ecdsa-sha2-nistp256": NIOSSHPrivateKey(custom: AgentPrivateKey<P256Algorithm>(agent: self, identity: identity))
        case "ecdsa-sha2-nistp384": NIOSSHPrivateKey(custom: AgentPrivateKey<P384Algorithm>(agent: self, identity: identity))
        case "ecdsa-sha2-nistp521": NIOSSHPrivateKey(custom: AgentPrivateKey<P521Algorithm>(agent: self, identity: identity))
        default: nil   // ex.: chaves sk-* de segurança física ainda não
        }
    }
}

// MARK: - Tipos por algoritmo (o NIOSSH exige prefixos estáticos)

protocol AgentAlgorithm {
    static var keyType: String { get }
    static var signatureType: String { get }
}

enum Ed25519Algorithm: AgentAlgorithm {
    static var keyType: String { "ssh-ed25519" }
    static var signatureType: String { "ssh-ed25519" }
}

/// RSA sempre com rsa-sha2-512 (o OpenSSH moderno recusa ssh-rsa/SHA-1).
enum RSAAlgorithm: AgentAlgorithm {
    static var keyType: String { "ssh-rsa" }
    static var signatureType: String { "rsa-sha2-512" }
}

enum P256Algorithm: AgentAlgorithm {
    static var keyType: String { "ecdsa-sha2-nistp256" }
    static var signatureType: String { "ecdsa-sha2-nistp256" }
}

enum P384Algorithm: AgentAlgorithm {
    static var keyType: String { "ecdsa-sha2-nistp384" }
    static var signatureType: String { "ecdsa-sha2-nistp384" }
}

enum P521Algorithm: AgentAlgorithm {
    static var keyType: String { "ecdsa-sha2-nistp521" }
    static var signatureType: String { "ecdsa-sha2-nistp521" }
}

final class AgentPrivateKey<A: AgentAlgorithm>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { A.signatureType }
    let agent: SSHAgent
    let identity: SSHAgent.Identity

    init(agent: SSHAgent, identity: SSHAgent.Identity) {
        self.agent = agent
        self.identity = identity
    }

    var publicKey: NIOSSHPublicKeyProtocol { AgentPublicKey<A>(blob: identity.blob) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let (_, bytes) = try agent.sign(Data(data), with: identity)
        return AgentSignature<A>(rawRepresentation: bytes)
    }
}

final class AgentPublicKey<A: AgentAlgorithm>: NIOSSHPublicKeyProtocol, NIOSSHUserAuthAlgorithmNaming {
    static var publicKeyPrefix: String { A.keyType }
    var userAuthAlgorithmName: String { A.signatureType }
    /// Blob completo do agente: string(tipo) + dados da chave.
    let blob: Data

    init(blob: Data) { self.blob = blob }

    var rawRepresentation: Data { blob }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }

    /// O NIOSSH já escreveu o tipo; aqui vai o resto do blob.
    func write(to buffer: inout ByteBuffer) -> Int {
        var copy = blob
        _ = try? copy.readString()
        return buffer.writeBytes(copy)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self { throw WormlinkError.unsupportedOperation("Ler chave do agente") }
}

struct AgentSignature<A: AgentAlgorithm>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { A.signatureType }
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self { throw WormlinkError.unsupportedOperation("Ler assinatura do agente") }
}

// MARK: - Strings SSH em Data

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func appendString(_ data: Data) {
        appendUInt32(UInt32(data.count))
        append(data)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard count >= 4 else { throw WormlinkError.invalidResponse }
        let value = prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        self = Data(dropFirst(4))
        return value
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard count >= length else { throw WormlinkError.invalidResponse }
        let value = Data(prefix(length))
        self = Data(dropFirst(length))
        return value
    }
}
