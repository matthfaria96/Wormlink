import AppKit
import SwiftUI
import WormlinkCore

/// Um lado da janela. Mostra arquivos (do Mac ou de um servidor) ou a lista de servidores.
@Observable
final class PaneSlot: Identifiable {
    enum ServersTab { case servers, quickConnect }
    enum ServersPage: Hashable { case all, history, cyberduck, bonjour, group(String) }

    let id = UUID()
    var files: PaneModel?
    var showingServers: Bool
    var serversTab: ServersTab = .servers
    var serversPage: ServersPage = .all
    var serversAsGrid = false
    var selectedServer: UUID?
    /// Servidor em edição dentro do painel (como o editor do Transmit).
    var editing: ServerDraft?
    var quickConnect = ServerDraft(bookmark: Bookmark(connectionProtocol: .sftp), isNew: true)
    /// Conexão aguardando senha.
    var passwordRequest: PasswordRequest?
    var connecting: Bookmark?
    var connectionError: String?

    init(files: PaneModel?, showingServers: Bool) {
        self.files = files
        self.showingServers = showingServers
    }

    /// Arquivos visíveis neste lado agora (nil quando a lista de servidores está à frente).
    var visibleFiles: PaneModel? { showingServers ? nil : files }
}

struct ServerDraft: Identifiable, Equatable {
    var id: UUID { bookmark.id }
    var bookmark: Bookmark
    var password = ""
    var isNew: Bool
}

struct PasswordRequest: Identifiable {
    var id: UUID { bookmark.id }
    var bookmark: Bookmark
    var password = ""
    var remember = true
    var failed = false
}

