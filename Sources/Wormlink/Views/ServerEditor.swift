import SwiftUI
import UniformTypeIdentifiers
import WormlinkCore

/// Editor de servidor dentro do painel: ícone no topo e os campos num Form agrupado, como os Ajustes do Sistema.
struct ServerEditor: View {
    @Environment(AppModel.self) private var app
    @Bindable var slot: PaneSlot
    var window: WindowModel
    @State private var draft: ServerDraft
    @State private var showIcons = false

    init(slot: PaneSlot, window: WindowModel) {
        self.slot = slot
        self.window = window
        _draft = State(initialValue: slot.editing ?? ServerDraft(bookmark: Bookmark(), isNew: true))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nome", text: $draft.bookmark.nickname,
                              prompt: Text(draft.bookmark.hostname.isEmpty ? "Nome" : draft.bookmark.hostname))
                } header: {
                    Button {
                        showIcons = true
                    } label: {
                        ServerIconView(draft.bookmark, size: 64)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "chevron.down.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.secondary, .background)
                                    .font(.title3)
                                    .offset(x: 6, y: 6)
                            }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showIcons, arrowEdge: .bottom) { IconPicker(bookmark: $draft.bookmark) }
                    .help("Escolher ícone e cor")
                    .accessibilityLabel("Escolher ícone e cor")
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                }
                ConnectionFields(bookmark: $draft.bookmark, password: $draft.password, showPaths: true)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Salvar como Droplet") {
                    save(connect: false)
                    Droplets.save(draft.bookmark)
                }
                .disabled(!isValid)
                Button("Conectar") { save(connect: true) }
                    .disabled(!isValid)
                Spacer()
                Button("Cancelar") { slot.editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") { save(connect: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var isValid: Bool {
        !draft.bookmark.hostname.isEmpty || !FieldSpec(draft.bookmark).showHost || [.s3, .azure].contains(draft.bookmark.connectionProtocol)
    }

    private func save(connect: Bool) {
        var bookmark = draft.bookmark
        if bookmark.connectionProtocol == .s3 && bookmark.hostname.isEmpty { bookmark.hostname = "s3.amazonaws.com" }
        if let host = bookmark.connectionProtocol.fixedHost { bookmark.hostname = host }
        app.save(bookmark)
        if !draft.password.isEmpty { Keychain.setPassword(draft.password, for: bookmark) }
        slot.selectedServer = bookmark.id
        slot.editing = nil
        if connect { Task { await window.connect(bookmark, in: slot, password: draft.password.isEmpty ? nil : draft.password, app: app) } }
    }
}

/// Quick Connect: os mesmos campos, sem salvar.
struct QuickConnectView: View {
    @Environment(AppModel.self) private var app
    @Bindable var slot: PaneSlot
    var window: WindowModel
    @State private var address = ""
    @State private var addToServers = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("URL", text: $address, prompt: Text("sftp://usuario@servidor/pasta"))
                        .onChange(of: address) { applyAddress() }
                } header: {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 48))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                        Text("Conexão rápida").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                } footer: {
                    Text("Cole um endereço completo ou preencha os campos abaixo.")
                }
                ConnectionFields(bookmark: $slot.quickConnect.bookmark, password: $slot.quickConnect.password, showPaths: false)
                Section {
                    Toggle("Adicionar aos Servidores", isOn: $addToServers)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Conectar", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(slot.quickConnect.bookmark.hostname.isEmpty && FieldSpec(slot.quickConnect.bookmark).showHost
                              && ![.s3, .azure].contains(slot.quickConnect.bookmark.connectionProtocol))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func applyAddress() {
        guard let parsed = Bookmark(address: address) else { return }
        var b = slot.quickConnect.bookmark
        b.connectionProtocol = parsed.connectionProtocol
        b.hostname = parsed.hostname
        b.port = parsed.port
        if !parsed.username.isEmpty { b.username = parsed.username }
        if !parsed.path.isEmpty { b.path = parsed.path }
        slot.quickConnect.bookmark = b
    }

    private func connect() {
        var bookmark = slot.quickConnect.bookmark
        if bookmark.connectionProtocol == .s3 && bookmark.hostname.isEmpty { bookmark.hostname = "s3.amazonaws.com" }
        if let host = bookmark.connectionProtocol.fixedHost { bookmark.hostname = host }
        bookmark.icon = .default(for: bookmark.connectionProtocol)
        let password = slot.quickConnect.password
        if addToServers {
            app.save(bookmark)
            if !password.isEmpty { Keychain.setPassword(password, for: bookmark) }
        }
        slot.quickConnect = ServerDraft(bookmark: Bookmark(connectionProtocol: bookmark.connectionProtocol), isNew: true)
        address = ""
        Task { await window.connect(bookmark, in: slot, password: password.isEmpty ? nil : password, app: app) }
    }
}

