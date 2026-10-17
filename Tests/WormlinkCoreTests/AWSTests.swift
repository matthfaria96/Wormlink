import Foundation
import Testing
@testable import WormlinkCore

@Test func awsProfilesParsing() throws {
    let profiles = AWSProfiles(credentials: """
    [default]
    aws_access_key_id = AKIADEFAULT
    aws_secret_access_key = segredo-default

    [dev]
    aws_access_key_id=AKIADEV
    aws_secret_access_key=segredo-dev
    aws_session_token = token-dev
    """, config: """
    [default]
    region = sa-east-1

    [profile admin]
    role_arn = arn:aws:iam::123456789012:role/Admin
    source_profile = default
    mfa_serial = arn:aws:iam::123456789012:mfa/ana
    external_id = xyz
    duration_seconds = 900
    """)
    #expect(profiles.names == ["admin", "default", "dev"])
    #expect(profiles.profile("default")?.region == "sa-east-1" && profiles.profile("default")?.accessKey == "AKIADEFAULT")
    #expect(profiles.profile("dev")?.sessionToken == "token-dev")
    let admin = try #require(profiles.profile("admin"))
    #expect(admin.roleARN == "arn:aws:iam::123456789012:role/Admin" && admin.sourceProfile == "default")
    #expect(admin.mfaSerial?.hasSuffix("mfa/ana") == true && admin.externalID == "xyz" && admin.duration == 900)
}

@Test func sessionTokenIsSigned() {
    var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
    S3Signer(accessKey: "AKIA", secretKey: "s", sessionToken: "tok").sign(&request, region: "us-east-1", payloadHash: S3Signer.emptyHash)
    #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == "tok")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-security-token") == true)
}

/// AssumeRole com MFA e External ID contra o moto (simulador da AWS), depois S3 com as credenciais temporárias.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WORMLINK_MOTO"] != nil))
func assumeRoleWithMFA() async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["WORMLINK_MOTO"])
    var bookmark = Bookmark(connectionProtocol: .s3, hostname: "127.0.0.1", port: Int(endpoint.split(separator: ":").last!) ?? 5055,
                            username: "AKIAEXAMPLEBASE", path: "/")
    bookmark.plainHTTP = true
    bookmark.roleARN = "arn:aws:iam::123456789012:role/Wormlink"
    bookmark.externalID = "externo"
    bookmark.mfaSerial = "arn:aws:iam::123456789012:mfa/teste"
    bookmark.stsEndpoint = "http://\(endpoint)"
    let asked = LockedTotal()
    let trust = ConnectionTrust(hostKey: { _ in false }, certificate: { _ in false }, interactive: { challenge in
        asked.add(1)
        #expect(challenge.name == "Código MFA da AWS")
        return ["123456"]
    })
    let fs = try await S3FileSystem.connect(bookmark, secret: "base-secret", trust: trust)
    #expect(asked.value == 1)
    try await fs.createDirectory("/bucket-papel")
    #expect(try await fs.list("/").contains { $0.name == "bucket-papel" })
}

