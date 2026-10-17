import Foundation
import NIOSSH
import Testing
@testable import WormlinkCore

/// Regressões dos bugs achados na auditoria.

@Test func plusSignsAreEncodedInQueries() {
    var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
    c.setQuery([URLQueryItem(name: "q", value: "name = 'C++.txt'")])
    #expect(c.percentEncodedQuery?.contains("C%2B%2B.txt") == true)
    #expect(c.url?.absoluteString.contains("+") == false)
}

@Test func asciiModeSeesThroughAtomicTemporaryNames() {
    var config = FTPConfig(host: "h", port: 21, username: "", password: "", security: .none, certificateTrust: { _ in false })
    config.asciiExtensions = ["txt", "htaccess"]
    #expect(config.isASCII("/www/leia.txt"))
    #expect(config.isASCII("/www/.leia.txt.wormlink-part"))
    #expect(config.isASCII("/www/.htaccess"))
    #expect(config.isASCII("/www/..htaccess.wormlink-part"))
    #expect(!config.isASCII("/www/foto.jpg"))
    #expect(!config.isASCII("/www/.foto.jpg.wormlink-part"))
}

@Test func syncKeepsFilesDifferingOnlyInCase() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "wl-case-\(UUID().uuidString)")
    let src = root.appending(path: "src"), dst = root.appending(path: "dst")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("novo".utf8).write(to: src.appending(path: "Readme.md"))
    try Data("velho".utf8).write(to: dst.appending(path: "README.md"))
    var options = SyncOptions()
    options.deleteOrphans = true
    let changes = try await Synchronizer(from: LocalFileSystem(), to: LocalFileSystem(), options: options).compare(src.path, dst.path)
    #expect(!changes.contains { $0.kind == .delete })
}

@Test func cloudBookmarksHaveTheirOwnKeychainAccount() {
    var a = Bookmark(nickname: "A", connectionProtocol: .dropbox, hostname: "api.dropboxapi.com")
    var b = a
    b.id = UUID()
    a.username = ""
    #expect(Keychain.account(for: a) != Keychain.account(for: b))
    let sftp = Bookmark(nickname: "S", connectionProtocol: .sftp, hostname: "h", username: "eu")
    #expect(Keychain.account(for: sftp) == "eu")
}

@Test func smbShareNamesWithSpaces() {
    let output = """
        Share                                           Type    Comments
        -------------------------------
        Meus Arquivos                                   Disk    pasta da família
        IPC$                                            Pipe    IPC Service
        ADMIN$                                          Disk    Remote Admin
        Fotos                                           Disk
        """
    #expect(SMBFileSystem.parseShares(output) == ["Meus Arquivos", "Fotos"])
}

@Test(arguments: [256, 384, 521]) func ecdsaKeysLoad(bits: Int) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "wl-ecdsa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for passphrase in ["", "segredo"] {
        let file = folder.appending(path: "id_ecdsa_\(bits)_\(passphrase.isEmpty ? "plain" : "enc")")
        let keygen = Process()
        keygen.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ecdsa", "-b", "\(bits)", "-N", passphrase, "-C", "", "-f", file.path]
        try keygen.run()
        keygen.waitUntilExit()
        let text = try String(contentsOf: file, encoding: .utf8)
        let key = try #require(SSHUserAuth.loadKey(text, passphrase: passphrase.isEmpty ? nil : passphrase))
        let expected = try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        #expect(String(openSSHPublicKey: key.publicKey) == expected)
        if !passphrase.isEmpty { #expect(SSHUserAuth.loadKey(text, passphrase: "errada") == nil) }
    }
}
