import AppKit
import SwiftUI
import WormlinkCore

/// Estado compartilhado por todas as janelas: servidores, histórico, transferências e edições remotas.
@Observable
final class AppModel {
    private(set) var bookmarks: [Bookmark]
    private(set) var history: [HistoryEntry]
    let transfers = TransferQueue()
    let editor = RemoteEditor()
    /// Favoritos montados no Finder (Wormlink Disk).
    var mountedDisks = Set<UUID>()

    func refreshDisks() async { mountedDisks = await Disk.mounted() }

    func toggleDisk(_ bookmark: Bookmark) async {
        do {
            if mountedDisks.contains(bookmark.id) {
                try await Disk.unmount(bookmark)
            } else {
                try await Disk.mount(bookmark)
                Disk.explainActivation(bookmark)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = mountedDisks.contains(bookmark.id) ? String(localized: "Não foi possível desmontar “\(bookmark.displayName)”")
                : String(localized: "Não foi possível montar “\(bookmark.displayName)”")
            alert.runModal()
        }
        await refreshDisks()
    }

    /// Documentos abertos no editor embutido, por janela.
    var textDocuments: [UUID: TextDocument] = [:]

    /// Abre um arquivo remoto no editor embutido; devolve o id da janela a abrir.
    func openText(_ item: FileItem, from fs: any FileSystem) -> UUID? {
        if let size = item.size, size > TextDocument.maxSize { return nil }
        let document = TextDocument(item: item, fs: fs)
        textDocuments[document.id] = document
        return document.id
    }
    private var store: BookmarkStore
    /// Grupos vazios criados pelo usuário (os com servidores vêm dos próprios favoritos).
    private(set) var emptyGroups: [String] = UserDefaults.standard.stringArray(forKey: "emptyGroups") ?? []

    struct HistoryEntry: Codable, Identifiable, Hashable {
        var id: UUID { bookmark.id }
        var bookmark: Bookmark
        var date: Date
    }

    init() {
        #if DEBUG
        // Só em depuração: WORMLINK_DATA_DIR troca a pasta de dados (capturas sem tocar nos dados reais).
        if let dir = ProcessInfo.processInfo.environment["WORMLINK_DATA_DIR"] { WormlinkPaths.dataDirectory = URL(filePath: dir) }
        #endif
        let iCloud = UserDefaults.standard.bool(forKey: "iCloudSync") && Self.iCloudFolder != nil
        let store = BookmarkStore(fileURL: iCloud ? Self.iCloudFolder!.appending(path: "Bookmarks.json") : BookmarkStore.defaultURL)
        self.store = store
        Self.currentStoreURL = store.fileURL
        let loaded = store.load()
        bookmarks = loaded
        SpotlightIndex.update(loaded)
        history = (UserDefaults.standard.data(forKey: "history")).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    func save(_ bookmark: Bookmark) {
        if let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[i] = bookmark } else { bookmarks.append(bookmark) }
        persist()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        // A senha fica no Chaves por servidor + usuário (formato do Cyberduck): só apaga se nenhum outro favorito usa.
        let sharesPassword = bookmarks.contains {
            Keychain.account(for: $0) == Keychain.account(for: bookmark) && $0.hostname == bookmark.hostname
                && $0.port == bookmark.port && $0.connectionProtocol == bookmark.connectionProtocol
        }
        if !sharesPassword { Keychain.deletePassword(for: bookmark) }
        persist()
    }

    func bookmark(id: UUID) -> Bookmark? { bookmarks.first { $0.id == id } }

    // MARK: Grupos

    var groups: [String] {
        Array(Set(bookmarks.compactMap(\.group) + emptyGroups)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func addGroup(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !groups.contains(name) else { return }
        emptyGroups.append(name)
        UserDefaults.standard.set(emptyGroups, forKey: "emptyGroups")
    }

    func renameGroup(_ old: String, to new: String) {
        for i in bookmarks.indices where bookmarks[i].group == old { bookmarks[i].group = new }
        emptyGroups = emptyGroups.map { $0 == old ? new : $0 }
        UserDefaults.standard.set(emptyGroups, forKey: "emptyGroups")
        persist()
    }

    /// Apaga o grupo; os servidores dele voltam para a lista principal.
    func removeGroup(_ name: String) {
        for i in bookmarks.indices where bookmarks[i].group == name { bookmarks[i].group = nil }
        emptyGroups.removeAll { $0 == name }
        UserDefaults.standard.set(emptyGroups, forKey: "emptyGroups")
        persist()
    }

    func move(_ id: UUID, toGroup group: String?) {
        guard var bookmark = bookmark(id: id) else { return }
        bookmark.group = group
        save(bookmark)
    }

    // MARK: iCloud Drive

    /// Pasta do Wormlink no iCloud Drive (nil se o iCloud Drive não está ativo).
    nonisolated static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appending(path: "Wormlink")
    }

    var iCloudAvailable: Bool { Self.iCloudFolder != nil }

    var iCloudSync: Bool {
        get { access(keyPath: \.iCloudSync); return UserDefaults.standard.bool(forKey: "iCloudSync") }
        set {
            withMutation(keyPath: \.iCloudSync) {
                UserDefaults.standard.set(newValue, forKey: "iCloudSync")
                guard let folder = Self.iCloudFolder else { return }
                let target = newValue ? folder.appending(path: "Bookmarks.json") : BookmarkStore.defaultURL
                // Junta os dois lados ao trocar, para não perder servidores.
                let other = BookmarkStore(fileURL: target).load()
                let known = Set(bookmarks.map(\.id))
                bookmarks += other.filter { !known.contains($0.id) }
                store = BookmarkStore(fileURL: target)
                persist()
            }
        }
    }

    /// Relê o arquivo (outro Mac pode ter mudado pelo iCloud).
    func reloadFromDisk() {
        guard iCloudSync else { return }
        let fresh = store.load()
        if fresh != bookmarks { bookmarks = fresh }
    }

    /// Registra uma conexão no histórico (as mais recentes primeiro, até 30).
    func recordConnection(_ bookmark: Bookmark) {
        history.removeAll { $0.bookmark.id == bookmark.id }
        history.insert(HistoryEntry(bookmark: bookmark, date: .now), at: 0)
        history = Array(history.prefix(30))
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "history")
        if var saved = self.bookmark(id: bookmark.id) {
            saved.lastUsed = .now
            save(saved)
        }
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "history")
    }

