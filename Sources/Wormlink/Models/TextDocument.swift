import Foundation
import WormlinkCore

/// Arquivo remoto aberto no editor embutido.
@Observable
final class TextDocument: Identifiable {
    let id = UUID()
    let name: String
    let remotePath: String
    let fs: any FileSystem
    var text = ""
    var savedText = ""
    var encoding: String.Encoding = .utf8
    var isLoading = true
    var isSaving = false
    var error: String?
    var lastSaved: Date?
    /// O download falhou: o texto vazio não é o arquivo e não pode ser salvo por cima dele.
    var loadFailed = false

    static let maxSize: Int64 = 8 * 1024 * 1024
    static let encodings: [(String.Encoding, String)] = [
        (.utf8, "UTF-8"), (.isoLatin1, "ISO Latin 1"), (.windowsCP1252, "Windows Latin 1"),
        (.macOSRoman, "Mac Roman"), (.utf16, "UTF-16"), (.ascii, "ASCII"),
    ]

    init(item: FileItem, fs: any FileSystem) {
        name = item.name
        remotePath = item.path
        self.fs = fs
    }

    var isDirty: Bool { text != savedText }

    private var local: URL {
        URL.cachesDirectory.appending(path: "Wormlink/Texto/\(id.uuidString)/\(name)")
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await fs.download(remotePath, to: local) { _ in }
            let data = try Data(contentsOf: local)
            // Detecta a codificação como o Transmit (UniversalDetector): o próprio Foundation faz a análise.
            var converted: NSString?
            var lossy: ObjCBool = false
            let detected = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [String.Encoding.utf8.rawValue]],
                                                   convertedString: &converted, usedLossyConversion: &lossy)
            if detected != 0, let converted {
                encoding = String.Encoding(rawValue: detected)
                text = converted as String
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
            savedText = text
            loadFailed = false
        } catch {
            loadFailed = true
            self.error = error.localizedDescription
        }
    }

    func reinterpret(as newEncoding: String.Encoding) {
        guard let data = try? Data(contentsOf: local), let string = String(data: data, encoding: newEncoding) else {
            error = String(localized: "O arquivo não pode ser lido nessa codificação.")
            return
        }
        encoding = newEncoding
        text = string
        savedText = string
    }

    func save() async {
        guard !loadFailed else { return }
        guard let data = text.data(using: encoding) else {
            let name = Self.encodings.first { $0.0 == encoding }?.1 ?? String(localized: "nesta codificação")
            error = String(localized: "O texto tem caracteres que não existem em \(name). Use UTF-8.")
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try data.write(to: local)
            try await fs.upload(local, to: remotePath) { _ in }
            savedText = text
            lastSaved = .now
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
