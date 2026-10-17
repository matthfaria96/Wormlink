import SwiftUI
import WormlinkCore

/// Faixa acima da lista quando a pasta é um cofre do Cryptomator (trancado ou aberto).
struct VaultBar: View {
    var pane: PaneModel
    @State private var working = false

    var body: some View {
        HStack(spacing: 8) {
            if let vault = pane.vault(at: pane.path) {
                Image(systemName: "lock.open.fill").foregroundStyle(Color.wormlink)
                Text("Cofre “\(RemotePath.name(vault.root))” desbloqueado").font(.callout)
                Spacer()
                Button("Trancar") { Task { await pane.lockVault() } }
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text("Cofre do Cryptomator").font(.callout)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Desbloquear…") { Task { await unlock() } }.disabled(working)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.wormlink.opacity(0.08))
        .task(id: pane.lockedVault) {
            // Senha guardada no Chaves: abre sozinho, sem perguntar.
            guard let root = pane.lockedVault, let saved = Keychain.vaultPassword(for: pane.vaultAccount(root)) else { return }
            working = true
            defer { working = false }
            try? await pane.unlockVault(password: saved)
        }
    }

    private func unlock() async {
        guard let root = pane.lockedVault else { return }
        var failed = false
        while let answer = VaultPrompts.password(for: RemotePath.name(root), retry: failed) {
            working = true
            defer { working = false }
            do {
                try await pane.unlockVault(password: answer.password)
                let account = pane.vaultAccount(root)
                if answer.remember { Keychain.setVaultPassword(answer.password, for: account) } else { Keychain.deleteVaultPassword(for: account) }
                return
            } catch CryptomatorError.wrongPassword {
                failed = true
            } catch {
                pane.operationError = error.localizedDescription
                return
            }
        }
    }
}

@MainActor
enum VaultPrompts {
    static func password(for name: String, retry: Bool) -> (password: String, remember: Bool)? {
        let alert = NSAlert()
        alert.messageText = retry ? String(localized: "Senha do cofre incorreta") : String(localized: "Desbloquear “\(name)”")
        alert.informativeText = String(localized: "Digite a senha do cofre do Cryptomator.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Desbloquear"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Lembrar no Chaves")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, alert.suppressionButton?.state == .on)
    }

    /// Pede nome e senha (duas vezes) e cria o cofre na pasta atual do painel.
    static func create(in pane: PaneModel) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "Novo Cofre Criptografado")
        alert.informativeText = String(localized: "Os arquivos guardados no cofre são criptografados antes de ir para o servidor. Ele abre no Cryptomator e no Cyberduck. Sem a senha não há como recuperá-los.")
        let name = NSTextField(string: String(localized: "Cofre"))
        let password = NSSecureTextField(), confirm = NSSecureTextField()
        name.placeholderString = String(localized: "Nome")
        password.placeholderString = String(localized: "Senha")
        confirm.placeholderString = String(localized: "Confirmar senha")
        let stack = NSStackView(views: [name, password, confirm])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 88)
        for field in [name, password, confirm] { field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Criar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Lembrar no Chaves")
        alert.window.initialFirstResponder = name
        while alert.runModal() == .alertFirstButtonReturn {
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            if title.isEmpty || title.contains("/") {
                alert.informativeText = String(localized: "Escolha um nome de pasta válido.")
            } else if password.stringValue.count < 8 {
                alert.informativeText = String(localized: "Use uma senha com pelo menos 8 caracteres.")
            } else if password.stringValue != confirm.stringValue {
                alert.informativeText = String(localized: "As senhas não são iguais.")
            } else {
                let root = RemotePath.join(pane.path, title)
                do {
                    try await pane.createVault(named: title, password: password.stringValue)
                    if alert.suppressionButton?.state == .on { Keychain.setVaultPassword(password.stringValue, for: pane.vaultAccount(root)) }
                } catch {
                    pane.operationError = error.localizedDescription
                }
                return
            }
        }
    }
}
