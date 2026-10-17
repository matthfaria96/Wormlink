import Foundation
import Testing
@testable import WormlinkCore

/// Roteiro completo contra servidores reais. Só roda com WORMLINK_SERVERS apontando para a pasta
/// com as chaves de teste (veja scripts/test-servers/start.sh); os servidores escutam em 127.0.0.1.
private let serversDir = ProcessInfo.processInfo.environment["WORMLINK_SERVERS"]
/// Configuração global dos testes, feita uma única vez (inicialização de `let` global é segura entre threads):
/// pasta de dados temporária e um ~/.ssh/config próprio com os aliases do teste do agente.
private let testSetup: Void = {
    WormlinkPaths.dataDirectory = FileManager.default.temporaryDirectory.appending(path: "wormlink-tests")
    let agent = ProcessInfo.processInfo.environment["WORMLINK_AGENT"] ?? "none"
    let config = FileManager.default.temporaryDirectory.appending(path: "wl-ssh-config-\(ProcessInfo.processInfo.processIdentifier)")
    try? """
    Host wl-direto
        HostName 127.0.0.1
        Port 2222
        User \(NSUserName())
        IdentityAgent \(agent)
    Host wl-bastiao
        HostName 127.0.0.1
        Port 2222
        IdentityAgent \(agent)
    Host wl-pulo
        HostName 127.0.0.1
        Port 2222
        IdentityAgent \(agent)
        ProxyJump \(NSUserName())@wl-bastiao
    """.write(to: config, atomically: true, encoding: .utf8)
    SSHConfig.location = config
}()

private let acceptAll = ConnectionTrust(hostKey: { _ in true }, certificate: { _ in true },
                                        passphrase: { _ in ("segredo", false) })

private func bookmarks() -> [(String, Bookmark, String?)] {
    guard let dir = serversDir else { return [] }
    var sftpEd = Bookmark(connectionProtocol: .sftp, hostname: "127.0.0.1", port: 2222, username: NSUserName())
    sftpEd.keyFile = dir + "/ssh/client_ed25519"
    sftpEd.path = dir + "/root"
    var sftpRSA = sftpEd
    sftpRSA.keyFile = dir + "/ssh/client_rsa"
    var sftpECDSA = sftpEd
    sftpECDSA.keyFile = dir + "/ssh/client_ecdsa"
    var sftpEncrypted = sftpEd
    sftpEncrypted.keyFile = dir + "/ssh/client_enc"
    var s3 = Bookmark(connectionProtocol: .s3, hostname: "127.0.0.1", port: 9000, username: "WLACCESS", path: "/bucket-um")
    s3.plainHTTP = true
    return [
        ("SFTP ed25519", sftpEd, nil),
        ("SFTP RSA", sftpRSA, nil),
        ("SFTP ECDSA", sftpECDSA, nil),
        ("SFTP chave cifrada", sftpEncrypted, nil),
        ("FTP", Bookmark(connectionProtocol: .ftp, hostname: "127.0.0.1", port: 2121, username: "wl"), "senha"),
        ("FTP-TLS", Bookmark(connectionProtocol: .ftps, hostname: "127.0.0.1", port: 2122, username: "wl"), "senha"),
        ("WebDAV", Bookmark(connectionProtocol: .webdav, hostname: "127.0.0.1", port: 8080, username: "wl"), "senha"),
        ("S3", s3, "WLSECRET1234"),
    ] + azure() + swift() + smb() + proftpd()
}

/// ProFTPD com mod_tls exigindo reaproveitamento da sessão TLS nos dados (o padrão dele e do vsftpd).
/// WORMLINK_PROFTPD=<porta>, usuário wl / senha.
private func proftpd() -> [(String, Bookmark, String?)] {
    guard let port = ProcessInfo.processInfo.environment["WORMLINK_PROFTPD"].flatMap(Int.init) else { return [] }
    return [("FTPS ProFTPD (reuso de sessão TLS)", Bookmark(connectionProtocol: .ftps, hostname: "127.0.0.1", port: port, username: "wl"), "senha")]
}

/// SMB via o cliente do macOS contra o impacket (smbserver.py, porta 4445, compartilhamento COMPARTILHADO).
private func smb() -> [(String, Bookmark, String?)] {
    guard ProcessInfo.processInfo.environment["WORMLINK_SMB"] != nil else { return [] }
    return [("SMB", Bookmark(connectionProtocol: .smb, hostname: "127.0.0.1", port: 4445, username: "wl", path: "/COMPARTILHADO"), "senha")]
}

