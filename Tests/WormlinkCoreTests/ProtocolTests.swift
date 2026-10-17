import Foundation
import Testing
@testable import WormlinkCore

/// Exemplos da documentação da AWS ("Signature Calculations for the Authorization Header").
@Test func sigV4MatchesAWSExamples() throws {
    let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = try #require(S3Signer.formatter("yyyyMMdd'T'HHmmss'Z'").date(from: "20130524T000000Z"))

    var get = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
    get.setValue("bytes=0-9", forHTTPHeaderField: "Range")
    signer.sign(&get, region: "us-east-1", payloadHash: S3Signer.emptyHash, date: date)
    #expect(get.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41") == true)

    var list = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
    signer.sign(&list, region: "us-east-1", payloadHash: S3Signer.emptyHash, date: date)
    #expect(list.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
        "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
}

@Test func ftpListParsing() throws {
    let unix = try #require(FTPListParser.list("-rw-r--r--   1 ana  www   1234 Jan  5  2024 relatório final.pdf", in: "/srv"))
    #expect(unix.path == "/srv/relatório final.pdf" && unix.size == 1234 && unix.mode == 0o644 && unix.owner == "ana")
    let dir = try #require(FTPListParser.list("drwxr-xr-x    2 0        0            4096 Mar 10 09:15 site", in: "/"))
    #expect(dir.isDirectory && dir.name == "site" && dir.mode == 0o755)
    let link = try #require(FTPListParser.list("lrwxrwxrwx 1 root root 7 Feb 1 10:00 www -> /var/www", in: "/"))
    #expect(link.isSymlink && link.name == "www" && link.linkTarget == "/var/www")
    let win = try #require(FTPListParser.list("01-15-26  10:30AM       <DIR>          Fotos 2026", in: "/"))
    #expect(win.isDirectory && win.name == "Fotos 2026")
    let mlsd = try #require(FTPListParser.mlsd("type=file;size=42;modify=20260115103000;UNIX.mode=0640; nota.txt", in: "/a"))
    #expect(mlsd.size == 42 && mlsd.mode == 0o640 && mlsd.path == "/a/nota.txt" && mlsd.modified != nil)
    #expect(FTPListParser.mlsd("type=cdir;modify=20260115103000; .", in: "/") == nil)
}

@Test func knownHostsHashedEntries() {
    // Linha gerada com `ssh-keygen -H` para "exemplo.com".
    let salt = Data((0..<20).map { UInt8($0) })
    let mac = KnownHostsTestSupport.hmac(salt: salt, name: "exemplo.com")
    let field = "|1|\(salt.base64EncodedString())|\(mac.base64EncodedString())"
    #expect(KnownHosts.matches(field, "exemplo.com"))
    #expect(!KnownHosts.matches(field, "outro.com"))
    #expect(KnownHosts.matches("a.com,[exemplo.com]:2222", "[exemplo.com]:2222"))
    #expect(KnownHosts.hostPattern("Exemplo.com", 2222) == "[exemplo.com]:2222")
}

import CryptoKit
enum KnownHostsTestSupport {
    static func hmac(salt: Data, name: String) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt)))
    }
}
