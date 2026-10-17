import Foundation
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
