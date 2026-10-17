import Foundation
import Testing
@testable import WormlinkCore

private func tempTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "wl-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Test func skipRulesUseGlobs() {
    let rules = SkipRules(patterns: ["*.tmp", ".DS_Store", "node_modules"])
    #expect(rules.skips("a.tmp") && rules.skips(".DS_Store") && rules.skips("node_modules"))
    #expect(!rules.skips("a.txt"))
}

@Test func syncPlansAndApplies() async throws {
    let root = try tempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appending(path: "src"), dst = root.appending(path: "dst")
    try write(src.appending(path: "igual.txt"), "mesmo")
    try write(src.appending(path: "mudou.txt"), "versão nova e maior")
    try write(src.appending(path: "novo/dentro.txt"), "x")
    try write(src.appending(path: "lixo.tmp"), "ignorar")
    try write(dst.appending(path: "igual.txt"), "mesmo")
    try write(dst.appending(path: "mudou.txt"), "velha")
    try write(dst.appending(path: "orfao.txt"), "sobra")
    // Mesma data nos iguais, para só o tamanho decidir.
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    for f in ["igual.txt"] {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: src.appending(path: f).path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dst.appending(path: f).path)
    }

    let fs = LocalFileSystem()
    var options = SyncOptions()
    options.deleteOrphans = true
    options.skip = SkipRules(patterns: ["*.tmp"])
    let sync = Synchronizer(from: fs, to: fs, options: options)
    let changes = try await sync.compare(src.path, dst.path)
    let summary = Dictionary(uniqueKeysWithValues: changes.map { ($0.relativePath, $0.kind) })
    #expect(summary == ["mudou.txt": .update, "novo": .add, "orfao.txt": .delete])

    try await sync.apply(changes, sourceRoot: src.path, destinationRoot: dst.path, progress: { _ in })
    #expect(try String(contentsOf: dst.appending(path: "mudou.txt"), encoding: .utf8) == "versão nova e maior")
    #expect(FileManager.default.fileExists(atPath: dst.appending(path: "novo/dentro.txt").path))
    #expect(!FileManager.default.fileExists(atPath: dst.appending(path: "lixo.tmp").path))
    // Órfãos locais vão para o Lixo.
    #expect(!FileManager.default.fileExists(atPath: dst.appending(path: "orfao.txt").path))
    // Datas preservadas: uma nova comparação não encontra nada.
    #expect(try await sync.compare(src.path, dst.path).isEmpty)
}

@Test func conflictsRenameSkipAndResume() async throws {
    let root = try tempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let src = root.appending(path: "src"), dst = root.appending(path: "dst")
    let payload = String(repeating: "0123456789", count: 50_000)
    try write(src.appending(path: "grande.bin"), payload)
    try write(dst.appending(path: "grande.bin"), String(payload.prefix(123_456)))
    let fs = LocalFileSystem()
    let item = try #require(try await fs.list(src.path).first)

    let resume = Copier(from: fs, to: fs, resolver: { _, _ in .resume })
    let received = LockedTotal()
    try await resume.copy(item, into: dst.path) { received.add($0) }
    #expect(try String(contentsOf: dst.appending(path: "grande.bin"), encoding: .utf8) == payload)
    #expect(received.value == Int64(payload.utf8.count))   // o já existente conta como feito

    let rename = Copier(from: fs, to: fs, resolver: { _, _ in .rename })
    try await rename.copy(item, into: dst.path) { _ in }
    #expect(FileManager.default.fileExists(atPath: dst.appending(path: "grande 2.bin").path))

    try write(src.appending(path: "grande.bin"), "outro conteúdo")
    let skip = Copier(from: fs, to: fs, resolver: { _, _ in .skip })
    try await skip.copy(try #require(try await fs.list(src.path).first), into: dst.path) { _ in }
    #expect(try String(contentsOf: dst.appending(path: "grande.bin"), encoding: .utf8) == payload)
}

final class LockedTotal: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ n: Int64) { lock.withLock { total += n } }
    var value: Int64 { lock.withLock { total } }
}

@Test func encryptedOpenSSHKeys() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "wl-keys-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (type, extra) in [("ed25519", [String]()), ("rsa", ["-b", "2048"])] {
        let file = dir.appending(path: type).path
        let keygen = Process()
        keygen.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", type] + extra + ["-N", "segredo", "-f", file]
        try keygen.run()
        keygen.waitUntilExit()
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(SSHUserAuth.isEncrypted(text), "\(type)")
        #expect(SSHUserAuth.loadKey(text, passphrase: nil) == nil)
        #expect(SSHUserAuth.loadKey(text, passphrase: "errada") == nil)
        #expect(SSHUserAuth.loadKey(text, passphrase: "segredo") != nil, "\(type)")
    }
}