@Test func s3RegionsForCompatibleProviders() {
    let cases = [
        "s3.wasabisys.com": "us-east-1", "s3.eu-central-1.wasabisys.com": "eu-central-1",
        "s3.us-west-004.backblazeb2.com": "us-west-004", "abc123.r2.cloudflarestorage.com": "auto",
        "storage.googleapis.com": "auto", "nyc3.digitaloceanspaces.com": "nyc3", "s3.fr-par.scw.cloud": "fr-par",
        "us-east-1.linodeobjects.com": "us-east-1", "fsn1.your-objectstorage.com": "fsn1",
        "objects-us-east-1.dream.io": "us-east-1", "127.0.0.1": "us-east-1",
    ]
    for (host, region) in cases { #expect(S3FileSystem.region(forEndpoint: host) == region, "\(host)") }
}

@Test func b2EndpointDiscovery() {
    let v3 = #"{"apiInfo":{"storageApi":{"s3ApiUrl":"https://s3.us-west-004.backblazeb2.com","apiUrl":"https://api004.backblazeb2.com"}}}"#
    #expect(B2.s3Endpoint(fromAuthorization: Data(v3.utf8)) == "s3.us-west-004.backblazeb2.com")
    let v2 = #"{"s3ApiUrl":"https://s3.eu-central-003.backblazeb2.com"}"#
    #expect(B2.s3Endpoint(fromAuthorization: Data(v2.utf8)) == "s3.eu-central-003.backblazeb2.com")
}

@Test func cyberduckProfileImport() throws {
    let plist: [String: Any] = ["Protocol": "s3", "Vendor": "Exemplo", "Description": "Exemplo S3", "Default Hostname": "s3.exemplo.net",
                                "Default Port": "8443", "Hostname Configurable": false, "Username Placeholder": "Chave", "Scheme": "https"]
    let preset = try ConnectionPreset.cyberduckProfile(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    #expect(preset.connectionProtocol == .s3 && preset.hostname == "s3.exemplo.net" && preset.port == 8443 && !preset.hostnameEditable)
    #expect(preset.userLabel == "Chave" && preset.name == "Exemplo S3")
    let nc = try ConnectionPreset.cyberduckProfile(try PropertyListSerialization.data(fromPropertyList: ["Protocol": "nextcloud", "Description": "Nuvem"], format: .xml, options: 0))
    var b = Bookmark(username: "ana")
    nc.apply(to: &b)
    #expect(b.connectionProtocol == .webdavs && b.path == "/remote.php/dav/files/ana")
    // Os perfis embutidos do Cyberduck (Nextcloud) também são lidos.
    let real = try Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Reference/cyberduck/profiles/default/Nextcloud.cyberduckprofile"))
    #expect(try ConnectionPreset.cyberduckProfile(real).connectionProtocol == .webdavs)
}

/// Recursos avançados do S3 contra o moto (WORMLINK_MOTO): URL assinada, ACL, classe, criptografia, metadados,
/// versões, opções do bucket, ciclo de vida e CloudFront.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WORMLINK_MOTO"] != nil))
func s3AdvancedFeatures() async throws {
    let endpoint = try #require(ProcessInfo.processInfo.environment["WORMLINK_MOTO"])
    var bookmark = Bookmark(connectionProtocol: .s3, hostname: "127.0.0.1", port: Int(endpoint.split(separator: ":").last!) ?? 5055,
                            username: "AKIAEXAMPLEADV", path: "/")
    bookmark.plainHTTP = true
    bookmark.s3StorageClass = "STANDARD_IA"
    bookmark.s3Encryption = "AES256"
    let fs = try await S3FileSystem.connect(bookmark, secret: "segredo", trust: ConnectionTrust(hostKey: { _ in false }, certificate: { _ in false }))
    let bucket = "/avancado-\(UUID().uuidString.prefix(8).lowercased())"
    try await fs.createDirectory(bucket)
    let temp = FileManager.default.temporaryDirectory.appending(path: "wl-s3adv-\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: temp) }
    try Data("<h1>versão 1</h1>".utf8).write(to: temp)
    let path = bucket + "/site/index.html"

    // Versionamento antes do primeiro envio, para ter duas versões.
    try await fs.setVersioning(String(bucket.dropFirst()), enabled: true)
    try await fs.upload(temp, to: path) { _ in }

    // Padrões do servidor aplicados ao envio + Content-Type pela extensão.
    var info = try await fs.objectInfo(path)
    #expect(info.storageClass == "STANDARD_IA" && info.encryption == "AES256" && info.contentType == "text/html")
    #expect(info.acl == .private)

    // URL assinada baixa sem credenciais.
    let signed = try await fs.presignedURL(path, expires: 3600)
    #expect(signed.query()?.contains("X-Amz-Signature=") == true)
    let (body, response) = try await URLSession.shared.data(from: signed)
    #expect((response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: body, as: UTF8.self) == "<h1>versão 1</h1>")

    // ACL, classe e metadados.
    try await fs.setACL(path, .publicRead)
    info.storageClass = "GLACIER_IR"
    info.metadata = ["autor": "ana"]
    info.cacheControl = "max-age=60"
    try await fs.update(path, info)
    let changed = try await fs.objectInfo(path)
    #expect(changed.storageClass == "GLACIER_IR" && changed.metadata["autor"] == "ana" && changed.cacheControl == "max-age=60")
    try await fs.setACL(path, .publicRead)
    #expect(try await fs.objectInfo(path).acl == .publicRead)

    // Versões: nova versão, restaurar a primeira.
    try Data("<h1>versão 2</h1>".utf8).write(to: temp)
    try await fs.upload(temp, to: path) { _ in }
    let versions = try await fs.versions(path)
    #expect(versions.count >= 3 && versions.first?.isLatest == true)
    let oldest = try #require(versions.last)
    try await fs.restore(path, version: oldest.versionID)
    let back = FileManager.default.temporaryDirectory.appending(path: "wl-s3back-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: back) }
    try await fs.download(path, to: back) { _ in }
    #expect(try String(contentsOf: back, encoding: .utf8) == "<h1>versão 1</h1>")

    // Opções do bucket e ciclo de vida.
    let name = String(bucket.dropFirst())
    try await fs.setRequesterPays(name, enabled: true)
    try await fs.setLifecycle(name, S3Lifecycle(transitionDays: 30, transitionClass: "GLACIER", expirationDays: 365))
    let options = try await fs.bucketOptions(name)
    #expect(options.versioning == "Enabled")   // o moto aceita requestPayment mas não guarda; só a chamada é testada
    #expect(options.lifecycle == S3Lifecycle(transitionDays: 30, transitionClass: "GLACIER", expirationDays: 365))
    try await fs.setLifecycle(name, S3Lifecycle())
    #expect(try await fs.bucketOptions(name).lifecycle.isEmpty)
    try await fs.setRequesterPays(name, enabled: false)

    // CloudFront: criar, listar, invalidar, desligar.
    let created = try await fs.createDistribution(for: name)
    let listed = try await fs.distributions(for: name)
    #expect(listed.contains { $0.id == created.id })
    #expect(try await fs.invalidate(created.id, paths: ["/site/*"]).isEmpty == false)
    try await fs.setDistribution(created.id, enabled: false)
    #expect(try await fs.distributions(for: name).first { $0.id == created.id }?.enabled == false)
}

@Test func s3PresignAndACLParsing() {
    let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
    // Exemplo oficial da AWS ("Authenticating Requests: Using Query Parameters").
    let url = signer.presign(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, region: "us-east-1", expires: 86400, date: date)
    #expect(url.query()?.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404") == true)
    let grants: [[String: String]] = [["ID": "dono", "Permission": "FULL_CONTROL"],
                                      ["URI": "http://acs.amazonaws.com/groups/global/AllUsers", "Permission": "READ"]]
    #expect(S3CannedACL.from(grants: grants) == .publicRead)
    #expect(S3CannedACL.from(grants: [grants[0]]) == .private)
    #expect(S3FileSystem.contentType("a/b/Foto.JPG") == "image/jpeg" && S3FileSystem.contentType("sem-extensao") == nil)
}
