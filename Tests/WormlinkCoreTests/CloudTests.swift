import Foundation
import Testing
@testable import WormlinkCore

@Test func dropboxParsingAndHeaders() throws {
    let file = try #require(DropboxFileSystem.item([".tag": "file", "name": "Relatório.pdf", "path_display": "/Docs/Relatório.pdf",
                                                    "size": 1234, "client_modified": "2026-01-15T10:30:00Z"]))
    #expect(file.path == "/Docs/Relatório.pdf" && file.size == 1234 && !file.isDirectory && file.modified != nil)
    let folder = try #require(DropboxFileSystem.item([".tag": "folder", "name": "Docs", "path_display": "/Docs"]))
    #expect(folder.isDirectory && folder.size == nil)
    #expect(DropboxFileSystem.item([".tag": "deleted", "path_display": "/x"]) == nil)
    // O cabeçalho só aceita ASCII: "ó" vira \u00f3.
    #expect(DropboxFileSystem.apiArg(["path": "/Relat\u{F3}rio"]) == #"{"path":"\/Relat\u00f3rio"}"#)
    #expect(DropboxFileSystem.dropboxPath("/") == "" && DropboxFileSystem.dropboxPath("/a/") == "/a")
}

@Test func googleDriveParsing() throws {
    let doc = try #require(GoogleDriveFileSystem.item(["id": "1", "name": "a/b.txt", "mimeType": "text/plain", "size": "42",
                                                       "modifiedTime": "2026-01-15T10:30:00.123Z"], in: "/Pasta"))
    #expect(doc.path == "/Pasta/a∕b.txt" && doc.size == 42 && doc.modified != nil)   // "/" no nome não vira subpasta
    let folder = try #require(GoogleDriveFileSystem.item(["id": "2", "name": "Fotos", "mimeType": GoogleDriveFileSystem.folderType], in: "/"))
    #expect(folder.isDirectory && folder.path == "/Fotos")
    #expect(GoogleDriveFileSystem.quoted("d'água") == #"'d\'água'"#)
}

@Test func oneDriveParsingAndURLs() throws {
    let item = try #require(OneDriveFileSystem.item(["name": "nota.txt", "size": 7, "file": [:],
                                                     "fileSystemInfo": ["lastModifiedDateTime": "2026-01-15T10:30:00Z"]], in: "/Docs"))
    #expect(item.path == "/Docs/nota.txt" && item.size == 7 && item.modified != nil)
    #expect(OneDriveFileSystem.item(["name": "Docs", "folder": ["childCount": 3]], in: "/")?.isDirectory == true)
    #expect(OneDriveFileSystem.itemURL("/").absoluteString == "https://graph.microsoft.com/v1.0/me/drive/root")
    #expect(OneDriveFileSystem.itemURL("/Minhas Fotos/a#1.jpg", suffix: "content").absoluteString
            == "https://graph.microsoft.com/v1.0/me/drive/root:/Minhas%20Fotos/a%231.jpg:/content")
}

@Test func oauthLoopbackReceivesCode() async throws {
    let receiver = try LoopbackReceiver(port: 53_699)
    async let params = receiver.waitForCallback(timeout: 10)
    let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:53699/?code=abc123&state=xyz")!)
    #expect(String(decoding: data, as: UTF8.self).contains("Pode voltar ao Wormlink"))
    let received = try await params
    #expect(received["code"] == "abc123" && received["state"] == "xyz")
}

@Test func pkceEncoding() {
    #expect(Data([0xfb, 0xff, 0xfe]).base64URL == "-__-")
    #expect(OAuthFlow.randomString(64).count == 64)
    #expect("a b&c=d/é".formEncoded == "a%20b%26c%3Dd%2F%C3%A9")
}
