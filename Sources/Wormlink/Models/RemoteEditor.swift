import AppKit
import WormlinkCore

/// Edição de arquivos remotos num app externo, como o "Edit" do Cyberduck e do Transmit:
/// baixa para uma pasta temporária, abre no editor e reenvia sempre que o arquivo é salvo.
@Observable
final class RemoteEditor {
    struct Session: Identifiable {
        let id = UUID()
        let remotePath: String
        let local: URL
        let fs: any FileSystem
        var lastModified: Date?
        var uploads = 0
        var lastError: String?
    }

    private(set) var sessions: [Session] = []
    private var watcher: Task<Void, Never>?

    /// Baixa `item` e abre no app escolhido (ou no padrão do sistema).
    func edit(_ item: FileItem, from fs: any FileSystem, with application: URL? = nil) async throws {
        let folder = URL.cachesDirectory.appending(path: "Wormlink/Editar/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appending(path: item.name)
        try await fs.download(item.path, to: local) { _ in }
        let modified = Self.modificationDate(local)
        sessions.append(Session(remotePath: item.path, local: local, fs: fs, lastModified: modified))
        let configuration = NSWorkspace.OpenConfiguration()
        if let application {
            try await NSWorkspace.shared.open([local], withApplicationAt: application, configuration: configuration)
        } else {
            NSWorkspace.shared.open(local)
        }
        startWatching()
    }

    /// Verifica a cada segundo (editores costumam salvar trocando o arquivo, o que confunde observadores de arquivo).
    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.uploadChanges()
            }
        }
    }

    private func uploadChanges() async {
        for session in sessions {
            guard let modified = Self.modificationDate(session.local), modified != session.lastModified else { continue }
            update(session.id) { $0.lastModified = modified }
            do {
                try await session.fs.upload(session.local, to: session.remotePath) { _ in }
                update(session.id) { $0.uploads += 1; $0.lastError = nil }
            } catch {
                update(session.id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    /// Altera uma sessão pelo id (a lista pode mudar durante um envio).
    private func update(_ id: UUID, _ change: (inout Session) -> Void) {
        if let index = sessions.firstIndex(where: { $0.id == id }) { change(&sessions[index]) }
    }

    func stop(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        try? FileManager.default.removeItem(at: session.local.deletingLastPathComponent())
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
