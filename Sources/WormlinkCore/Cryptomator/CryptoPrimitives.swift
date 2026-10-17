import CommonCrypto
import CryptoKit
import Foundation

/// AES em modo ECB (só blocos inteiros): base para CMAC, SIV e CTR.
final class AESBlockCipher {
    private var cryptor: CCCryptorRef?

    init(key: Data) {
        let status = key.withUnsafeBytes { raw in
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            raw.baseAddress, key.count, nil, &cryptor)
        }
        precondition(status == kCCSuccess && [16, 24, 32].contains(key.count), "chave AES inválida")
    }

    deinit { CCCryptorRelease(cryptor) }

    /// Cifra `count` bytes (múltiplo de 16) de `input` para `output`; podem ser o mesmo buffer.
    func encrypt(_ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer, count: Int) {
        var moved = 0
        CCCryptorUpdate(cryptor, input, count, output, count, &moved)
    }

    func encryptBlock(_ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        block.withUnsafeBytes { input in out.withUnsafeMutableBytes { encrypt(input.baseAddress!, $0.baseAddress!, count: 16) } }
        return out
    }

    /// AES-CTR com contador de 128 bits big-endian a partir de `iv` (como "AES/CTR/NoPadding" do Java).
    func ctr(iv: [UInt8], _ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let blocks = (data.count + 15) / 16
        var stream = [UInt8](repeating: 0, count: blocks * 16)
        var counter = iv
        for index in 0..<blocks {
            stream.replaceSubrange(index * 16..<index * 16 + 16, with: counter)
            for byte in (0..<16).reversed() {
                counter[byte] &+= 1
                if counter[byte] != 0 { break }
            }
        }
        let length = stream.count
        stream.withUnsafeMutableBytes { encrypt($0.baseAddress!, $0.baseAddress!, count: length) }
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                for i in 0..<data.count { out[i] = input[i] ^ stream[i] }
            }
        }
        return output
    }

    // MARK: CMAC (RFC 4493)

    private static func double(_ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { out[i] = (block[i] << 1) | (i < 15 ? block[i + 1] >> 7 : 0) }
        if block[0] & 0x80 != 0 { out[15] ^= 0x87 }
        return out
    }

    func cmac(_ message: [UInt8]) -> [UInt8] {
        let k1 = Self.double(encryptBlock([UInt8](repeating: 0, count: 16)))
        let k2 = Self.double(k1)
        let count = max(1, (message.count + 15) / 16)
        let complete = !message.isEmpty && message.count % 16 == 0
        var x = [UInt8](repeating: 0, count: 16)
        for index in 0..<count - 1 {
            for i in 0..<16 { x[i] ^= message[index * 16 + i] }
            x = encryptBlock(x)
        }
        var last = Array(message[(count - 1) * 16..<message.count])
        if complete {
            for i in 0..<16 { last[i] ^= k1[i] }
        } else {
            last.append(0x80)
            last += [UInt8](repeating: 0, count: 16 - last.count)
            for i in 0..<16 { last[i] ^= k2[i] }
        }
        for i in 0..<16 { x[i] ^= last[i] }
        return encryptBlock(x)
    }

    /// S2V do AES-SIV (RFC 5297): os dados associados vêm antes, o texto por último.
    func s2v(_ strings: [[UInt8]]) -> [UInt8] {
        var d = cmac([UInt8](repeating: 0, count: 16))
        for string in strings.dropLast() {
            let mac = cmac(string)
            d = Self.double(d)
            for i in 0..<16 { d[i] ^= mac[i] }
        }
        var last = strings.last ?? []
        if last.count >= 16 {
            for i in 0..<16 { last[last.count - 16 + i] ^= d[i] }
        } else {
            d = Self.double(d)
            last.append(0x80)
            last += [UInt8](repeating: 0, count: 16 - last.count)
            for i in 0..<16 { last[i] ^= d[i] }
        }
        return cmac(last)
    }
}

/// AES-SIV determinístico (RFC 5297). Saída: V (16 bytes) seguido do texto cifrado.
enum AESSIV {
    static func encrypt(macKey: Data, ctrKey: Data, _ plaintext: Data, associatedData: [Data] = []) -> Data {
        let v = AESBlockCipher(key: macKey).s2v(associatedData.map(Array.init) + [Array(plaintext)])
        return Data(v) + AESBlockCipher(key: ctrKey).ctr(iv: counter(from: v), plaintext)
    }

    static func decrypt(macKey: Data, ctrKey: Data, _ ciphertext: Data, associatedData: [Data] = []) -> Data? {
        guard ciphertext.count >= 16 else { return nil }
        let v = Array(ciphertext.prefix(16))
        let plaintext = AESBlockCipher(key: ctrKey).ctr(iv: counter(from: v), ciphertext.dropFirst(16))
        let check = AESBlockCipher(key: macKey).s2v(associatedData.map(Array.init) + [Array(plaintext)])
        return zip(v, check).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 ? plaintext : nil
    }

    private static func counter(from v: [UInt8]) -> [UInt8] {
        var q = v
        q[8] &= 0x7f
        q[12] &= 0x7f
        return q
    }
}