/// Rótulos e campos visíveis de cada protocolo (e do perfil de serviço escolhido).
struct FieldSpec {
    var hostLabel = String(localized: "Endereço"), hostPrompt = String(localized: "servidor.com"), showHost = true, showPort = true
    var userLabel = String(localized: "Usuário"), userPrompt = String(localized: "usuário"), showCredentials = true
    var passwordLabel = String(localized: "Senha"), passwordPrompt = String(localized: "senha")
    var pathLabel = String(localized: "Caminho remoto"), pathPrompt = "/www/projeto"
    var note: String?

    init(_ bookmark: Bookmark) {
        switch bookmark.connectionProtocol {
        case .s3:
            hostLabel = "Endpoint"; hostPrompt = "s3.amazonaws.com"
            userLabel = "Access Key ID"; userPrompt = String(localized: "AKIA… (ou use um perfil AWS)")
            passwordLabel = "Secret Key"; passwordPrompt = String(localized: "secret access key")
            pathLabel = String(localized: "Bucket/pasta"); pathPrompt = "/meu-bucket"
        case .b2:
            showHost = false; showPort = false
            userLabel = "Key ID"; userPrompt = String(localized: "keyID da Application Key")
            passwordLabel = "Application Key"; passwordPrompt = "applicationKey"
            pathLabel = String(localized: "Bucket/pasta"); pathPrompt = "/meu-bucket"
        case .azure:
            hostPrompt = "<conta>.blob.core.windows.net (opcional)"; showPort = false
            userLabel = String(localized: "Conta"); userPrompt = String(localized: "nome da conta de armazenamento")
            passwordLabel = String(localized: "Chave ou SAS"); passwordPrompt = String(localized: "chave de acesso ou token SAS")
            pathLabel = String(localized: "Contêiner/pasta"); pathPrompt = "/meu-conteiner"
        case .swift:
            hostLabel = String(localized: "Autenticação"); hostPrompt = "identity.servidor.com"
            userPrompt = "projeto:usuário"; passwordPrompt = String(localized: "senha ou API key")
            pathLabel = String(localized: "Contêiner/pasta"); pathPrompt = "/meu-conteiner"
        case .smb:
            userPrompt = String(localized: "usuário (vazio = convidado)")
            pathLabel = String(localized: "Compartilhamento"); pathPrompt = "/Documentos"
        case .sharePoint:
            hostLabel = "Site"; hostPrompt = "empresa.sharepoint.com"; showPort = false; showCredentials = false
            pathLabel = String(localized: "Caminho do site"); pathPrompt = "/sites/Equipe"
        case .dropbox, .box, .googleDrive, .oneDrive:
            showHost = false; showPort = false; showCredentials = false
        default: break
        }
        if let id = bookmark.preset, let preset = PresetStore.all.first(where: { $0.id == id }) {
            if let label = preset.userLabel { userLabel = label }
            if let label = preset.passwordLabel { passwordLabel = label }
            if !preset.hostnameEditable { showHost = false; showPort = false }
            note = preset.note
        }
    }
}

