import CryptoKit
import Foundation

/// Chaves SSH do usuário (o painel "Keys" do Transmit): listar, gerar, importar e instalar num servidor.
public enum SSHKeyManager {
    public struct Key: Identifiable, Hashable, Sendable {
        public var id: String { privatePath }
        public let privatePath: String
        public let publicKey: String
        public let type: String
        public let comment: String
        public let fingerprint: String
        public let isEncrypted: Bool

        public var name: String { (privatePath as NSString).lastPathComponent }
    }

    public enum KeyType: String, CaseIterable, Sendable {
        case ed25519, rsa, ecdsa
        public var title: String { switch self { case .ed25519: "Ed25519 (recomendado)"; case .rsa: "RSA 4096"; case .ecdsa: "ECDSA P-256" } }
        var arguments: [String] {
            switch self {
            case .ed25519: ["-t", "ed25519"]
            case .rsa: ["-t", "rsa", "-b", "4096"]
            case .ecdsa: ["-t", "ecdsa", "-b", "256"]
            }
        }
    }

    /// Pasta das chaves (os testes trocam por uma temporária).
    nonisolated(unsafe) public static var folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")

    public static func list() -> [Key] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pub" }.compactMap { pub in
            let privateURL = pub.deletingPathExtension()
            guard let line = try? String(contentsOf: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  FileManager.default.fileExists(atPath: privateURL.path) else { return nil }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            let privateText = (try? String(contentsOf: privateURL, encoding: .utf8)) ?? ""
            return Key(privatePath: privateURL.path, publicKey: line, type: parts[0], comment: parts.count > 2 ? parts[2] : "",
                       fingerprint: KnownHosts.fingerprint(of: line), isEncrypted: SSHUserAuth.isEncrypted(privateText))
        }.sorted { $0.name < $1.name }
    }

    /// Gera um par novo com o ssh-keygen do sistema. Devolve a chave criada.
    @discardableResult
    public static func generate(_ type: KeyType, name: String, passphrase: String, comment: String) throws -> Key {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = folder.appending(path: name).path
        guard !FileManager.default.fileExists(atPath: path) else { throw WormlinkError.unsupportedOperation("Substituir a chave existente “\(name)”") }
        try run("/usr/bin/ssh-keygen", ["-q"] + type.arguments + ["-N", passphrase, "-C", comment, "-f", path])
        guard let key = list().first(where: { $0.name == name }) else { throw WormlinkError.invalidResponse }
        return key
    }

    /// Copia uma chave privada para a pasta (e a pública ao lado; se faltar, é derivada).
    @discardableResult
    public static func importKey(from url: URL, passphrase: String? = nil) throws -> Key {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var target = folder.appending(path: url.lastPathComponent)
        if target.standardizedFileURL != url.standardizedFileURL {
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) { target = folder.appending(path: "\(url.lastPathComponent)-\(n)"); n += 1 }
            try FileManager.default.copyItem(at: url, to: target)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let pub = URL(filePath: target.path + ".pub")
        let sourcePub = URL(filePath: url.path + ".pub")
        if !FileManager.default.fileExists(atPath: pub.path) {
            if FileManager.default.fileExists(atPath: sourcePub.path) {
                try FileManager.default.copyItem(at: sourcePub, to: pub)
            } else {
                let derived = try run("/usr/bin/ssh-keygen", ["-y", "-P", passphrase ?? "", "-f", target.path])
                try derived.write(to: pub, atomically: true, encoding: .utf8)
            }
        }
        guard let key = list().first(where: { $0.name == target.lastPathComponent }) else { throw WormlinkError.invalidBookmark }
        return key
    }

    /// "ssh-copy-id": acrescenta a chave pública ao authorized_keys do servidor (cria ~/.ssh com 700 e o arquivo com 600).
    public static func install(_ publicKey: String, on fs: any FileSystem, authorizedKeys path: String) async throws {
        let folder = RemotePath.parent(path)
        if (try? await fs.list(folder)) == nil { try await fs.createDirectory(folder) }
        try? await fs.setPermissions(folder, mode: 0o700)
        let temp = FileManager.default.temporaryDirectory.appending(path: "wormlink-authorized-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let exists = (try? await fs.list(folder))?.contains { $0.path == RemotePath.normalize(path) } ?? false
        var text = ""
        if exists {
            try await fs.download(path, to: temp) { _ in }
            text = (try? String(contentsOf: temp, encoding: .utf8)) ?? ""
        }
        let blob = publicKey.split(separator: " ").dropFirst().first.map(String.init) ?? publicKey
        guard !text.split(whereSeparator: \.isNewline).contains(where: { $0.contains(blob) }) else { return }   // já instalada
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += publicKey.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try text.write(to: temp, atomically: true, encoding: .utf8)
        try await fs.upload(temp, to: path) { _ in }
        try? await fs.setPermissions(path, mode: 0o600)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WormlinkError.commandFailed(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
