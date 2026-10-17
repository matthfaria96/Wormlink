import AppKit
import FileProvider
import WormlinkCore

/// Wormlink Disk do lado do app: monta e desmonta favoritos como locais no Finder (File Provider).
enum Disk {
    static func domain(for bookmark: Bookmark) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(bookmark.id.uuidString), displayName: bookmark.displayName)
    }

    static var extensionPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/PlugIns/WormlinkDisk.appex").path
    }

    /// Favoritos montados agora.
    static func mounted() async -> Set<UUID> {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return Set(domains.compactMap { UUID(uuidString: $0.identifier.rawValue) })
    }

    static func mount(_ bookmark: Bookmark) async throws {
        guard FileManager.default.fileExists(atPath: extensionPath) else {
            throw WormlinkError.unsupportedOperation("Montar no Finder fora do Wormlink.app")
        }
        // Conecta uma vez no app: aqui dá para perguntar sobre chaves, certificados e frases secretas.
        let fs = try await Connector.connect(bookmark, password: Keychain.password(for: bookmark), trust: TrustPrompter.trust)
        await fs.disconnect()
        try DiskConfig.collect(for: bookmark).store(trusting: [Bundle.main.bundlePath, extensionPath])
        try await NSFileProviderManager.add(domain(for: bookmark))
    }

    static func unmount(_ bookmark: Bookmark) async throws {
        try await NSFileProviderManager.remove(domain(for: bookmark))
        DiskConfig.remove(bookmark.id.uuidString)
    }

    /// Pasta do servidor no Finder (em ~/Library/CloudStorage).
    static func reveal(_ bookmark: Bookmark) async {
        guard let manager = NSFileProviderManager(for: domain(for: bookmark)),
              let url = try? await manager.getUserVisibleURL(for: .rootContainer) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Avisa como ativar a extensão (o macOS pede aprovação do usuário uma vez).
    @MainActor
    static func explainActivation(_ bookmark: Bookmark) {
        let alert = NSAlert()
        alert.messageText = "“\(bookmark.displayName)” foi montado no Finder"
        alert.informativeText = """
        Ele aparece na barra lateral do Finder, em Locais. Se for a primeira vez, ative o Wormlink Disk em \
        Ajustes do Sistema › Geral › Itens de Início e Extensões › Provedores de Arquivos.
        """
        alert.addButton(withTitle: "Mostrar no Finder")
        alert.addButton(withTitle: "Abrir Ajustes do Sistema")
        alert.addButton(withTitle: "OK")
        switch alert.runModal() {
        case .alertFirstButtonReturn: Task { await reveal(bookmark) }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        default: break
        }
    }
}
