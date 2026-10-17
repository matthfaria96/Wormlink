import Foundation

/// Identificadores opacos e estáveis para os itens do Wormlink Disk: o caminho remoto muda ao
/// renomear ou mover, o identificador não. Guardado em JSON para sobreviver a reinícios da extensão.
public final class ItemIdentifiers: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var byPath: [String: String] = [:]
    private var byID: [String: String] = [:]

    public init(file: URL) {
        self.file = file
        // Arquivo ausente ou corrompido: começa vazio.
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            byID = saved
            for (id, path) in saved { byPath[path] = id }
        }
    }

    /// Identificador do caminho, criando um novo se ainda não existir.
    public func identifier(for path: String) -> String {
        let path = RemotePath.normalize(path)
        return lock.withLock {
            if let id = byPath[path] { return id }
            let id = UUID().uuidString
            byPath[path] = id
            byID[id] = path
            save()
            return id
        }
    }

    public func path(for identifier: String) -> String? {
        lock.withLock { byID[identifier] }
    }

    /// Renomeou/moveu: o item e tudo abaixo dele mantêm os identificadores no novo caminho.
    public func moved(from old: String, to new: String) {
        let old = RemotePath.normalize(old), new = RemotePath.normalize(new)
        guard old != new else { return }
        lock.withLock {
            // O que já estava no destino (sobrescrito) deixa de existir.
            for (path, id) in byPath where Self.contains(new, path) {
                byPath[path] = nil
                byID[id] = nil
            }
            for (path, id) in byPath where Self.contains(old, path) {
                let moved = new + path.dropFirst(old.count)
                byPath[path] = nil
                byPath[moved] = id
                byID[id] = moved
            }
            save()
        }
    }

    public func removed(_ path: String) {
        let path = RemotePath.normalize(path)
        lock.withLock {
            for (p, id) in byPath where Self.contains(path, p) {
                byPath[p] = nil
                byID[id] = nil
            }
            save()
        }
    }

    private static func contains(_ base: String, _ path: String) -> Bool {
        path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(byID).write(to: file, options: .atomic)
    }
}
