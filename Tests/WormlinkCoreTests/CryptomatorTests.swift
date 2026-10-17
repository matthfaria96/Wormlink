import CryptoKit
import Foundation
import Testing
@testable import WormlinkCore

private func hex(_ text: String) -> Data {
    let clean = text.filter(\.isHexDigit)
    return Data(stride(from: 0, to: clean.count, by: 2).map {
        UInt8(clean[clean.index(clean.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
    })
}

@Test func cryptoPrimitiveVectors() {
    // RFC 4493, exemplo 2 (16 bytes) e 4 (64 bytes).
    let cmacKey = hex("2b7e1516 28aed2a6 abf71588 09cf4f3c")
    let message = hex("""
        6bc1bee2 2e409f96 e93d7e11 7393172a ae2d8a57 1e03ac9c 9eb76fac 45af8e51
        30c81c46 a35ce411 e5fbc119 1a0a52ef f69f2445 df4f9b17 ad2b417b e66c3710
        """)
    let cmac = AESBlockCipher(key: cmacKey)
    #expect(Data(cmac.cmac([])) == hex("bb1d6929 e9593728 7fa37d12 9b756746"))
    #expect(Data(cmac.cmac(Array(message.prefix(16)))) == hex("070a16b4 6b4d4144 f79bdd9d d04a287c"))
    #expect(Data(cmac.cmac(Array(message))) == hex("51f0bebf 7e3b9d92 fc497417 79363cfe"))

    // RFC 5297, A.1 (determinístico).
    let sivKey = hex("fffefdfc fbfaf9f8 f7f6f5f4 f3f2f1f0 f0f1f2f3 f4f5f6f7 f8f9fafb fcfdfeff")
    let ad = hex("10111213 14151617 18191a1b 1c1d1e1f 20212223 24252627")
    let plain = hex("11223344 55667788 99aabbcc ddee")
    let sealed = AESSIV.encrypt(macKey: sivKey.prefix(16), ctrKey: sivKey.suffix(16), plain, associatedData: [ad])
    #expect(sealed == hex("85632d07 c6e8f37f 950acd32 0a2ecc93 40c02b96 90c4dc04 daef7f6a fe5c"))
    #expect(AESSIV.decrypt(macKey: sivKey.prefix(16), ctrKey: sivKey.suffix(16), sealed, associatedData: [ad]) == plain)
    var tampered = sealed
    tampered[20] ^= 1
    #expect(AESSIV.decrypt(macKey: sivKey.prefix(16), ctrKey: sivKey.suffix(16), tampered, associatedData: [ad]) == nil)

    // RFC 7914, seção 12 (dois primeiros vetores).
    #expect(Scrypt.derive(password: Data(), salt: Data(), n: 16, r: 1, p: 1, length: 64) == hex("""
        77d65762 38657b20 3b19ca42 c18a0497 f16b4844 e3074ae8 dfdffa3f ede21442
        fcd0069d ed0948f8 326a753a 0fc81f17 e8d3e0fb 2e0d3628 cf35e20c 38d18906
        """))
    #expect(Scrypt.derive(password: Data("password".utf8), salt: Data("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64) == hex("""
        fdbabe1c 9d347200 7856e719 0d01e9fe 7c6ad7cb c8237830 e7737663 4b373162
        2eaf30d9 2e22a388 6ff10927 9d9830da c727afb9 4a83ee6d 8360cbdf a2cc0640
        """))

    #expect(Data("foobar".utf8).base32Encoded == "MZXW6YTBOI")
    #expect(Data([0xfb, 0xff]).base64URLEncoded == "-_8=")
}

@Test func cryptomatorVaultRoundTrip() throws {
    let created = CryptomatorVault.create(password: "sênha", scryptCost: 1024)
    #expect(throws: CryptomatorError.wrongPassword) {
        try CryptomatorVault.unlock(masterkey: created.masterkey, config: created.config, password: "errada")
    }
    // A senha é normalizada (NFC): "e" + acento combinado abre o mesmo cofre.
    let vault = try CryptomatorVault.unlock(masterkey: created.masterkey, config: created.config, password: "se\u{0302}nha")
    #expect(vault.cipher == .gcm)

    let name = vault.encryptName("Relatório final.pdf", dirID: "")
    #expect(name.hasSuffix(".c9r"))
    #expect(vault.decryptName(name, dirID: "") == "Relatório final.pdf")
    #expect(vault.decryptName(name, dirID: "outra-pasta") == nil)
    #expect(vault.directoryPath(for: "").count == "d/".count + 2 + 1 + 30)

    for size in [0, 1, 32 * 1024, 32 * 1024 + 1, 100_000] {
        let data = CryptomatorVault.random(size)
        let encrypted = try vault.encrypt(data)
        #expect(vault.cleartextSize(Int64(encrypted.count)) == Int64(size))
        #expect(try vault.decrypt(encrypted) == data)
    }
    var broken = try vault.encrypt(Data("conteúdo".utf8))
    broken[broken.count - 1] ^= 1
    #expect(throws: CryptomatorError.self) { try vault.decrypt(broken) }

    let legacy = CryptomatorVault(encKey: vault.encKey, macKey: vault.macKey, cipher: .ctrMac)
    let data = CryptomatorVault.random(70_000)
    let encrypted = try legacy.encrypt(data)
    #expect(legacy.cleartextSize(Int64(encrypted.count)) == 70_000)
    #expect(try legacy.decrypt(encrypted) == data)
}

// MARK: - Compatibilidade com outra implementação (pycryptomator)

private let pycryptomator = ProcessInfo.processInfo.environment["WORMLINK_PYCRYPTOMATOR"]

private func runInterop(_ command: String, _ folder: URL, _ password: String) throws -> [String: String] {
    let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/cryptomator_interop.py").standardized
    let process = Process()
    process.executableURL = URL(filePath: pycryptomator!)
    process.arguments = ["-I", script.path, command, folder.path, password]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "{}"
    return try JSONDecoder().decode([String: String].self, from: Data(last.utf8))
}

/// Conteúdo decifrado do cofre visto pelo Wormlink, no mesmo formato do script (caminho → sha256 ou "dir").
private func snapshot(_ fs: CryptomatorFileSystem) async throws -> [String: String] {
    var result: [String: String] = [:]
    func walk(_ folder: String) async throws {
        for item in try await fs.list(folder) {
            let relative = "/" + item.path.dropFirst(fs.root.count + 1)
            if item.isDirectory {
                result[relative] = "dir"
                try await walk(item.path)
            } else {
                let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                try await fs.download(item.path, to: temp) { _ in }
                let data = try Data(contentsOf: temp)
                #expect(item.size == Int64(data.count), "tamanho listado de \(relative)")
                result[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
    }
    try await walk(fs.root)
    return result
}

@Test(.enabled(if: pycryptomator != nil)) func cryptomatorInterop() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "Wormlink-cofres-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let local = LocalFileSystem()
    let long = String(repeating: "nome comprido ", count: 12) + ".txt"

    // 1. Cofre criado pelo pycryptomator, lido e alterado pelo Wormlink.
    let theirs = base.appending(path: "deles")
    let expected = try runInterop("make", theirs, "senha forte")
    #expect(expected.count == 7)
    await #expect(throws: CryptomatorError.wrongPassword) { try await CryptomatorFileSystem.unlock(local, at: theirs.path, password: "outra") }
    let opened = try await CryptomatorFileSystem.unlock(local, at: theirs.path, password: "senha forte")
    #expect(try await snapshot(opened) == expected)

    try await opened.createDirectory(opened.root + "/Novas")
    let note = base.appending(path: "nota.txt")
    try Data("escrito pelo Wormlink".utf8).write(to: note)
    try await opened.upload(note, to: opened.root + "/Novas/nota.txt") { _ in }
    try await opened.move(opened.root + "/leia-me.txt", to: opened.root + "/Novas/" + long)          // curto → longo
    try await opened.move(opened.root + "/Pasta/Sub/" + long, to: opened.root + "/curto.txt")         // longo → curto
    try await opened.delete(FileItem(path: opened.root + "/vazio", isDirectory: false))
    try await opened.delete(FileItem(path: opened.root + "/Pasta/Sub", isDirectory: true))
    let afterEdits = try await snapshot(opened)
    #expect(afterEdits["/Novas/" + long] == expected["/leia-me.txt"])
    #expect(afterEdits["/curto.txt"] == expected["/Pasta/Sub/" + long])
    #expect(afterEdits["/vazio"] == nil && afterEdits["/Pasta/Sub"] == nil)
    #expect(try runInterop("dump", theirs, "senha forte") == afterEdits)

    // 2. Cofre criado pelo Wormlink, lido pelo pycryptomator.
    let ours = base.appending(path: "nosso")
    let created = try await CryptomatorFileSystem.create(local, at: ours.path, password: "çenha", scryptCost: 1024)
    try await created.createDirectory(created.root + "/Docs")
    try await created.createDirectory(created.root + "/Docs/" + long.replacingOccurrences(of: ".txt", with: ""))
    let big = base.appending(path: "grande.bin")
    try CryptomatorVault.random(100_000).write(to: big)
    try await created.upload(big, to: created.root + "/Docs/grande.bin") { _ in }
    try await created.upload(note, to: created.root + "/" + long) { _ in }
    try await created.createFile(created.root + "/vazio")
    try await created.move(created.root + "/Docs", to: created.root + "/Documentos")
    let ourSnapshot = try await snapshot(created)
    #expect(ourSnapshot.count == 5)
    let theirView = try runInterop("dump", ours, "çenha")
    #expect(theirView == ourSnapshot, "pycryptomator: \(theirView.sorted { $0.key < $1.key })\nWormlink: \(ourSnapshot.sorted { $0.key < $1.key })")
}
