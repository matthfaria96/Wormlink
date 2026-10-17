import SwiftUI
import WormlinkCore

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Geral", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Transferências", systemImage: "arrow.up.arrow.down", value: "transfers") { TransferSettingsView() }
            Tab("Regras", systemImage: "line.3.horizontal.decrease.circle", value: "rules") { SkipRulesSettings() }
            Tab("Servidores", systemImage: "server.rack", value: "servers") { ServersSettings() }
            Tab("Nuvens", systemImage: "cloud", value: "clouds") { CloudSettings() }
            Tab("Chaves", systemImage: "key", value: "keys") { KeysSettings() }
        }
        .frame(width: 520)
        .tint(.wormlink)
    }
}

private struct GeneralSettings: View {
    @AppStorage("showHiddenFiles") private var showHidden = false
    @AppStorage("doubleClickRemote") private var doubleClick = "transfer"
    @AppStorage("notifyTransfers") private var notify = true

    var body: some View {
        Form {
            Toggle("Mostrar arquivos ocultos em painéis novos", isOn: $showHidden)
            Picker("Duplo clique num arquivo remoto", selection: $doubleClick) {
                Text("Baixar para o outro lado").tag("transfer")
                Text("Editar no app padrão").tag("edit")
                Text("Editar no Wormlink").tag("editInternal")
            }
            Toggle("Avisar quando uma transferência terminar em segundo plano", isOn: $notify)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TransferSettingsView: View {
    @AppStorage("maxConcurrentTransfers") private var maxConcurrent = 2
    @AppStorage("conflictPolicy") private var conflict = "ask"
    @AppStorage("preserveDates") private var preserveDates = true
    @AppStorage("atomicUploads") private var atomicUploads = true
    @AppStorage("verifyChecksums") private var verifyChecksums = false
    @AppStorage("copyURLsAfterUpload") private var copyURLs = false
    @AppStorage("limitUploadKB") private var limitUpload = 0
    @AppStorage("limitDownloadKB") private var limitDownload = 0
    @State private var asciiList = FTPFileSystem.asciiExtensions.sorted().joined(separator: " ")

    var body: some View {
        Form {
            Stepper("Transferências simultâneas: \(maxConcurrent)", value: $maxConcurrent, in: 1...8)
            Section("Velocidade") {
                Picker("Limite de envio", selection: $limitUpload) { speedOptions }
                Picker("Limite de download", selection: $limitDownload) { speedOptions }
            }
            .onChange(of: limitUpload) { TransferSettings.applyBandwidthLimits() }
            .onChange(of: limitDownload) { TransferSettings.applyBandwidthLimits() }
            Section("Segurança") {
                Toggle("Enviar com nome temporário e renomear no fim", isOn: $atomicUploads)
                Text("Assim o arquivo no servidor nunca fica pela metade se a conexão cair.").font(.caption).foregroundStyle(.secondary)
                Toggle("Verificar cada arquivo depois de transferido", isOn: $verifyChecksums)
                Text("Usa o checksum do servidor (SHA-256 via SSH, HASH no FTP, MD5 no S3 e Google Drive, hash do Dropbox) ou, sem ele, o tamanho.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Copiar as URLs depois do envio", isOn: $copyURLs)
            Picker("Quando o arquivo já existe", selection: $conflict) {
                Text("Perguntar").tag("ask")
                ForEach(ConflictAction.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Preservar a data de modificação (quando o servidor permite)", isOn: $preserveDates)
            Text("Com datas preservadas, a sincronização reconhece arquivos iguais mesmo depois de transferidos.")
                .font(.caption).foregroundStyle(.secondary)
            Section("FTP em modo ASCII") {
                TextField("Extensões", text: $asciiList, axis: .vertical)
                    .lineLimit(2...3)
                    .onChange(of: asciiList) {
                        let list = asciiList.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                        UserDefaults.standard.set(list.filter { !$0.isEmpty }, forKey: "asciiExtensions")
                    }
                Text("Usadas pelos servidores FTP com “Modo ASCII” ligado no editor.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var speedOptions: some View {
        Text("Sem limite").tag(0)
        ForEach([64, 128, 256, 512, 1024, 2048, 5120, 10240, 25600], id: \.self) { kb in
            Text(kb >= 1024 ? "\(kb / 1024) MB/s" : "\(kb) KB/s").tag(kb)
        }
    }
}

private struct SkipRulesSettings: View {
    @AppStorage("skipPatterns") private var stored = SkipRules.default.patterns.joined(separator: "\n")
    @State private var patterns: [String] = []
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Itens com estes nomes são ignorados em transferências e sincronizações. Use * e ? como curingas.")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(patterns.indices, id: \.self) { index in
                    TextField("padrão", text: Binding(get: { patterns[index] }, set: { patterns[index] = $0; save() }))
                        .textFieldStyle(.plain)
                        .tag(index)
                }
            }
            .listStyle(.bordered)
            .frame(height: 200)
            HStack {
                Button("Adicionar", systemImage: "plus") { patterns.append("*.log"); save() }
                Button("Remover", systemImage: "minus") {
                    if let selection, patterns.indices.contains(selection) { patterns.remove(at: selection); save() }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Restaurar Padrões") { patterns = SkipRules.default.patterns; save() }
            }
            .labelStyle(.iconOnly)
        }
        .padding(20)
        .onAppear { patterns = UserDefaults.standard.stringArray(forKey: "skipPatterns") ?? SkipRules.default.patterns }
    }

    private func save() { UserDefaults.standard.set(patterns.filter { !$0.isEmpty }, forKey: "skipPatterns") }
}

private struct ServersSettings: View {
    @Environment(AppModel.self) private var app
    @State private var imported = PresetStore.imported()
    @State private var importError: String?

    var body: some View {
        Form {
            Section("Perfis de conexão") {
                if imported.isEmpty {
                    Text("Os serviços prontos (Wasabi, R2, Backblaze, Nextcloud…) aparecem no menu Protocolo do editor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(imported) { preset in
                    LabeledContent(preset.name, value: preset.connectionProtocol.displayName)
                }
                Button("Importar Perfil do Cyberduck…") { importProfile() }
                if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            }
            Section("Importar e exportar") {
                HStack {
                    Menu("Importar de…") {
                        ForEach(ServerImporter.allCases) { source in
                            Button(source.title) { app.importServers(from: source) }
                        }
                    }
                    .fixedSize()
                    Button("Exportar…") { app.exportServers() }
                    Button("Restaurar…") { app.restoreServers() }
                }
                Text("Cyberduck, Transmit, FileZilla e WinSCP. O backup (.wormlinkservers) pode incluir as senhas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Mostrar servidores da rede local (Bonjour)", isOn: Binding(get: { app.showBonjour }, set: { app.showBonjour = $0 }))
            Toggle("Sincronizar servidores pelo iCloud Drive", isOn: Binding(get: { app.iCloudSync }, set: { app.iCloudSync = $0 }))
            Text("Os favoritos ficam em iCloud Drive › Wormlink e aparecem nos seus outros Macs. As senhas continuam só no Chaves deste Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if app.iCloudSync && !app.iCloudAvailable {
                Label("O iCloud Drive não está ativo neste Mac.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "cyberduckprofile") ?? .data]
        panel.prompt = String(localized: "Importar")
        guard panel.runModal() == .OK else { return }
        importError = nil
        for url in panel.urls {
            do { try PresetStore.add(try ConnectionPreset.cyberduckProfile(Data(contentsOf: url))) } catch {
                importError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        imported = PresetStore.imported()
    }
}

/// Client IDs dos apps OAuth que o usuário cadastra em cada provedor.
private struct CloudSettings: View {
    @AppStorage("oauth.dropbox.clientID") private var dropbox = ""
    @AppStorage("oauth.google.clientID") private var google = ""
    @AppStorage("oauth.google.clientSecret") private var googleSecret = ""
    @AppStorage("oauth.onedrive.clientID") private var onedrive = ""
    @AppStorage("oauth.box.clientID") private var box = ""
    @AppStorage("oauth.box.clientSecret") private var boxSecret = ""

    var body: some View {
        Form {
            Section {
                Text("Cada nuvem exige um app cadastrado no provedor (gratuito). Use como endereço de retorno:")
                Text(OAuthProvider.redirectURI).font(.body.monospaced()).textSelection(.enabled)
            }
            Section("Dropbox") {
                TextField("App key", text: $dropbox)
                Link("Criar app no Dropbox (escopo: arquivos)", destination: URL(string: "https://www.dropbox.com/developers/apps")!)
            }
            Section("Google Drive") {
                TextField("Client ID", text: $google)
                SecureField("Client secret (apps do tipo Desktop)", text: $googleSecret)
                Link("Criar credencial OAuth (Desktop) no Google Cloud", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
            }
            Section("Box") {
                TextField("Client ID", text: $box)
                SecureField("Client secret", text: $boxSecret)
                Link("Criar app no Box (OAuth 2.0, redirect acima)", destination: URL(string: "https://app.box.com/developers/console")!)
            }
            Section("Microsoft OneDrive e SharePoint") {
                TextField("Application (client) ID", text: $onedrive)
                Link("Registrar app no Microsoft Entra (cliente público)", destination: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}