    /// Favoritos do Cyberduck que ainda não estão aqui.
    var cyberduckCandidates: [Bookmark] {
        let known = Set(bookmarks.map(\.id))
        return Bookmark.importCyberduckBookmarks().filter { !known.contains($0.id) }
    }

    @discardableResult
    func importFromCyberduck() -> Int {
        let new = cyberduckCandidates
        bookmarks += new
        persist()
        return new.count
    }

    // MARK: Bonjour

    let bonjour = BonjourBrowser()

    var showBonjour: Bool {
        get { access(keyPath: \.showBonjour); return UserDefaults.standard.object(forKey: "showBonjour") as? Bool ?? true }
        set {
            withMutation(keyPath: \.showBonjour) { UserDefaults.standard.set(newValue, forKey: "showBonjour") }
            newValue ? bonjour.start() : bonjour.stop()
        }
    }

    func startBonjourIfEnabled() { if showBonjour { bonjour.start() } }

    // MARK: Importar, exportar e restaurar

    /// Junta servidores vindos de outro app ou de um backup. Ignora os que já existem (mesmo id, ou mesmo
    /// protocolo, endereço, porta e usuário) e guarda as senhas no Chaves.
    @discardableResult
    func merge(_ entries: [(bookmark: Bookmark, password: String?)]) -> Int {
        func signature(_ b: Bookmark) -> String {
            "\(b.connectionProtocol.rawValue)|\(b.hostname.lowercased())|\(b.port)|\(b.username)|\(b.path)"
        }
        var ids = Set(bookmarks.map(\.id))
        var known = Set(bookmarks.map(signature))
        var added = 0
        for (bookmark, password) in entries where !ids.contains(bookmark.id) && !known.contains(signature(bookmark)) {
            bookmarks.append(bookmark)
            ids.insert(bookmark.id)
            known.insert(signature(bookmark))
            if let password, !password.isEmpty { _ = Keychain.setPassword(password, for: bookmark) }
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    /// Importa de outro app (pede o arquivo quando não está no lugar de sempre).
    func importServers(from source: ServerImporter) {
        var location = source.isAvailable ? source.defaultLocation : nil
        if location == nil {
            let panel = NSOpenPanel()
            panel.message = String(localized: "Escolha os servidores do \(source.title) para importar.")
            panel.canChooseDirectories = source == .transmit || source == .cyberduck
            guard panel.runModal() == .OK, let url = panel.url else { return }
            location = url
        }
        do {
            let entries = try source.read(location)
            let added = merge(entries)
            inform(added == 1 ? String(localized: "1 servidor importado do \(source.title)") : String(localized: "\(added) servidores importados do \(source.title)"),
                   entries.count > added ? String(localized: "\(entries.count - added) já estavam no Wormlink.") : nil)
        } catch {
            inform(String(localized: "Não foi possível importar do \(source.title)"), error.localizedDescription)
        }
    }

    func exportServers() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Servidores do Wormlink.wormlinkservers")
        let passwords = NSButton(checkboxWithTitle: String(localized: "Incluir senhas (o arquivo fica legível só por você)"), target: nil, action: nil)
        panel.accessoryView = passwords
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ServerBackup(bookmarks: bookmarks, includePasswords: passwords.state == .on).write(to: url)
        } catch {
            inform(String(localized: "Não foi possível exportar"), error.localizedDescription)
        }
    }

    func restoreServers() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Escolha um backup de servidores do Wormlink.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try ServerBackup.read(url)
            let added = merge(backup.bookmarks.map { ($0, backup.passwords?[$0.id.uuidString]) })
            inform(added == 1 ? String(localized: "1 servidor restaurado") : String(localized: "\(added) servidores restaurados"), nil)
        } catch {
            inform(String(localized: "Não foi possível restaurar"), error.localizedDescription)
        }
    }

    private func inform(_ title: String, _ detail: String?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail ?? ""
        alert.runModal()
    }

    /// Arquivo de favoritos em uso (Serviços do Finder leem sem passar pela janela).
    nonisolated(unsafe) static var currentStoreURL = BookmarkStore.defaultURL

    private func persist() {
        bookmarks.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        try? store.save(bookmarks)
        Self.currentStoreURL = store.fileURL
        SpotlightIndex.update(bookmarks)
    }

    // MARK: Lugares locais (barra de Places do painel local)

    var localPlaces: [String] {
        get {
            access(keyPath: \.localPlaces)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return UserDefaults.standard.stringArray(forKey: "localPlaces") ?? [home, home + "/Downloads", home + "/Desktop"]
        }
        set {
            withMutation(keyPath: \.localPlaces) { UserDefaults.standard.set(newValue, forKey: "localPlaces") }
        }
    }
}