/// Swift simulado (scripts/test-servers/swift_mock.py) com Keystone v3 e TempAuth v1.
private func swift() -> [(String, Bookmark, String?)] {
    guard ProcessInfo.processInfo.environment["WORMLINK_SWIFT"] != nil else { return [] }
    var v3 = Bookmark(connectionProtocol: .swift, hostname: "127.0.0.1", port: 8090, username: "projeto:wl", path: "/conteiner")
    v3.plainHTTP = true
    v3.swiftAuthPath = "/v3"
    var v1 = v3
    v1.swiftAuthPath = "/auth/v1.0"
    return [("Swift Keystone 3", v3, "senha"), ("Swift TempAuth", v1, "senha")]
}

/// Azure só entra com o Azurite rodando (WORMLINK_AZURITE=1), com a conta e a chave públicas do emulador.
private func azure() -> [(String, Bookmark, String?)] {
    guard ProcessInfo.processInfo.environment["WORMLINK_AZURITE"] != nil else { return [] }
    var bookmark = Bookmark(connectionProtocol: .azure, hostname: "127.0.0.1", port: 10000, username: "devstoreaccount1",
                            path: "/conteiner-teste")
    bookmark.plainHTTP = true
    return [("Azure", bookmark, "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==")]
}

@Test(.enabled(if: serversDir != nil), arguments: bookmarks().map(\.0))
func protocolRoundTrip(_ name: String) async throws {
    _ = testSetup
    let (_, bookmark, password) = try #require(bookmarks().first { $0.0 == name })
    if bookmark.connectionProtocol == .swift {
        let root = try await SwiftFileSystem.connect({ var b = bookmark; b.path = "/"; return b }(), password: password ?? "")
        try await root.createDirectory("/conteiner")
    }
    if bookmark.connectionProtocol == .azure {
        // O contêiner precisa existir antes de conectar na pasta dele.
        let root = try AzureFileSystem(bookmark: { var b = bookmark; b.path = "/"; return b }(), secret: password ?? "")
        if try await !root.list("/").contains(where: { $0.name == "conteiner-teste" }) { try await root.createDirectory("/conteiner-teste") }
    }
    let fs = try await Connector.connect(bookmark, password: password, trust: acceptAll)

    let base = RemotePath.join(fs.homePath, "wormlink-teste-\(UUID().uuidString.prefix(6))")
    // No S3 as pastas surgem dos arquivos; o rclone não aceita marcadores "pasta/".
    if bookmark.connectionProtocol != .s3 {
        try await fs.createDirectory(base)
        try await fs.createDirectory(RemotePath.join(base, "sub pasta"))
    }

    // 3 MB aleatórios (vários blocos SFTP e pacotes FTP).
    let local = FileManager.default.temporaryDirectory.appending(path: "wl-up-\(UUID().uuidString)")
    let payload = Data((0..<(3 * 1024 * 1024 + 123)).map { _ in UInt8.random(in: 0...255) })
    try payload.write(to: local)
    defer { try? FileManager.default.removeItem(at: local) }
    let remote = RemotePath.join(base, "sub pasta/arquivo ação.bin")
    try await fs.upload(local, to: remote) { _ in }

    let listed = try await fs.list(RemotePath.join(base, "sub pasta"))
    let item = try #require(listed.first { $0.name == "arquivo ação.bin" }, "listagem: \(listed.map(\.name))")
    #expect(item.size == Int64(payload.count))

    let back = FileManager.default.temporaryDirectory.appending(path: "wl-down-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: back) }
    try await fs.download(remote, to: back) { _ in }
    #expect(try Data(contentsOf: back) == payload)

    // Retomada: um download pela metade termina sem baixar de novo o começo.
    let mac = LocalFileSystem()
    let half = FileManager.default.temporaryDirectory.appending(path: "wl-half-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: half) }
    try payload.prefix(1_000_000).write(to: half.appending(path: item.name))
    if fs.canResumeDownloads {
        try await Copier(from: fs, to: mac, resolver: { _, _ in .resume }).copy(item, into: half.path) { _ in }
        #expect(try Data(contentsOf: half.appending(path: item.name)) == payload)
    }
    if fs.canResumeUploads {
        // Envio retomado: trunca o remoto e completa a partir do que já existe.
        let partial = half.appending(path: "parcial.bin")
        try payload.prefix(700_000).write(to: partial)
        try await fs.upload(partial, to: remote) { _ in }
        let source = try #require(try await mac.list(half.path).first { $0.name == item.name })
        try await Copier(from: mac, to: fs, resolver: { _, _ in .resume }).copy(source, into: RemotePath.parent(remote)) { _ in }
        try await fs.download(remote, to: back) { _ in }
        #expect(try Data(contentsOf: back) == payload)
    }

    // Sincronização: um arquivo novo localmente é o único a ir para o servidor.
    try Data("novo".utf8).write(to: half.appending(path: "novo.txt"))
    try? FileManager.default.removeItem(at: half.appending(path: "parcial.bin"))
    let mirror = RemotePath.join(base, "espelho")
    if bookmark.connectionProtocol != .s3 { try await fs.createDirectory(mirror) }
    let sync = Synchronizer(from: mac, to: fs)
    let first = try await sync.compare(half.path, mirror)
    #expect(Set(first.map { $0.relativePath }) == [item.name, "novo.txt"])
    try await sync.apply(first, sourceRoot: half.path, destinationRoot: mirror, progress: { _ in })
    let second = try await sync.compare(half.path, mirror)
    #expect(second.isEmpty, "\(second.map { "\($0.relativePath) \($0.kind) \(String(describing: $0.source?.modified)) \(String(describing: $0.destination?.modified))" })")

    // Envio atômico + verificação (checksum do servidor quando houver, senão tamanho).
    var careful = Copier(from: mac, to: fs, resolver: { _, _ in .overwrite })
    careful.atomicUploads = true
    careful.verifyChecksums = true
    let source = try #require(try await mac.list(half.path).first { $0.name == item.name })
    try await careful.copy(source, into: RemotePath.parent(remote)) { _ in }
    let names = try await fs.list(RemotePath.parent(remote)).map(\.name)
    #expect(!names.contains { $0.hasSuffix(".wormlink-part") }, "\(names)")
    var back2 = Copier(from: fs, to: mac, resolver: { _, _ in .overwrite })
    back2.verifyChecksums = true
    try await back2.copy(try #require(try await fs.list(RemotePath.parent(remote)).first { $0.path == remote }), into: half.path) { _ in }
    if fs.supportsCommands, bookmark.connectionProtocol == .sftp {
        #expect(try await fs.remoteChecksum(remote)?.value == (try Checksum.local(half.appending(path: item.name), .sha256)).value)
    }

    let renamed = RemotePath.join(base, "sub pasta/renomeado.bin")
    try await fs.move(remote, to: renamed)
    let afterRename = try await fs.list(RemotePath.join(base, "sub pasta")).map(\.name)
    #expect(afterRename == ["renomeado.bin"], "\(afterRename)")

    if fs.supportsPermissions {
        try await fs.setPermissions(renamed, mode: 0o640)
        let after = try await fs.list(RemotePath.join(base, "sub pasta")).first
        #expect(after?.mode == 0o640, "\(String(describing: after))")
    }

    // Duplicar no próprio servidor ("renomeado 2.bin").
    let original = try #require(try await fs.list(RemotePath.join(base, "sub pasta")).first)
    try await Copier(from: fs, to: fs, resolver: { _, _ in .rename }).copy(original, into: RemotePath.join(base, "sub pasta")) { _ in }
    #expect(try await fs.list(RemotePath.join(base, "sub pasta")).map(\.name).sorted() == ["renomeado 2.bin", "renomeado.bin"])
    if let copy = try await fs.list(RemotePath.join(base, "sub pasta")).first(where: { $0.name == "renomeado 2.bin" }) {
        try await fs.delete(copy)
    }

    // Comandos: shell via SSH (compactar e descompactar) ou comando FTP bruto.
    if fs is SFTPFileSystem {
        let folder = try #require(try await fs.list(base).first { $0.name == "sub pasta" })
        _ = try await fs.execute(Archiver.compressCommand([folder], in: base, to: "sub.tar.gz", .tarGz))
        let archive = try #require(try await fs.list(base).first { $0.name == "sub.tar.gz" })
        _ = try await fs.execute(try #require(Archiver.expandCommand(archive, in: base)))
        try await fs.delete(archive)
    } else if fs is FTPFileSystem {
        #expect(try await fs.execute("SYST").contains("UNIX"))
    }

    try await fs.createFile(RemotePath.join(base, "vazio.txt"))
    let top = try await fs.list(base).map(\.name).sorted()
    #expect(top == ["espelho", "sub pasta", "vazio.txt"])

    // Apagar a pasta apaga tudo dentro.
    let folder = try #require(try await fs.list(fs.homePath).first { $0.path == base })
    try await fs.delete(folder)
    #expect(try await fs.list(fs.homePath).contains { $0.path == base } == false)
    await fs.disconnect()   // espera: no SMB isso desmonta o compartilhamento
}

/// ~/.ssh/config (alias + agente) e ProxyJump contra o sshd de teste. Precisa de um ssh-agent
/// com as chaves de teste em WORMLINK_AGENT (o start.sh não sobe; veja o teste para o comando).
@Test(.enabled(if: serversDir != nil && ProcessInfo.processInfo.environment["WORMLINK_AGENT"] != nil))
func sshConfigAgentAndProxyJump() async throws {
    _ = testSetup
    for alias in ["wl-direto", "wl-pulo"] {
        // Só o alias: endereço, porta, usuário e chave vêm do config e do agente.
        let fs = try await Connector.connect(Bookmark(connectionProtocol: .sftp, hostname: alias, path: serversDir! + "/root"),
                                             password: nil, trust: acceptAll)
        #expect(try await fs.list(fs.homePath).isEmpty == false, "\(alias)")
        await fs.disconnect()
    }
}

/// Keyboard-interactive em duas etapas (senha + código 2FA) contra scripts/test-servers/kbdint.py.
@Test(.enabled(if: serversDir != nil && ProcessInfo.processInfo.environment["WORMLINK_KBDINT"] != nil))
func keyboardInteractiveTwoFactor() async throws {
    _ = testSetup
    let asked = LockedTotal()
    let trust = ConnectionTrust(hostKey: { _ in true }, certificate: { _ in true }, interactive: { challenge in
        asked.add(1)
        #expect(challenge.prompts.map(\.text) == ["Verification code: "] && challenge.prompts[0].echo)
        #expect(challenge.instruction.contains("autenticador"))
        return ["123456"]
    })
    let bookmark = Bookmark(connectionProtocol: .sftp, hostname: "127.0.0.1", port: 2223, username: "wl", path: "/")
    let fs = try await Connector.connect(bookmark, password: "senha", trust: trust)
    _ = try await fs.list("/")
    await fs.disconnect()
    #expect(asked.value == 1)   // a senha foi respondida sozinha; só o código foi perguntado

    // Código errado: falha de autenticação, sem travar.
    let wrong = ConnectionTrust(hostKey: { _ in true }, certificate: { _ in true }, interactive: { _ in ["000000"] })
    await #expect(throws: WormlinkError.authenticationFailed) {
        _ = try await Connector.connect(bookmark, password: "senha", trust: wrong)
    }
}

/// Anuncia um SFTP falso com o dns-sd e espera o navegador Bonjour encontrá-lo (WORMLINK_BONJOUR=1).
@Test(.enabled(if: ProcessInfo.processInfo.environment["WORMLINK_BONJOUR"] != nil))
@MainActor func bonjourDiscovery() async throws {
    let name = "Wormlink Teste \(Int.random(in: 1000...9999))"
    let advert = Process()
    advert.executableURL = URL(filePath: "/usr/bin/dns-sd")
    advert.arguments = ["-R", name, "_sftp-ssh._tcp", "local.", "2222", "u=tester", "path=/srv"]
    advert.standardOutput = Pipe()
    try advert.run()
    defer { advert.terminate() }
    let browser = BonjourBrowser()
    browser.start()
    defer { browser.stop() }
    var match: Bookmark?
    for _ in 0..<100 {
        match = browser.servers.first { $0.nickname == name }
        if match != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let found = try #require(match)
    #expect(found.connectionProtocol == .sftp && found.port == 2222 && found.username == "tester" && found.path == "/srv")
    #expect(found.hostname.hasSuffix(".local"))
    #expect(BonjourBrowser.bookmark(name: name, type: "_sftp-ssh._tcp", proto: .sftp, host: "x", port: 1, txt: [:]).id == found.id)
}

/// Ajustes por servidor no FTP: LIST em vez de MLSD, modo ASCII em .txt (binário no resto) e tempo limite.
@Test(.enabled(if: serversDir != nil))
func ftpServerSpecificOptions() async throws {
    _ = testSetup
    // "localhost": os outros testes de FTP usam 127.0.0.1, e o Transcript é separado por endereço.
    var bookmark = Bookmark(connectionProtocol: .ftp, hostname: "localhost", port: 2121, username: "wl")
    bookmark.ftpUseMLSD = false
    bookmark.ftpASCIIMode = true
    bookmark.timeout = 7
    let fs = try await Connector.connect(bookmark, password: "senha", trust: acceptAll)
    defer { Task { await fs.disconnect() } }
    let base = RemotePath.join(fs.homePath, "opcoes-\(UUID().uuidString.prefix(6))")
    try await fs.createDirectory(base)
    let start = Transcript.shared.snapshot.last?.id ?? 0

    let temp = FileManager.default.temporaryDirectory.appending(path: "wl-ascii-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let text = "linha 1\nlinha 2\n\nfim\n"
    let binary = Data([0, 13, 10, 13, 255, 10])
    try Data(text.utf8).write(to: temp.appending(path: "leia.txt"))
    try binary.write(to: temp.appending(path: "dado.bin"))
    try await fs.upload(temp.appending(path: "leia.txt"), to: RemotePath.join(base, "leia.txt")) { _ in }
    try await fs.upload(temp.appending(path: "dado.bin"), to: RemotePath.join(base, "dado.bin")) { _ in }

    let names = try await fs.list(base).map(\.name).sorted()
    #expect(names == ["dado.bin", "leia.txt"])
    try await fs.download(RemotePath.join(base, "leia.txt"), to: temp.appending(path: "volta.txt")) { _ in }
    try await fs.download(RemotePath.join(base, "dado.bin"), to: temp.appending(path: "volta.bin")) { _ in }
    #expect(try String(contentsOf: temp.appending(path: "volta.txt"), encoding: .utf8) == text)
    #expect(try Data(contentsOf: temp.appending(path: "volta.bin")) == binary)

    let sent = Transcript.shared.snapshot.filter { $0.id > start && !$0.isReply && $0.host == "localhost" }.map(\.text)
    #expect(sent.contains { $0.hasPrefix("LIST") } && !sent.contains { $0.hasPrefix("MLSD") })
    #expect(sent.filter { $0 == "TYPE A" }.count == 2)   // só o .txt, na ida e na volta

    for item in try await fs.list(base) { try await fs.delete(item) }
    try await fs.delete(FileItem(path: base, isDirectory: true))
}

/// Erros do SFTP chegam com texto legível.
@Test(.enabled(if: serversDir != nil))
func sftpReadableErrors() async throws {
    _ = testSetup
    let (_, bookmark, _) = try #require(bookmarks().first)
    let fs = try await Connector.connect(bookmark, password: nil, trust: acceptAll)
    defer { Task { await fs.disconnect() } }
    do {
        _ = try await fs.list("/nao/existe/mesmo")
        Issue.record("listou uma pasta que não existe")
    } catch {
        #expect(error.localizedDescription.hasPrefix("Arquivo ou pasta não encontrado"), "\(error.localizedDescription)")
    }
}

/// Envio acima do limite do Swift: segmentos + manifesto (SLO), com limites pequenos para o teste.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WORMLINK_SWIFT"] != nil))
func swiftLargeObjectUpload() async throws {
    var bookmark = Bookmark(connectionProtocol: .swift, hostname: "127.0.0.1", port: 8090, username: "projeto:wl", path: "/")
    bookmark.plainHTTP = true
    bookmark.swiftAuthPath = "/auth/v1.0"
    let fs = try await SwiftFileSystem.connect(bookmark, password: "senha")
    try await fs.createDirectory("/grandes")
    let (threshold, segment) = (SwiftFileSystem.largeObjectThreshold, SwiftFileSystem.segmentSize)
    SwiftFileSystem.largeObjectThreshold = 1_000_000
    SwiftFileSystem.segmentSize = 400_000
    defer { SwiftFileSystem.largeObjectThreshold = threshold; SwiftFileSystem.segmentSize = segment }

    let local = FileManager.default.temporaryDirectory.appending(path: "wl-slo-\(UUID().uuidString)")
    let back = local.appendingPathExtension("volta")
    defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: back) }
    let data = Data((0..<1_300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try data.write(to: local)
    try await fs.upload(local, to: "/grandes/video.bin") { _ in }

    #expect(try await fs.list("/grandes").first { $0.name == "video.bin" }?.size == 1_300_000)
    try await fs.download("/grandes/video.bin", to: back) { _ in }
    #expect(try Data(contentsOf: back) == data)

    try await fs.move("/grandes/video.bin", to: "/grandes/renomeado.bin")
    try await fs.download("/grandes/renomeado.bin", to: back) { _ in }
    #expect(try Data(contentsOf: back) == data)

    try await fs.delete(FileItem(path: "/grandes/renomeado.bin", isDirectory: false))
    // Os segmentos saem junto com o manifesto: não sobra nem a pasta .file-segments.
    #expect(try await fs.list("/grandes").isEmpty)
}