@Test func bandwidthLimiterPacesTransfers() async {
    let limiter = BandwidthLimiter()
    limiter.setLimit(1_000_000, for: .download)   // 1 MB/s
    let start = Date()
    for _ in 0..<6 { await limiter.throttle(250_000, .download) }   // 1,5 MB
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed > 1.1, "\(elapsed)")   // sem teto: em paralelo com a bateria pesada o relógio atrasa
    limiter.setLimit(0, for: .download)
    #expect(limiter.reserve(10_000_000, .download) == 0)
}

@Test func checksumsMatchKnownValues() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "wl-sum-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try Checksum.local(file, .sha256).value == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(try Checksum.local(file, .md5).value == "900150983cd24fb0d6963f7d28e17f72")
    // content_hash do Dropbox de um arquivo de um bloco = SHA-256(SHA-256(conteúdo)).
    #expect(try Checksum.local(file, .dropbox).value == "4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358")
}

@Test func searchAndArchives() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "wl-find-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["a/relatorio-2026.pdf", "a/b/c/Relatorio final.PDF", "a/b/nota.txt", "x/y/z.txt"] {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("conteúdo".utf8).write(to: url)
    }
    let found = LockedNames()
    try await RemoteSearch.run(LocalFileSystem(), from: root.path, matching: "relatorio") { found.add($0.map(\.name)) }
    #expect(found.names.sorted() == ["Relatorio final.PDF", "relatorio-2026.pdf"])
    let glob = LockedNames()
    try await RemoteSearch.run(LocalFileSystem(), from: root.path, matching: "*.txt") { glob.add($0.map(\.name)) }
    #expect(glob.names.sorted() == ["nota.txt", "z.txt"])

    // Compactar e descompactar no Mac com os mesmos comandos usados via SSH.
    let fs = LocalFileSystem()
    let folder = root.appending(path: "a").path
    let items = try await fs.list(folder).filter { $0.name == "b" }
    try Archiver.runLocally(Archiver.compressCommand(items, in: folder, to: "b.tar.gz", .tarGz))
    try FileManager.default.removeItem(atPath: folder + "/b")
    let archive = try #require(try await fs.list(folder).first { $0.name == "b.tar.gz" })
    try Archiver.runLocally(try #require(Archiver.expandCommand(archive, in: folder)))
    #expect(FileManager.default.fileExists(atPath: folder + "/b/c/Relatorio final.PDF"))
    #expect(Archiver.format(of: "site.TGZ") == .tarGz && Archiver.format(of: "foto.jpg") == nil)
}

final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ more: [String]) { lock.withLock { stored += more } }
    var names: [String] { lock.withLock { stored } }
}

/// Servidores que comparam nomes byte a byte não podem receber NFD do Mac (viraria um segundo arquivo).
@Test func uploadsUseComposedNames() async throws {
    let decomposed = "arquivo ac\u{0327}a\u{0303}o.txt"   // NFD, como o macOS pode devolver
    let root = FileManager.default.temporaryDirectory.appending(path: "wl-nfc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appending(path: decomposed))
    let recorder = RecordingFS()
    let item = FileItem(path: root.appending(path: decomposed).path, isDirectory: false, size: 1)
    try await Copier(from: LocalFileSystem(), to: recorder).copy(item, into: "/dest", existing: []) { _ in }
    let sent = try #require(recorder.uploaded.first)
    #expect(Array(sent.unicodeScalars) == Array("/dest/arquivo ação.txt".precomposedStringWithCanonicalMapping.unicodeScalars))
}

/// Sistema de arquivos falso que só registra os caminhos de envio.
final class RecordingFS: FileSystem, @unchecked Sendable {
    let title = "teste", homePath = "/"
    private let lock = NSLock()
    private var paths: [String] = []
    var uploaded: [String] { lock.withLock { paths } }
    func list(_ path: String) async throws -> [FileItem] { [] }
    func createDirectory(_ path: String) async throws {}
    func delete(_ item: FileItem) async throws {}
    func move(_ path: String, to newPath: String) async throws {}
    func download(_ path: String, to local: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {}
    func upload(_ local: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws { lock.withLock { paths.append(path) } }
    func disconnect() async {}
}

@Test func smbShareListParsing() {
    let output = """
    Share                                           Type    Comments
    -------------------------------
    COMPARTILHADO                                   Disk
    Fotos                                           Disk    Fotos da família
    IPC$                                            Pipe    Remote IPC
    ADMIN$                                          Disk    Remote Admin

    3 shares listed
    """
    #expect(SMBFileSystem.parseShares(output) == ["COMPARTILHADO", "Fotos"])
}
