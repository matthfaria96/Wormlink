import SwiftUI
import WormlinkCore

/// Navegador de arquivos de um painel: um sistema de arquivos, a pasta aberta e as subpastas expandidas.
@Observable
final class PaneModel: Identifiable {
    enum Layout: String, CaseIterable {
        case list, icons, columns, gallery

        var title: String {
            switch self { case .list: "Lista"; case .icons: "Ícones"; case .columns: "Colunas"; case .gallery: "Galeria" }
        }

        var symbol: String {
            switch self { case .list: "list.bullet"; case .icons: "square.grid.2x2"; case .columns: "rectangle.split.3x1"; case .gallery: "rectangle.bottomhalf.inset.filled" }
        }
    }

    nonisolated struct Row: Identifiable, Hashable {
        let item: FileItem
        let depth: Int
        var id: String { item.id }
    }

    let id = UUID()
    let fs: any FileSystem
    let bookmark: Bookmark?
    private(set) var path: String
    private(set) var items: [FileItem] = []
    var selection = Set<FileItem.ID>()
    var sortOrder = [KeyPathComparator(\PaneModel.Row.item.name, comparator: .localizedStandard)]
    var showHidden = UserDefaults.standard.bool(forKey: "showHiddenFiles")
    var layout: Layout = Layout(rawValue: UserDefaults.standard.string(forKey: "paneLayout") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "paneLayout") }
    }
    var filter = ""
    private(set) var isLoading = false
    /// Falha ao listar a pasta (aparece no lugar da lista).
    var error: String?
    /// Falha numa operação (renomear, apagar…), mostrada num alerta.
    var operationError: String?
    private(set) var expanded = Set<String>()
    private var children: [String: [FileItem]] = [:]
    private var back: [String] = []
    private var forward: [String] = []
    /// Resultados da busca em subpastas (nil = navegação normal).
    private(set) var searchResults: [FileItem]?
    private(set) var isSearching = false
    private(set) var searchFolder: String?
    private var searchTask: Task<Void, Never>?
    /// Chamado a cada mudança de pasta feita pelo usuário (Folder Linking).
    var onNavigate: ((String) -> Void)?

    init(fs: any FileSystem, bookmark: Bookmark? = nil, path: String? = nil) {
        self.fs = fs
        self.bookmark = bookmark
        self.path = RemotePath.normalize(path ?? fs.homePath)
    }

    var isLocal: Bool { fs is LocalFileSystem }
    var title: String { isLocal ? Host.current().localizedName ?? "Este Mac" : fs.title }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Linhas visíveis: pastas primeiro, na ordem da tabela, com as subpastas expandidas logo abaixo.
    var rows: [Row] {
        if let searchResults {
            return searchResults.map { Row(item: $0, depth: 0) }.sorted(using: sortOrder)
        }
        var result: [Row] = []
        func add(_ list: [FileItem], depth: Int) {
            for item in arrange(list) {
                result.append(Row(item: item, depth: depth))
                if item.isDirectory, expanded.contains(item.path), let kids = children[item.path] { add(kids, depth: depth + 1) }
            }
        }
        add(items, depth: 0)
        return result
    }

    private func arrange(_ list: [FileItem]) -> [FileItem] {
        var shown = showHidden ? list : list.filter { !$0.isHidden }
        if !filter.isEmpty { shown = shown.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        let sorted = shown.map { Row(item: $0, depth: 0) }.sorted(using: sortOrder).map(\.item)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    var selectedItems: [FileItem] { rows.map(\.item).filter { selection.contains($0.id) } }

    // MARK: Navegação

    func go(to newPath: String, notify: Bool = true) async {
        let target = RemotePath.normalize(newPath)
        guard target != path else { return await reload() }
        back.append(path)
        forward.removeAll()
        await open(target, notify: notify)
    }

    func goBack() async {
        guard let previous = back.popLast() else { return }
        forward.append(path)
        await open(previous, notify: true)
    }

    func goForward() async {
        guard let next = forward.popLast() else { return }
        back.append(path)
        await open(next, notify: true)
    }

    func goUp() async { await go(to: RemotePath.parent(path)) }

    private func open(_ target: String, notify: Bool) async {
        clearSearch()
        path = target
        expanded.removeAll()
        children.removeAll()
        selection.removeAll()
        if notify { onNavigate?(target) }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await fs.list(path)
            for folder in expanded { children[folder] = try? await fs.list(folder) }
            error = nil
            selection.formIntersection(rows.map(\.id))
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    /// Abre ou fecha uma subpasta na própria lista (triângulo ao lado do nome).
    func toggle(_ item: FileItem) async {
        if expanded.remove(item.path) != nil { return }
        expanded.insert(item.path)
        if children[item.path] == nil {
            do { children[item.path] = try await fs.list(item.path) } catch {
                expanded.remove(item.path)
                operationError = error.localizedDescription
            }
        }
    }

    // MARK: Busca em subpastas

    func startSearch(_ query: String) {
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        searchResults = []
        isSearching = true
        searchFolder = path
        let fs = fs, root = path
        searchTask = Task { [weak self] in
            try? await RemoteSearch.run(fs, from: root, matching: query, skip: TransferSettings.skipRules,
                                        found: { hits in Task { @MainActor in self?.searchResults?.append(contentsOf: hits) } },
                                        visiting: { folder in Task { @MainActor in self?.searchFolder = folder } })
            self?.isSearching = false
        }
    }

    func stopSearch() {
        searchTask?.cancel()
        isSearching = false
    }

    func clearSearch() {
        stopSearch()
        searchResults = nil
        searchFolder = nil
    }

    // MARK: Operações

    func createFolder(named name: String, in folder: String? = nil) async {
        await run { try await self.fs.createDirectory(RemotePath.join(folder ?? self.path, name)) }
    }

    func createFile(named name: String) async {
        await run { try await self.fs.createFile(RemotePath.join(self.path, name)) }
    }

    func rename(_ item: FileItem, to name: String) async {
        guard !name.isEmpty, name != item.name else { return }
        await run { try await self.fs.move(item.path, to: RemotePath.join(RemotePath.parent(item.path), name)) }
    }

    func delete(_ targets: [FileItem]) async {
        await run { for item in targets { try await self.fs.delete(item) } }
    }

    /// "foto.jpg" → "foto 2.jpg" na mesma pasta (no servidor, baixa e envia de novo se preciso).
    func duplicate(_ targets: [FileItem]) async {
        await run {
            let copier = Copier(from: self.fs, to: self.fs, resolver: { _, _ in .rename })
            for item in targets { try await copier.copy(item, into: RemotePath.parent(item.path)) { _ in } }
        }
    }

    /// Compactar e descompactar: no Mac, ou no servidor quando há shell (SFTP).
    var canArchive: Bool { isLocal || fs is SFTPFileSystem }

    func compress(_ targets: [FileItem], as format: Archiver.Format) async {
        guard let first = targets.first else { return }
        let folder = RemotePath.parent(first.path)
        let command = Archiver.compressCommand(targets, in: folder, to: Archiver.archiveName(for: targets, format), format)
        await run { try await self.runShell(command) }
    }

    func expand(_ item: FileItem) async {
        guard let command = Archiver.expandCommand(item, in: RemotePath.parent(item.path)) else { return }
        await run { try await self.runShell(command) }
    }

    private func runShell(_ command: String) async throws {
        if isLocal {
            try await Task.detached { try Archiver.runLocally(command) }.value
        } else {
            _ = try await fs.execute(command)
        }
    }

    /// "Enviar Comando": shell na pasta atual (SFTP) ou comando FTP bruto.
    func sendCommand(_ command: String) async -> String {
        do {
            let line = fs is SFTPFileSystem ? "cd \(SFTPFileSystem.shellQuote(path)) && \(command)" : command
            let output = try await fs.execute(line)
            await reload()
            return output.isEmpty ? "(sem saída)" : output
        } catch {
            return error.localizedDescription
        }
    }

    func setPermissions(_ item: FileItem, mode: UInt16) async {
        await run { try await self.fs.setPermissions(item.path, mode: mode) }
    }

    private func run(_ operation: () async throws -> Void) async {
        do { try await operation() } catch { operationError = error.localizedDescription }
        await reload()
    }
}

extension FileItem {
    /// Chaves de ordenação não opcionais para as colunas da tabela.
    nonisolated var sortSize: Int64 { size ?? -1 }
    nonisolated var sortDate: Date { modified ?? .distantPast }
}
