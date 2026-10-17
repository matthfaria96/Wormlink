import SwiftUI
import WormlinkCore

extension SSHKeyManager.Key {
    /// "ssh-ed25519" → "Ed25519", "ecdsa-sha2-nistp256" → "ECDSA".
    var kind: String {
        if type.contains("ed25519") { return "Ed25519" }
        if type.hasPrefix("ecdsa") { return "ECDSA" }
        if type.contains("rsa") { return "RSA" }
        return type.replacingOccurrences(of: "ssh-", with: "")
    }
}

/// Ajustes › Chaves: as chaves SSH de ~/.ssh (listar, gerar, importar, copiar a pública).
struct KeysSettings: View {
    @State private var keys = SSHKeyManager.list()
    @State private var selection: SSHKeyManager.Key.ID?
    @State private var generating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chaves em ~/.ssh. O Wormlink usa estas chaves (e as do agente SSH) ao conectar por SFTP.")
                .font(.caption).foregroundStyle(.secondary)
            Table(keys, selection: $selection) {
                TableColumn("Nome") { key in
                    Label(key.name, systemImage: key.isEncrypted ? "key.horizontal.fill" : "key.horizontal")
                }
                TableColumn("Tipo") { key in Text(key.kind) }.width(70)
                TableColumn("Impressão digital") { key in
                    Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 200)
            .contextMenu(forSelectionType: SSHKeyManager.Key.ID.self) { ids in
                if let key = keys.first(where: { ids.contains($0.id) }) {
                    Button("Copiar Chave Pública") { copy(key) }
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: key.privatePath)]) }
                }
            }
            HStack {
                Button("Gerar Chave…") { generating = true }
                Button("Importar…", action: importKey)
                Spacer()
                Button("Copiar Chave Pública") { if let key = selected { copy(key) } }.disabled(selected == nil)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(20)
        .sheet(isPresented: $generating) {
            GenerateKeySheet { key in keys = SSHKeyManager.list(); selection = key.id }
        }
    }

    private var selected: SSHKeyManager.Key? { keys.first { $0.id == selection } }

    private func copy(_ key: SSHKeyManager.Key) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Escolha uma chave privada (OpenSSH ou PEM) para copiar para ~/.ssh.")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let key = try SSHKeyManager.importKey(from: url)
            keys = SSHKeyManager.list()
            selection = key.id
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GenerateKeySheet: View {
    var onCreate: (SSHKeyManager.Key) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var type = SSHKeyManager.KeyType.ed25519
    @State private var name = "id_ed25519"
    @State private var passphrase = ""
    @State private var comment = NSUserName() + "@" + (Host.current().localizedName ?? "Mac")
    @State private var error: String?

    var body: some View {
        Form {
            Picker("Tipo", selection: $type) {
                ForEach(SSHKeyManager.KeyType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: type) { name = "id_" + type.rawValue }
            TextField("Nome do arquivo", text: $name)
            SecureField("Frase-senha (opcional)", text: $passphrase)
            TextField("Comentário", text: $comment)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Gerar") {
                    do {
                        let key = try SSHKeyManager.generate(type, name: name, passphrase: passphrase, comment: comment)
                        if !passphrase.isEmpty { Keychain.setKeyPassphrase(passphrase, for: key.privatePath) }
                        onCreate(key)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(name.isEmpty || name.contains("/"))
            }
        }
    }
}

/// Instala uma chave pública no ~/.ssh/authorized_keys do servidor SFTP conectado ("Copiar ID" do Cyberduck).
struct InstallKeySheet: View {
    var fs: SFTPFileSystem
    @Environment(\.dismiss) private var dismiss
    @State private var keys = SSHKeyManager.list()
    @State private var selection: String?
    @State private var state: Status = .idle

    enum Status: Equatable { case idle, working, done, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Instalar chave pública em “\(fs.title)”").font(.headline)
            Text("A chave é acrescentada a \(authorizedKeys). Depois disso o servidor aceita a chave sem pedir senha.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if keys.isEmpty {
                Text("Nenhuma chave em ~/.ssh. Gere uma em Ajustes › Chaves.").foregroundStyle(.secondary)
            } else {
                Picker("Chave", selection: $selection) {
                    ForEach(keys) { key in Text("\(key.name) (\(key.kind))").tag(Optional(key.id)) }
                }
            }
            switch state {
            case .working: ProgressView().controlSize(.small)
            case .done: Label("Chave instalada.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
            case .idle: EmptyView()
            }
            HStack {
                Spacer()
                Button(state == .done ? "OK" : "Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                if state != .done {
                    Button("Instalar", action: install)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(selection == nil || state == .working)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { selection = keys.first?.id }
    }

    private var authorizedKeys: String { RemotePath.join(fs.loginDirectory, ".ssh/authorized_keys") }

    private func install() {
        guard let key = keys.first(where: { $0.id == selection }) else { return }
        state = .working
        Task {
            do {
                try await SSHKeyManager.install(key.publicKey, on: fs, authorizedKeys: authorizedKeys)
                state = .done
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
