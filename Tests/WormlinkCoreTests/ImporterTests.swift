import Foundation
import Testing
@testable import WormlinkCore

@Test func transmitMetadataImport() {
    let b = ServerImporter.transmit(["com_panic_transmit_nickname": "AynThor", "com_panic_transmit_port": 2221,
                                     "com_panic_transmit_protocol": "FTP", "com_panic_transmit_server": "192.168.3.125",
                                     "com_panic_transmit_uniqueIdentifier": "4BF9CCA9-52E6-4E62-95B9-64111150F7FC"])
    #expect(b?.nickname == "AynThor" && b?.connectionProtocol == .ftp && b?.port == 2221 && b?.hostname == "192.168.3.125")
    #expect(b?.id.uuidString == "4BF9CCA9-52E6-4E62-95B9-64111150F7FC")
    #expect(ServerImporter.transmit(["com_panic_transmit_protocol": "SFTP", "com_panic_transmit_server": "x"])?.connectionProtocol == .sftp)
    #expect(ServerImporter.transmit(["com_panic_transmit_protocol": "FTP with TLS/SSL", "com_panic_transmit_server": "x"])?.connectionProtocol == .ftps)
    #expect(ServerImporter.transmit(["com_panic_transmit_protocol": "WebDAV HTTPS", "com_panic_transmit_server": "x"])?.connectionProtocol == .webdavs)
}

@Test func fileZillaImport() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <FileZilla3><Servers>
      <Server><Host>ftp.exemplo.com</Host><Port>21</Port><Protocol>4</Protocol><User>ana</User>
        <Pass encoding="base64">c2VuaGE=</Pass><Name>Site</Name><RemoteDir>1 0 3 www 7 projeto</RemoteDir></Server>
      <Folder expanded="1">Clientes
        <Server><Host>sftp.cliente.com</Host><Port>2222</Port><Protocol>1</Protocol><User>bia</User><Name>Cliente A</Name></Server>
      </Folder>
    </Servers></FileZilla3>
    """
    let servers = try ServerImporter.fileZilla(Data(xml.utf8))
    #expect(servers.count == 2)
    #expect(servers[0].bookmark.connectionProtocol == .ftps && servers[0].password == "senha" && servers[0].bookmark.path == "/www/projeto")
    #expect(servers[1].bookmark.connectionProtocol == .sftp && servers[1].bookmark.port == 2222 && servers[1].bookmark.group == "Clientes")
}

@Test func winSCPImport() {
    let ini = """
    [Configuration\\Interface]
    Foo=1
    [Sessions\\Clientes/Loja%20Web]
    HostName=loja.exemplo.com
    PortNumber=22
    UserName=deploy
    FSProtocol=2
    RemoteDirectory=/var/www
    [Sessions\\Backup FTP]
    HostName=backup.exemplo.com
    FSProtocol=5
    Ftps=3
    """
    let servers = ServerImporter.winSCP(ini)
    #expect(servers.count == 2)
    #expect(servers[0].bookmark.nickname == "Loja Web" && servers[0].bookmark.group == "Clientes" && servers[0].bookmark.connectionProtocol == .sftp)
    #expect(servers[0].bookmark.path == "/var/www" && servers[0].bookmark.username == "deploy")
    #expect(servers[1].bookmark.connectionProtocol == .ftps)
}

@Test func backupRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "wl-\(UUID().uuidString).wormlinkservers")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = [Bookmark(nickname: "A", connectionProtocol: .sftp, hostname: "a.com"), Bookmark(nickname: "B", connectionProtocol: .s3)]
    try ServerBackup(bookmarks: original, includePasswords: false).write(to: url)
    let restored = try ServerBackup.read(url)
    #expect(restored.bookmarks == original && restored.passwords == nil)
}

@Test func sshKeyManagement() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "wl-keys-mgr-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    SSHKeyManager.folder = dir   // nunca o ~/.ssh real nos testes
    let generated = try SSHKeyManager.generate(.ed25519, name: "id_teste", passphrase: "", comment: "teste@wormlink")
    #expect(generated.type == "ssh-ed25519" && generated.comment == "teste@wormlink" && !generated.isEncrypted)
    #expect(generated.fingerprint.hasPrefix("SHA256:"))
    try SSHKeyManager.generate(.rsa, name: "id_cifrada", passphrase: "segredo", comment: "c")
    #expect(SSHKeyManager.list().first { $0.name == "id_cifrada" }?.isEncrypted == true)

    // Importar uma chave sem .pub deriva a pública.
    let outside = FileManager.default.temporaryDirectory.appending(path: "wl-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.copyItem(atPath: generated.privatePath, toPath: outside.appending(path: "trazida").path)
    let imported = try SSHKeyManager.importKey(from: outside.appending(path: "trazida"))
    #expect(imported.publicKey.hasPrefix("ssh-ed25519 ") && imported.fingerprint == generated.fingerprint)

    // Instalar duas vezes não duplica a linha.
    let fs = LocalFileSystem()
    let authorized = dir.appending(path: "remoto/.ssh/authorized_keys").path
    try FileManager.default.createDirectory(at: dir.appending(path: "remoto"), withIntermediateDirectories: true)
    try await SSHKeyManager.install(generated.publicKey, on: fs, authorizedKeys: authorized)
    try await SSHKeyManager.install(generated.publicKey, on: fs, authorizedKeys: authorized)
    let lines = try String(contentsOfFile: authorized, encoding: .utf8).split(whereSeparator: \.isNewline)
    #expect(lines.count == 1)
    let mode = (try FileManager.default.attributesOfItem(atPath: authorized)[.posixPermissions] as? NSNumber)?.intValue
    #expect(mode == 0o600)
}

@Test func ftpASCIIConversions() {
    var previous: UInt8 = 0
    #expect(FTPConnection.unixToNetwork(Data("a\nb\r\nc\r".utf8), previous: &previous) == Data("a\r\nb\r\nc\r".utf8))
    #expect(FTPConnection.unixToNetwork(Data("\nd".utf8), previous: &previous) == Data("\nd".utf8))   // CR|LF entre blocos
    var config = FTPConfig(host: "h", port: 21, username: "", password: "", security: .none, certificateTrust: { _ in false })
    config.asciiExtensions = ["txt", "html"]
    #expect(config.isASCII("/a/LEIA.TXT") && !config.isASCII("/a/foto.jpg"))
    var b = Bookmark()
    b.encoding = "iso-8859-1"
    #expect(b.stringEncoding == .isoLatin1)
    b.encoding = "windows-1252"
    #expect(b.stringEncoding == .windowsCP1252)
}

@Test func smbExistingMountMatching() {
    #expect(SMBFileSystem.matches("//wl@127.0.0.1:4445/COMPARTILHADO", host: "127.0.0.1", port: 4445, share: "compartilhado"))
    #expect(SMBFileSystem.matches("//NAS.local/Fotos%20Antigas", host: "nas.local", port: 445, share: "Fotos Antigas"))
    #expect(!SMBFileSystem.matches("//wl@127.0.0.1:4445/OUTRO", host: "127.0.0.1", port: 4445, share: "COMPARTILHADO"))
    #expect(!SMBFileSystem.matches("//wl@127.0.0.1/COMPARTILHADO", host: "127.0.0.1", port: 4445, share: "COMPARTILHADO"))
}