/// Estado de uma janela (ou aba): dois lados, Folder Linking e o inspetor.
@Observable
final class WindowModel {
    enum Side { case left, right }

    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    /// Fechar a janela (ou a aba) encerra as conexões dela; senão SSH/FTP ficam abertos até sair do app.
    func disconnectOnClose(_ window: NSWindow) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let connections = [self.left, self.right].compactMap(\.files).filter { !$0.isLocalConnection }.map(\.base)
                Task { for connection in connections { await connection.disconnect() } }
            }
        }
    }

    let left: PaneSlot
    let right: PaneSlot
    var active: Side = .left
    var showInspector = false
    var showSync = false
    /// Só o lado ativo na janela (Transmit: "Um Painel").
    var singlePane = false
    /// Servidor SFTP em que instalar uma chave pública (abre a folha).
    var installKeyOn: SFTPFileSystem?
    var search = ""
    private(set) var linking = false
    private var linkBases: (left: String, right: String)?
    private var linkingInProgress = false

    init() {
        left = PaneSlot(files: PaneModel(fs: LocalFileSystem()), showingServers: false)
        right = PaneSlot(files: nil, showingServers: true)
    }

    func slot(_ side: Side) -> PaneSlot { side == .left ? left : right }
    func other(_ side: Side) -> Side { side == .left ? .right : .left }
    func side(of slot: PaneSlot) -> Side { slot === left ? .left : .right }

    var activeFiles: PaneModel? { slot(active).visibleFiles }
    var otherFiles: PaneModel? { slot(other(active)).visibleFiles }

    /// Título da janela: o servidor conectado, ou o lado ativo, ou "Servidores".
    var title: String {
        for slot in [right, left] where !slot.showingServers {
            if let files = slot.files, !files.isLocalConnection { return files.title }
        }
        return activeFiles?.title ?? String(localized: "Servidores")
    }

    /// Subtítulo da janela: a pasta aberta no lado ativo.
    var subtitle: String {
        guard let files = activeFiles else { return "" }
        if files.isLocalConnection { return (files.path as NSString).abbreviatingWithTildeInPath }
        return files.path
    }

    // MARK: Conexão

    func connect(_ bookmark: Bookmark, in slot: PaneSlot, password: String? = nil, app: AppModel) async {
        let password = password ?? Keychain.password(for: bookmark)
        slot.connecting = bookmark
        slot.connectionError = nil
        defer { slot.connecting = nil }
        do {
            let fs = try await Connector.connect(bookmark, password: password, trust: TrustPrompter.trust)
            if let old = slot.files, !old.isLocalConnection { await old.base.disconnect() }
            let pane = PaneModel(fs: fs, bookmark: bookmark)
            pane.onNavigate = { [weak self, weak slot] path in
                guard let self, let slot else { return }
                self.mirror(path, from: self.side(of: slot))
            }
            slot.files = pane
            slot.showingServers = false
            slot.editing = nil
            active = side(of: slot)
            app.recordConnection(bookmark)
            await pane.reload()
            if let local = bookmark.localPath, let other = self.slot(other(side(of: slot))).files, other.isLocalConnection {
                await other.go(to: local)
            }
        } catch WormlinkError.authenticationFailed {
            // Sem senha (ou senha errada): pede no próprio painel, como o Transmit.
            slot.passwordRequest = PasswordRequest(bookmark: bookmark, failed: password != nil)
        } catch {
            slot.connectionError = error.localizedDescription
        }
    }

    func submitPassword(in slot: PaneSlot, app: AppModel) {
        guard let request = slot.passwordRequest else { return }
        slot.passwordRequest = nil
        // O usuário digitado no pedido de senha passa a fazer parte do favorito salvo.
        if var saved = app.bookmark(id: request.bookmark.id), saved.username != request.bookmark.username {
            saved.username = request.bookmark.username
            app.save(saved)
        }
        if request.remember, app.bookmark(id: request.bookmark.id) != nil {
            Keychain.setPassword(request.password, for: request.bookmark)
        }
        Task { await connect(request.bookmark, in: slot, password: request.password, app: app) }
    }

    func disconnect(_ slot: PaneSlot) async {
        guard let files = slot.files, !files.isLocalConnection else { slot.showingServers = true; return }
        slot.files = nil
        slot.showingServers = true
        await files.base.disconnect()
    }

    /// Volta o lado para os arquivos deste Mac.
    func showLocal(_ slot: PaneSlot, path: String? = nil) async {
        if let files = slot.files, files.isLocalConnection {
            slot.showingServers = false
            if let path { await files.go(to: path) }
            return
        }
        if let files = slot.files { await files.base.disconnect() }
        let pane = PaneModel(fs: LocalFileSystem(), path: path)
        pane.onNavigate = { [weak self, weak slot] p in
            guard let self, let slot else { return }
            self.mirror(p, from: self.side(of: slot))
        }
        slot.files = pane
        slot.showingServers = false
        await pane.reload()
    }

    // MARK: Folder Linking

    func toggleLinking() {
        guard let l = left.visibleFiles, let r = right.visibleFiles else { linking = false; return }
        linking.toggle()
        linkBases = linking ? (l.path, r.path) : nil
    }

    /// Ao entrar numa pasta de um lado, abre a correspondente do outro.
    private func mirror(_ path: String, from side: Side) {
        guard linking, !linkingInProgress, let bases = linkBases, let target = slot(other(side)).visibleFiles else { return }
        let (mine, theirs) = side == .left ? (bases.left, bases.right) : (bases.right, bases.left)
        guard path == mine || path.hasPrefix(mine == "/" ? "/" : mine + "/") else { return }
        let relative = String(path.dropFirst(mine.count))
        linkingInProgress = true
        Task {
            await target.go(to: RemotePath.normalize(theirs + "/" + relative))
            linkingInProgress = false
        }
    }

    // MARK: Transferências

    func transferSelection(using queue: TransferQueue) {
        guard let from = activeFiles, let to = otherFiles else { return }
        transfer(from.selectedItems, from: from, to: to, into: to.path, using: queue)
    }

    func transfer(_ items: [FileItem], from: PaneModel, to: PaneModel, into folder: String, using queue: TransferQueue) {
        queue.enqueue(items, from: from.fs, to: to.fs, into: folder, bookmark: to.bookmark) { [weak to] in
            Task { await to?.reload() }
        }
    }

    func pane(with id: UUID) -> PaneModel? {
        [left.files, right.files].compactMap { $0 }.first { $0.id == id }
    }
}