/// scrypt (RFC 7914), usado pelo Cryptomator para derivar a chave a partir da senha.
enum Scrypt {
    static func derive(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) -> Data {
        precondition(n > 1 && n & (n - 1) == 0, "N precisa ser potência de 2")
        let blockWords = 32 * r
        let initial = pbkdf2SHA256(password: password, salt: salt, length: p * 128 * r)
        var words = [UInt32](repeating: 0, count: p * blockWords)
        initial.withUnsafeBytes { raw in
            for i in 0..<words.count { words[i] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        }
        var v = [UInt32](repeating: 0, count: n * blockWords)
        var x = [UInt32](repeating: 0, count: blockWords)
        var y = [UInt32](repeating: 0, count: blockWords)
        words.withUnsafeMutableBufferPointer { b in
            v.withUnsafeMutableBufferPointer { v in
                x.withUnsafeMutableBufferPointer { x in
                    y.withUnsafeMutableBufferPointer { y in
                        for chunk in 0..<p { roMix(b.baseAddress! + chunk * blockWords, r: r, n: n, v: v.baseAddress!, x: x.baseAddress!, y: y.baseAddress!) }
                    }
                }
            }
        }
        var mixed = Data(count: words.count * 4)
        mixed.withUnsafeMutableBytes { raw in
            for i in 0..<words.count { raw.storeBytes(of: words[i].littleEndian, toByteOffset: i * 4, as: UInt32.self) }
        }
        return pbkdf2SHA256(password: password, salt: mixed, length: length)
    }

    /// PBKDF2-HMAC-SHA256 com uma única iteração (o que o scrypt usa).
    static func pbkdf2SHA256(password: Data, salt: Data, length: Int) -> Data {
        let key = SymmetricKey(data: password)
        var output = Data()
        var index: UInt32 = 1
        while output.count < length {
            var block = salt
            withUnsafeBytes(of: index.bigEndian) { block.append(contentsOf: $0) }
            output.append(contentsOf: HMAC<SHA256>.authenticationCode(for: block, using: key))
            index += 1
        }
        return output.prefix(length)
    }

    private static func roMix(_ b: UnsafeMutablePointer<UInt32>, r: Int, n: Int, v: UnsafeMutablePointer<UInt32>,
                              x: UnsafeMutablePointer<UInt32>, y: UnsafeMutablePointer<UInt32>) {
        let words = 32 * r
        x.update(from: b, count: words)
        for i in 0..<n {
            (v + i * words).update(from: x, count: words)
            blockMix(x, y, r: r)
        }
        for _ in 0..<n {
            let j = Int(x[(2 * r - 1) * 16]) & (n - 1)
            let vj = v + j * words
            for k in 0..<words { x[k] ^= vj[k] }
            blockMix(x, y, r: r)
        }
        b.update(from: x, count: words)
    }

    private static func blockMix(_ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>, r: Int) {
        var t = [UInt32](repeating: 0, count: 16)
        t.withUnsafeMutableBufferPointer { t in
            let t = t.baseAddress!
            t.update(from: b + (2 * r - 1) * 16, count: 16)
            for i in 0..<2 * r {
                for k in 0..<16 { t[k] ^= b[i * 16 + k] }
                salsa8(t)
                (y + i * 16).update(from: t, count: 16)
            }
        }
        for i in 0..<r {
            (b + i * 16).update(from: y + 2 * i * 16, count: 16)
            (b + (r + i) * 16).update(from: y + (2 * i + 1) * 16, count: 16)
        }
    }

    @inline(__always) private static func rotate(_ a: UInt32, _ n: UInt32) -> UInt32 { (a << n) | (a >> (32 - n)) }

    private static func salsa8(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        for _ in 0..<4 {
            x4 ^= rotate(x0 &+ x12, 7); x8 ^= rotate(x4 &+ x0, 9); x12 ^= rotate(x8 &+ x4, 13); x0 ^= rotate(x12 &+ x8, 18)
            x9 ^= rotate(x5 &+ x1, 7); x13 ^= rotate(x9 &+ x5, 9); x1 ^= rotate(x13 &+ x9, 13); x5 ^= rotate(x1 &+ x13, 18)
            x14 ^= rotate(x10 &+ x6, 7); x2 ^= rotate(x14 &+ x10, 9); x6 ^= rotate(x2 &+ x14, 13); x10 ^= rotate(x6 &+ x2, 18)
            x3 ^= rotate(x15 &+ x11, 7); x7 ^= rotate(x3 &+ x15, 9); x11 ^= rotate(x7 &+ x3, 13); x15 ^= rotate(x11 &+ x7, 18)
            x1 ^= rotate(x0 &+ x3, 7); x2 ^= rotate(x1 &+ x0, 9); x3 ^= rotate(x2 &+ x1, 13); x0 ^= rotate(x3 &+ x2, 18)
            x6 ^= rotate(x5 &+ x4, 7); x7 ^= rotate(x6 &+ x5, 9); x4 ^= rotate(x7 &+ x6, 13); x5 ^= rotate(x4 &+ x7, 18)
            x11 ^= rotate(x10 &+ x9, 7); x8 ^= rotate(x11 &+ x10, 9); x9 ^= rotate(x8 &+ x11, 13); x10 ^= rotate(x9 &+ x8, 18)
            x12 ^= rotate(x15 &+ x14, 7); x13 ^= rotate(x12 &+ x15, 9); x14 ^= rotate(x13 &+ x12, 13); x15 ^= rotate(x14 &+ x13, 18)
        }
        b[0] &+= x0; b[1] &+= x1; b[2] &+= x2; b[3] &+= x3; b[4] &+= x4; b[5] &+= x5; b[6] &+= x6; b[7] &+= x7
        b[8] &+= x8; b[9] &+= x9; b[10] &+= x10; b[11] &+= x11; b[12] &+= x12; b[13] &+= x13; b[14] &+= x14; b[15] &+= x15
    }
}

extension Data {
    /// Base64 "URL-safe" com preenchimento, como o Cryptomator usa nos nomes.
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// Aceita Base64 comum ou URL-safe, com ou sem preenchimento.
    init?(base64Flexible text: some StringProtocol) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    /// Base32 (RFC 4648), maiúsculas, sem preenchimento.
    var base32Encoded: String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = "", buffer = 0, bits = 0
        for byte in self {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return output
    }
}