/// Campos de conexão em seções de Form agrupado (rótulo à esquerda, valor à direita).
struct ConnectionFields: View {
    @Binding var bookmark: Bookmark
    @Binding var password: String
    var showPaths: Bool
    @State private var showAdvanced = ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_ADVANCED"] != nil
    @State private var showServerOptions = ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_ADVANCED"] != nil

    private var spec: FieldSpec { FieldSpec(bookmark) }
    private var proto: ConnectionProtocol { bookmark.connectionProtocol }

    var body: some View {
        Section {
            Picker("Protocolo", selection: kindBinding) {
                Section("Protocolos") {
                    ForEach(ConnectionProtocol.allCases) { proto in
                        Label(proto.displayName, systemImage: proto.symbolName).tag("proto:" + proto.rawValue)
                    }
                }
                Section("Serviços") {
                    ForEach(PresetStore.all) { preset in
                        Label(preset.name, systemImage: preset.connectionProtocol.symbolName).tag("preset:" + preset.id)
                    }
                }
            }
            if proto == .ftp || proto == .ftps {
                Toggle("Modo passivo", isOn: .constant(true))
                    .disabled(true)
                    .help("O Wormlink sempre usa o modo passivo (EPSV/PASV).")
            }
            if proto == .s3 || proto == .azure || proto == .swift {
                Toggle("Sem TLS (HTTP), para servidores locais ou emuladores", isOn: $bookmark.plainHTTP)
            }
            if spec.showHost {
                field(spec.hostLabel, prompt: spec.hostPrompt, text: $bookmark.hostname)
                if spec.showPort {
                    TextField("Porta", value: $bookmark.port, format: .number.grouping(.never))
                }
            }
            if proto == .swift {
                Picker("Versão", selection: Binding(get: { bookmark.swiftAuthPath ?? "/v3" }, set: { bookmark.swiftAuthPath = $0 })) {
                    Text("Keystone 3").tag("/v3")
                    Text("Keystone 2").tag("/v2.0")
                    Text("TempAuth / v1").tag("/auth/v1.0")
                }
                field(String(localized: "Região"), prompt: String(localized: "opcional"), text: optionalBinding(\.swiftRegion))
            }
        } footer: {
            if let note = spec.note { Text(note) }
        }

        if proto.isOAuth {
            Section {
                LabeledContent("Conta") {
                    Text(bookmark.username.isEmpty ? String(localized: "Ao conectar, o navegador abre para você entrar.") : bookmark.username)
                        .foregroundStyle(bookmark.username.isEmpty ? .secondary : .primary)
                }
                if proto.oauthProvider?.clientID.isEmpty == true {
                    SettingsLink {
                        Label("Configure o Client ID em Ajustes › Nuvens", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.link)
                }
            }
        }

        if spec.showCredentials || proto == .sftp || proto == .s3 {
            Section {
                if spec.showCredentials {
                    field(spec.userLabel, prompt: spec.userPrompt, text: $bookmark.username)
                    SecureField(spec.passwordLabel, text: $password,
                                prompt: Text(proto == .sftp ? String(localized: "senha (ou use uma chave)") : spec.passwordPrompt))
                }
                if proto == .sftp {
                    LabeledContent("Chave SSH") {
                        HStack(spacing: 6) {
                            Text(bookmark.keyFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "Automática"))
                                .foregroundStyle(bookmark.keyFile == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(bookmark.keyFile == nil ? String(localized: "~/.ssh, ~/.ssh/config e agente (automático)") : "")
                            if bookmark.keyFile != nil {
                                BarButton(title: String(localized: "Limpar chave"), symbol: "xmark.circle.fill") { bookmark.keyFile = nil }
                            }
                            Button("Escolher…", action: chooseKey)
                        }
                    }
                }
                if proto == .s3 { s3Advanced }
            }
        }

        Section {
            if showPaths && proto != .sharePoint {
                field(String(localized: "URL raiz"), prompt: "http://www.servidor.com/projeto", text: optionalBinding(\.webURL))
            }
            field(spec.pathLabel, prompt: spec.pathPrompt, text: $bookmark.path)
            if showPaths {
                LabeledContent("Caminho local") {
                    HStack(spacing: 6) {
                        TextField("Caminho local", text: Binding(
                            get: { bookmark.localPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "" },
                            set: { bookmark.localPath = $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }),
                                  prompt: Text("~/Sites/projeto"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        Button("Escolher…", action: chooseLocalFolder)
                    }
                }
            }
        }

        if showPaths { serverOptions }
    }

    /// Ajustes deste servidor (Transmit: "Server-specific preferences"; Cyberduck: aba Avançado do favorito).
    @ViewBuilder
    private var serverOptions: some View {
        let isFTP = proto == .ftp || proto == .ftps
        Section {
            DisclosureGroup("Avançado", isExpanded: $showServerOptions) {
                if !proto.isOAuth {
                    LabeledContent("Tempo limite") {
                        HStack(spacing: 6) {
                            TextField("Tempo limite", value: Binding(get: { bookmark.timeout ?? 20 },
                                                                     set: { bookmark.timeout = $0 == 20 ? nil : max(5, min($0, 600)) }),
                                      format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Text("segundos").foregroundStyle(.secondary)
                        }
                    }
                }
                if isFTP {
                    Picker("Codificação", selection: Binding(get: { bookmark.encoding ?? "" },
                                                             set: { bookmark.encoding = $0.isEmpty ? nil : $0 })) {
                        ForEach(Self.encodings, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    Toggle("Listar com MLSD quando o servidor oferece", isOn: Binding(
                        get: { bookmark.ftpUseMLSD ?? true }, set: { bookmark.ftpUseMLSD = $0 ? nil : false }))
                    Toggle("Modo ASCII para arquivos de texto", isOn: Binding(
                        get: { bookmark.ftpASCIIMode ?? false }, set: { bookmark.ftpASCIIMode = $0 ? true : nil }))
                        .help("Converte fins de linha (CRLF ↔ LF) em .txt, .html, .php… — ajuste a lista em Ajustes › Transferências.")
                }
                if proto == .s3 {
                    Picker("Classe padrão", selection: optionalBinding(\.s3StorageClass)) {
                        Text("Do bucket").tag("")
                        ForEach(S3StorageClass.all, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    Picker("Criptografia", selection: optionalBinding(\.s3Encryption)) {
                        ForEach(S3Encryption.all, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    Picker("Acesso", selection: optionalBinding(\.s3ACL)) {
                        Text("Do bucket").tag("")
                        ForEach(S3CannedACL.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Quem baixa paga (Requester Pays)", isOn: Binding(
                        get: { bookmark.s3RequesterPays ?? false }, set: { bookmark.s3RequesterPays = $0 ? true : nil }))
                    Toggle("Usar Transfer Acceleration", isOn: Binding(
                        get: { bookmark.s3Accelerate ?? false }, set: { bookmark.s3Accelerate = $0 ? true : nil }))
                }
                TextField("Notas", text: optionalBinding(\.comment), prompt: Text("opcional"), axis: .vertical)
                    .lineLimit(1...4)
            }
        }
    }

    static let encodings: [(id: String, title: String)] = [
        ("", "Unicode (UTF-8)"), ("iso-8859-1", String(localized: "Ocidental (ISO Latin 1)")), ("windows-1252", String(localized: "Ocidental (Windows)")),
        ("macintosh", String(localized: "Ocidental (Mac OS Roman)")), ("iso-8859-2", String(localized: "Europa Central (ISO Latin 2)")),
        ("windows-1251", String(localized: "Cirílico (Windows)")), ("koi8-r", String(localized: "Cirílico (KOI8-R)")), ("shift_jis", String(localized: "Japonês (Shift JIS)")),
        ("euc-jp", String(localized: "Japonês (EUC)")), ("gb18030", String(localized: "Chinês Simplificado (GB 18030)")), ("big5", String(localized: "Chinês Tradicional (Big 5)")),
        ("euc-kr", String(localized: "Coreano (EUC)")),
    ]

    /// "Amazon S3 with IAM Role" do Transmit + perfis da AWS CLI.
    @ViewBuilder
    private var s3Advanced: some View {
        Picker("Perfil AWS", selection: Binding(get: { bookmark.awsProfile ?? "" }, set: { bookmark.awsProfile = $0.isEmpty ? nil : $0 })) {
            Text("Nenhum (usar as chaves acima)").tag("")
            ForEach(AWSProfiles.load().names, id: \.self) { Text($0).tag($0) }
        }
        DisclosureGroup("IAM Role, MFA e STS", isExpanded: $showAdvanced) {
            field("Papel (ARN)", prompt: "arn:aws:iam::123456789012:role/Nome", text: optionalBinding(\.roleARN))
            field("External ID", prompt: String(localized: "opcional"), text: optionalBinding(\.externalID))
            field("MFA (ARN)", prompt: "arn:aws:iam::123456789012:mfa/usuário", text: optionalBinding(\.mfaSerial))
            field("Endpoint STS", prompt: "https://sts.amazonaws.com", text: optionalBinding(\.stsEndpoint))
        }
    }

    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        TextField(label, text: text, prompt: Text(prompt))
    }

    private func optionalBinding(_ key: WritableKeyPath<Bookmark, String?>) -> Binding<String> {
        Binding(get: { bookmark[keyPath: key] ?? "" }, set: { bookmark[keyPath: key] = $0.isEmpty ? nil : $0 })
    }

    /// Protocolo puro ("proto:sftp") ou perfil de serviço ("preset:wasabi").
    private var kindBinding: Binding<String> {
        Binding(get: { bookmark.preset.map { "preset:" + $0 } ?? "proto:" + bookmark.connectionProtocol.rawValue }, set: { tag in
            let old = bookmark.connectionProtocol
            if tag.hasPrefix("preset:"), let preset = PresetStore.all.first(where: { "preset:" + $0.id == tag }) {
                preset.apply(to: &bookmark)
                if bookmark.nickname.isEmpty { bookmark.nickname = preset.name }
            } else if let new = ConnectionProtocol(rawValue: String(tag.dropFirst(6))) {
                bookmark.preset = nil
                if bookmark.port == old.defaultPort { bookmark.port = new.defaultPort }
                if bookmark.icon == .default(for: old) { bookmark.icon = .default(for: new) }
                if let host = new.fixedHost { bookmark.hostname = host } else if old.fixedHost != nil { bookmark.hostname = "" }
                bookmark.connectionProtocol = new
            }
        })
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Usar Chave")
        if panel.runModal() == .OK, let url = panel.url { bookmark.keyFile = url.path }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Escolher")
        if panel.runModal() == .OK, let url = panel.url { bookmark.localPath = url.path }
    }
}

/// Grade de símbolos e cores para o ícone do servidor.
struct IconPicker: View {
    @Binding var bookmark: Bookmark

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 4), spacing: 8) {
                ForEach(ServerIcon.allCases, id: \.self) { icon in
                    Button { bookmark.icon = icon } label: {
                        ServerIconView(icon: icon, color: bookmark.color, size: 36)
                            .overlay { if bookmark.icon == icon { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary, lineWidth: 2).padding(-3) } }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                ForEach(ServerColor.allCases, id: \.self) { color in
                    Button { bookmark.color = color } label: {
                        Circle().fill(color.color.gradient).frame(width: 18, height: 18)
                            .overlay { if bookmark.color == color { Circle().strokeBorder(.primary, lineWidth: 2).padding(-3) } }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}