/// Perguntas de segurança ao usuário durante a conexão.
enum TrustPrompter {
    nonisolated static let trust = ConnectionTrust(hostKey: { challenge in await askHostKey(challenge) },
                                       certificate: { challenge in await askCertificate(challenge) },
                                       passphrase: { request in await askPassphrase(request) },
                                       openBrowser: { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } },
                                       interactive: { challenge in await askInteractive(challenge) })

    /// Perguntas do keyboard-interactive (código 2FA, OTP…): uma caixa por pergunta.
    @MainActor
    static func askInteractive(_ c: InteractiveChallenge) -> [String]? {
        let alert = NSAlert()
        alert.messageText = c.name.isEmpty ? String(localized: "“\(c.host)” pede mais informações") : c.name
        alert.informativeText = c.instruction.isEmpty ? String(localized: "Usuário: \(c.user)") : c.instruction
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var fields: [NSTextField] = []
        for prompt in c.prompts {
            stack.addArrangedSubview(NSTextField(labelWithString: prompt.text.trimmingCharacters(in: .whitespaces)))
            let field = prompt.echo ? NSTextField() : NSSecureTextField()
            field.frame.size.width = 260
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(field)
            fields.append(field)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(c.prompts.count) * 48)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Continuar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        alert.window.initialFirstResponder = fields.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return fields.map(\.stringValue)
    }

    /// Chaves cuja frase o usuário recusou nesta sessão (não pergunta de novo a cada conexão).
    @MainActor private static var declinedKeys = Set<String>()

    @MainActor
    static func askPassphrase(_ request: PassphraseRequest) -> (passphrase: String, remember: Bool)? {
        guard !declinedKeys.contains(request.keyPath) else { return nil }
        let alert = NSAlert()
        alert.messageText = request.retry ? String(localized: "Frase secreta incorreta") : String(localized: "A chave SSH está protegida")
        alert.informativeText = String(localized: "Digite a frase secreta de “\((request.keyPath as NSString).abbreviatingWithTildeInPath)”.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Usar Chave"))
        alert.addButton(withTitle: String(localized: "Pular Esta Chave"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Lembrar no Chaves")
        alert.suppressionButton?.state = .on
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            declinedKeys.insert(request.keyPath)
            return nil
        }
        return (field.stringValue, alert.suppressionButton?.state == .on)
    }

    @MainActor
    static func askHostKey(_ c: HostKeyChallenge) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = c.changed ? .critical : .warning
        alert.messageText = c.changed ? String(localized: "A chave do servidor “\(c.host)” mudou") : String(localized: "Servidor desconhecido: “\(c.host)”")
        alert.informativeText = (c.changed
            ? String(localized: "Isso pode indicar que alguém está interceptando a conexão, ou que o servidor foi reinstalado. ")
            : String(localized: "É a primeira conexão com este servidor. "))
            + String(localized: "Confira a impressão digital com o administrador antes de continuar.\n\n\(c.keyType)\n\(c.fingerprint)")
        alert.addButton(withTitle: c.changed ? String(localized: "Cancelar") : String(localized: "Confiar e Conectar"))
        alert.addButton(withTitle: c.changed ? String(localized: "Confiar na Nova Chave") : String(localized: "Cancelar"))
        let response = alert.runModal()
        return c.changed ? response == .alertSecondButtonReturn : response == .alertFirstButtonReturn
    }

    @MainActor
    static func askCertificate(_ c: CertificateChallenge) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "O certificado de “\(c.host)” não é confiável")
        alert.informativeText = "\(c.reason)\n\nCertificado: \(c.summary)\nSHA-256: \(c.fingerprint)"
        alert.addButton(withTitle: String(localized: "Cancelar"))
        alert.addButton(withTitle: String(localized: "Confiar Sempre"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}
