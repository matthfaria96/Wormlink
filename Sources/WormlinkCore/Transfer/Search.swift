import Foundation

/// Busca por nome em todas as subpastas (em largura, para os resultados próximos aparecerem primeiro).
public enum RemoteSearch {
    /// `query` aceita texto simples (contém, sem diferenciar maiúsculas) ou curingas `*` e `?`.
    public static func matches(_ name: String, _ query: String) -> Bool {
        if query.contains("*") || query.contains("?") { return fnmatch(query.lowercased(), name.lowercased(), 0) == 0 }
        return name.localizedCaseInsensitiveContains(query)
    }

    public static func run(_ fs: any FileSystem, from root: String, matching query: String, limit: Int = 2_000,
                           skip: SkipRules = .default,
                           found: @escaping @Sendable ([FileItem]) -> Void,
                           visiting: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        var queue = [RemotePath.normalize(root)]
        var total = 0
        while !queue.isEmpty, total < limit {
            try Task.checkCancellation()
            let folder = queue.removeFirst()
            visiting(folder)
            guard let items = try? await fs.list(folder) else { continue }   // pasta sem permissão: segue
            let hits = items.filter { !skip.skips($0.name) && matches($0.name, query) }
            if !hits.isEmpty {
                total += hits.count
                found(Array(hits.prefix(limit - (total - hits.count))))
            }
            queue += items.filter { $0.isDirectory && !$0.isSymlink && !skip.skips($0.name) }.map(\.path)
        }
    }
}

/// Compactar e descompactar, no Mac ou no servidor (shell via SSH), com os comandos que o Cyberduck usa.
public enum Archiver {
    public enum Format: String, CaseIterable, Sendable {
        case zip, tarGz = "tar.gz", tar

        public var title: String { switch self { case .zip: "ZIP"; case .tarGz: "TAR.GZ"; case .tar: "TAR" } }
    }

    /// Formato pelo nome do arquivo (nil = não é um arquivo compactado conhecido).
    public static func format(of name: String) -> Format? {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") { return .zip }
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tarGz }
        if lower.hasSuffix(".tar") { return .tar }
        return nil
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Nome do arquivo novo: o item ("site.zip") ou "Arquivo.zip" para vários.
    public static func archiveName(for items: [FileItem], _ format: Format) -> String {
        (items.count == 1 ? items[0].name : "Arquivo") + "." + format.rawValue
    }

    public static func compressCommand(_ items: [FileItem], in folder: String, to archive: String, _ format: Format) -> String {
        let names = items.map { quote($0.name) }.joined(separator: " ")
        let target = quote(archive)
        switch format {
        case .zip: return "cd \(quote(folder)) && zip -qr \(target) \(names)"
        case .tarGz: return "cd \(quote(folder)) && tar -czpf \(target) \(names)"
        case .tar: return "cd \(quote(folder)) && tar -cpf \(target) \(names)"
        }
    }

    public static func expandCommand(_ item: FileItem, in folder: String) -> String? {
        guard let format = format(of: item.name) else { return nil }
        let file = quote(item.name)
        switch format {
        case .zip: return "cd \(quote(folder)) && unzip -qo \(file)"
        case .tarGz: return "cd \(quote(folder)) && tar -xzpf \(file)"
        case .tar: return "cd \(quote(folder)) && tar -xpf \(file)"
        }
    }

    /// No Mac: mesmo comando, num shell local.
    public static func runLocally(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WormlinkError.commandFailed(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}
