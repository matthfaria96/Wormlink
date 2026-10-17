// Wormlink: autenticação com chaves RSA usando rsa-sha2-512 (RFC 8332).
// O OpenSSH 8.8+ recusa assinaturas `ssh-rsa` (SHA-1), que é o que `Insecure.RSA.PrivateKey` produz.
import CCryptoBoringSSL
import Crypto
import Foundation
import NIO
import NIOSSH

extension Insecure.RSA {
    public final class SHA512PrivateKey: NIOSSHPrivateKeyProtocol {
        public static let keyPrefix = "rsa-sha2-512"
        private let base: PrivateKey

        public init(_ base: PrivateKey) { self.base = base }

        public var publicKey: NIOSSHPublicKeyProtocol { SHA512PublicKey(base._publicKey) }

        public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            let context = CCryptoBoringSSL_RSA_new()
            defer { CCryptoBoringSSL_RSA_free(context) }
            // Cópias: RSA_free libera o que for entregue a RSA_set0_key.
            let n = CCryptoBoringSSL_BN_new()!, e = CCryptoBoringSSL_BN_new()!, d = CCryptoBoringSSL_BN_new()!
            CCryptoBoringSSL_BN_copy(n, base._publicKey.modulus)
            CCryptoBoringSSL_BN_copy(e, base._publicKey.publicExponent)
            CCryptoBoringSSL_BN_copy(d, base.privateExponent)
            guard CCryptoBoringSSL_RSA_set0_key(context, n, e, d) == 1 else { throw CitadelError.signingError }

            let hash = Array(SHA512.hash(data: Array(data)))
            var out = [UInt8](repeating: 0, count: Int(CCryptoBoringSSL_RSA_size(context)))
            var length: UInt32 = UInt32(out.count)
            guard CCryptoBoringSSL_RSA_sign(NID_sha512, hash, hash.count, &out, &length, context) == 1 else {
                throw CitadelError.signingError
            }
            return SHA512Signature(rawRepresentation: out.prefix(Int(length)))
        }
    }

    /// Mesmo formato de chave `ssh-rsa`, anunciada como algoritmo `rsa-sha2-512`.
    public final class SHA512PublicKey: NIOSSHPublicKeyProtocol, NIOSSHUserAuthAlgorithmNaming {
        public static let publicKeyPrefix = "ssh-rsa"
        public var userAuthAlgorithmName: String { "rsa-sha2-512" }
        private let base: PublicKey

        init(_ base: PublicKey) { self.base = base }

        public var rawRepresentation: Data { base.rawRepresentation }

        public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }

        public func write(to buffer: inout ByteBuffer) -> Int { base.write(to: &buffer) }

        public static func read(from buffer: inout ByteBuffer) throws -> Self { throw CitadelError.unsupported }
    }

    public struct SHA512Signature: NIOSSHSignatureProtocol {
        public static let signaturePrefix = "rsa-sha2-512"
        public let rawRepresentation: Data

        public init<D: DataProtocol>(rawRepresentation: D) { self.rawRepresentation = Data(rawRepresentation) }

        public func write(to buffer: inout ByteBuffer) -> Int { buffer.writeSSHString(rawRepresentation) }

        public static func read(from buffer: inout ByteBuffer) throws -> SHA512Signature {
            guard let inner = buffer.readSSHBuffer() else { throw CitadelError.invalidSignature }
            return SHA512Signature(rawRepresentation: inner.readableBytesView)
        }
    }
}
