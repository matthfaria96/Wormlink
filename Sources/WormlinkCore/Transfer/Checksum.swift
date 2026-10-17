import CryptoKit
import Foundation

/// Soma de verificação de um arquivo, no algoritmo que o servidor sabe calcular.
public struct Checksum: Equatable, Sendable {
    public enum Algorithm: String, Sendable { case sha256, sha1, md5, dropbox }
    public let algorithm: Algorithm
    /// Hexadecimal minúsculo.
    public let value: String

    public init(_ algorithm: Algorithm, _ value: String) {
        self.algorithm = algorithm
        self.value = value.lowercased()
    }

    /// Calcula a mesma soma para um arquivo local.
    public static func local(_ url: URL, _ algorithm: Algorithm) throws -> Checksum {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch algorithm {
        case .sha256:
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return Checksum(.sha256, hash.finalize().hex)
        case .sha1:
            var hash = Insecure.SHA1()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return Checksum(.sha1, hash.finalize().hex)
        case .md5:
            var hash = Insecure.MD5()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return Checksum(.md5, hash.finalize().hex)
        case .dropbox:
            // content_hash do Dropbox: SHA-256 da concatenação dos SHA-256 de cada bloco de 4 MB.
            var blocks = Data()
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                blocks.append(contentsOf: SHA256.hash(data: chunk))
            }
            return Checksum(.dropbox, SHA256.hash(data: blocks).hex)
        }
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
