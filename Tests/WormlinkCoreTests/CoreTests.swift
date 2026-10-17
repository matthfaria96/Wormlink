import Foundation
import Testing
@testable import WormlinkCore

@Test func remotePaths() {
    #expect(RemotePath.normalize("a//b/./c/../d/") == "/a/b/d")
    #expect(RemotePath.parent("/a/b") == "/a")
    #expect(RemotePath.parent("/a") == "/")
    #expect(RemotePath.name("/a/b.txt") == "b.txt")
    #expect(RemotePath.components("/a/b") == ["/", "/a", "/a/b"])
}

@Test func addressParsing() throws {
    let b = try #require(Bookmark(address: "davs://ana@exemplo.com:8443/www"))
    #expect(b.connectionProtocol == .webdavs)
    #expect(b.hostname == "exemplo.com")
    #expect(b.port == 8443)
    #expect(b.username == "ana")
    #expect(b.path == "/www")
    let plain = try #require(Bookmark(address: "servidor.local"))
    #expect(plain.connectionProtocol == .sftp && plain.port == 22)
}

@Test func cyberduckBookmark() throws {
    let plist: [String: Any] = ["Protocol": "davs", "Hostname": "nuvem.exemplo.com", "Port": "443", "Username": "bia",
                                "Nickname": "Nuvem", "UUID": "6B0A2C4E-1A2B-4C3D-8E9F-0123456789AB", "Path": "/remote.php/dav"]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let b = try Bookmark(cyberduckPlist: data)
    #expect(b.connectionProtocol == .webdavs && b.nickname == "Nuvem" && b.port == 443 && b.path == "/remote.php/dav")
    #expect(b.id.uuidString == "6B0A2C4E-1A2B-4C3D-8E9F-0123456789AB")
}

@Test func propfindParsing() {
    let xml = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
      <d:response><d:href>/dav/Fotos%202026/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
      <d:response><d:href>https://h.com/dav/a%C3%A7%C3%A3o.txt</d:href><d:propstat><d:prop><d:resourcetype/>
        <d:getcontentlength>1234</d:getcontentlength><d:getlastmodified>Wed, 14 Oct 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
    </d:multistatus>
    """
    let items = PropfindParser.parse(Data(xml.utf8))
    #expect(items.map(\.path) == ["/dav", "/dav/Fotos 2026", "/dav/ação.txt"])
    #expect(items[1].isDirectory && !items[2].isDirectory)
    #expect(items[2].size == 1234 && items[2].modified != nil)
}

@Test func localCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "wormlink-test-\(UUID().uuidString)")
    let src = root.appending(path: "src/pasta"), dst = root.appending(path: "dst")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 5000).write(to: src.appending(path: "a.bin"))
    defer { try? FileManager.default.removeItem(at: root) }
    let fs = LocalFileSystem()
    let item = try #require(try await fs.list(src.deletingLastPathComponent().path).first)
    let copier = Copier(from: fs, to: fs)
    #expect(try await copier.totalSize(of: item) == 5000)
    try await copier.copy(item, into: dst.path) { _ in }
    #expect(FileManager.default.fileExists(atPath: dst.appending(path: "pasta/a.bin").path))
}

@Test func publicURLs() {
    var b = Bookmark(connectionProtocol: .sftp, hostname: "exemplo.com", username: "ana", path: "/var/www/site")
    b.webURL = "https://exemplo.com/"
    #expect(b.publicURL(for: "/var/www/site/img/foto 1.png")?.absoluteString == "https://exemplo.com/img/foto%201.png")
    b.webURL = nil
    #expect(b.publicURL(for: "/tmp/a.txt")?.absoluteString == "sftp://ana@exemplo.com/tmp/a.txt")
}
