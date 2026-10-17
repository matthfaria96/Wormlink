import SwiftUI
import WormlinkCore

/// Lado da janela com a lista de servidores (ou o editor, a senha, o Quick Connect).
struct ServersPane: View {
    @Environment(AppModel.self) private var app
    var window: WindowModel
    @Bindable var slot: PaneSlot
    @State private var creatingGroup = false
    @State private var renamingGroup: String?
    @State private var groupName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                if let request = slot.passwordRequest {
                    PasswordPrompt(request: request, slot: slot, window: window)
                } else if slot.editing != nil {
                    ServerEditor(slot: slot, window: window)
                } else if slot.serversTab == .quickConnect {
                    QuickConnectView(slot: slot, window: window)
                } else {
                    VStack(spacing: 0) {
                        serverList
                        Divider()
                        bottomBar
                    }
                }
                if let bookmark = slot.connecting {
                    connectingOverlay(bookmark)
                }
            }
        }
        .alert("Novo Grupo", isPresented: $creatingGroup) {
            TextField("Nome", text: $groupName)
            Button("Criar") { app.addGroup(groupName) }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Renomear Grupo", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Nome", text: $groupName)
            Button("Renomear") { if let old = renamingGroup { app.renameGroup(old, to: groupName) } }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Não foi possível conectar", isPresented: Binding(get: { slot.connectionError != nil },
                                                                  set: { if !$0 { slot.connectionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(slot.connectionError ?? "") }
    }

    // MARK: Cabeçalho: local | [Servidores | Quick Connect] | lista/grade

    /// Segmento escolhido; nenhum enquanto o editor ou a senha estão à frente.
    private var tab: Binding<PaneSlot.ServersTab?> {
        Binding(get: { slot.editing == nil && slot.passwordRequest == nil ? slot.serversTab : nil }, set: { tab in
            slot.editing = nil
            slot.passwordRequest = nil
            slot.serversTab = tab ?? .servers
        })
    }

    private var header: some View {
        ZStack {
            Picker("Modo", selection: tab) {
                Text("Servidores").tag(Optional(PaneSlot.ServersTab.servers))
                Text("Quick Connect").tag(Optional(PaneSlot.ServersTab.quickConnect))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack {
                LocationMenu(window: window, slot: slot)
                Spacer()
                if slot.serversTab == .servers && slot.editing == nil && slot.passwordRequest == nil {
                    BarButton(title: slot.serversAsGrid ? String(localized: "Ver como lista") : String(localized: "Ver como grade"),
                              symbol: slot.serversAsGrid ? "list.bullet" : "square.grid.2x2") { slot.serversAsGrid.toggle() }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    // MARK: Lista

    private var filtered: [Bookmark] {
        let source: [Bookmark] = switch slot.serversPage {
        case .all: window.search.isEmpty ? app.bookmarks.filter { $0.group == nil } : app.bookmarks
        case .history: app.history.map(\.bookmark)
        case .cyberduck: app.cyberduckCandidates
        case .bonjour: app.bonjour.servers
        case .group(let name): app.bookmarks.filter { $0.group == name }
        }
        guard !window.search.isEmpty else { return source }
        return source.filter {
            $0.displayName.localizedCaseInsensitiveContains(window.search) || $0.hostname.localizedCaseInsensitiveContains(window.search)
        }
    }

    private var serverList: some View {
        List(selection: $slot.selectedServer) {
            Section {
                if slot.serversAsGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 12) {
                        ForEach(filtered) { bookmark in tile(bookmark) }
                    }
                    .padding(.vertical, 6)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { bookmark in row(bookmark) }
                }
                if filtered.isEmpty && window.search.isEmpty && slot.serversPage == .all { emptyState }
            } header: {
                if slot.serversPage != .all { pageHeader }
            }
            if slot.serversPage == .all && window.search.isEmpty {
                Section("Coleções") {
                    ForEach(app.groups, id: \.self) { group in
                        let count = app.bookmarks.filter { $0.group == group }.count
                        groupRow(group, symbol: "folder", detail: count == 1 ? String(localized: "1 servidor") : String(localized: "\(count) servidores")) {
                            slot.serversPage = .group(group)
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            ids.compactMap(UUID.init(uuidString:)).forEach { app.move($0, toGroup: group) }
                            return true
                        }
                        .contextMenu {
                            Button("Renomear Grupo…") { renamingGroup = group; groupName = group }
                            Divider()
                            Button("Apagar Grupo", role: .destructive) { app.removeGroup(group) }
                        }
                    }
                    groupRow(String(localized: "Histórico"), symbol: "clock.arrow.circlepath",
                             detail: app.history.first.map { $0.date.formatted(.relative(presentation: .named)) } ?? String(localized: "Vazio")) {
                        slot.serversPage = .history
                    }
                    if app.showBonjour {
                        let count = app.bonjour.servers.count
                        groupRow("Bonjour", symbol: "bonjour",
                                 detail: count == 0 ? String(localized: "Procurando…") : count == 1 ? String(localized: "1 servidor") : String(localized: "\(count) servidores")) {
                            slot.serversPage = .bonjour
                        }
                    }
                    let candidates = app.cyberduckCandidates.count
                    if candidates > 0 {
                        groupRow(String(localized: "Do Cyberduck"), symbol: "tray.and.arrow.down",
                                 detail: candidates == 1 ? String(localized: "1 servidor") : String(localized: "\(candidates) servidores")) {
                            slot.serversPage = .cyberduck
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let bookmark = filtered.first(where: { ids.contains($0.id) }) {
                menu(for: bookmark)
            } else {
                Button("Novo Servidor…", action: newServer)
                Button("Novo Grupo…") { groupName = ""; creatingGroup = true }
            }
        } primaryAction: { ids in
            if let bookmark = filtered.first(where: { ids.contains($0.id) }) { connect(bookmark) }
        }
        .onChange(of: slot.selectedServer) { if slot.selectedServer != nil { window.active = window.side(of: slot) } }
        .overlay {
            if filtered.isEmpty && !window.search.isEmpty {
                ContentUnavailableView.search(text: window.search)
            } else if filtered.isEmpty && slot.serversPage != .all {
                emptyState
            }
        }
    }

    private var pageHeader: some View {
        HStack {
            Button {
                slot.serversPage = .all
            } label: {
                Label(pageTitle, systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .font(.headline)
            .tint(.primary)
            .help("Voltar aos Servidores")
            Spacer()
            if slot.serversPage == .history && !app.history.isEmpty {
                Button("Limpar Histórico") { app.clearHistory() }.buttonStyle(.link)
            }
            if slot.serversPage == .cyberduck && !app.cyberduckCandidates.isEmpty {
                Button("Importar Todos") { app.importFromCyberduck() }.buttonStyle(.link)
            }
        }
    }

    private var pageTitle: String {
        switch slot.serversPage {
        case .all: String(localized: "Servidores")
        case .history: String(localized: "Histórico")
        case .cyberduck: String(localized: "Do Cyberduck")
        case .bonjour: "Bonjour"
        case .group(let name): name
        }
    }

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 10) {
            ServerIconView(bookmark, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.displayName).lineLimit(1)
                Text(detail(for: bookmark)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if app.mountedDisks.contains(bookmark.id) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .foregroundStyle(.secondary)
                    .help("Montado no Finder")
                    .accessibilityLabel("Montado no Finder")
            }
        }
        .padding(.vertical, 2)
        .tag(bookmark.id)
        .draggable(bookmark.id.uuidString)
    }

    /// Cartão da grade, com a seleção do Finder no modo ícones: fundo no ícone e nome destacado.
    private func tile(_ bookmark: Bookmark) -> some View {
        let selected = slot.selectedServer == bookmark.id
        return VStack(spacing: 4) {
            ServerIconView(bookmark, size: 52)
                .padding(6)
                .background(selected ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12, style: .continuous))
            Text(bookmark.displayName)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
            Text(detail(for: bookmark)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture(count: 2) { connect(bookmark) }
        .onTapGesture { slot.selectedServer = bookmark.id }
        .draggable(bookmark.id.uuidString)
        .contextMenu { menu(for: bookmark) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func detail(for bookmark: Bookmark) -> String {
        if slot.serversPage == .history, let entry = app.history.first(where: { $0.bookmark.id == bookmark.id }) {
            return entry.date.formatted(.relative(presentation: .named))
        }
        return bookmark.connectionProtocol == .s3 && bookmark.hostname.isEmpty ? "Amazon S3" : bookmark.hostname
    }

    private func groupRow(_ title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 7, style: .continuous))
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            if let emptyText { Text(emptyText) }
        } actions: {
            if slot.serversPage == .all {
                Button("Adicionar Servidor", action: newServer)
            }
        }
        // Na lista, a linha tem recuo à esquerda: sem isso o aviso fica fora do centro.
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptySymbol: String {
        switch slot.serversPage {
        case .history: "clock"
        case .bonjour: "bonjour"
        case .cyberduck: "tray"
        case .group: "folder"
        case .all: "server.rack"
        }
    }

    private var emptyTitle: String {
        switch slot.serversPage {
        case .all: String(localized: "Nenhum servidor salvo")
        case .history: String(localized: "Nenhuma Conexão Recente")
        case .cyberduck: String(localized: "Nada para Importar")
        case .bonjour: String(localized: "Procurando Servidores")
        case .group: String(localized: "Grupo Vazio")
        }
    }

    private var emptyText: String? {
        switch slot.serversPage {
        case .all: String(localized: "Salve um servidor para acessá-lo com um clique, ou use o Quick Connect para conectar sem salvar.")
        case .history: nil
        case .cyberduck: String(localized: "Nenhum favorito novo do Cyberduck neste Mac.")
        case .bonjour: String(localized: "SFTP, FTP, WebDAV e SMB anunciados na rede local aparecem aqui sozinhos.")
        case .group: String(localized: "Arraste servidores para cá ou crie um com o botão +.")
        }
    }

    @ViewBuilder
    private func menu(for bookmark: Bookmark) -> some View {
        Button("Conectar") { connect(bookmark) }
        Button("Conectar no Outro Lado") {
            let other = window.slot(window.other(window.side(of: slot)))
            Task { await window.connect(bookmark, in: other, app: app) }
        }
        Divider()
        if app.bookmark(id: bookmark.id) != nil {
            Button("Editar…") { edit(bookmark) }
            Menu("Mover para Grupo") {
                Button("Nenhum") { app.move(bookmark.id, toGroup: nil) }.disabled(bookmark.group == nil)
                Divider()
                ForEach(app.groups, id: \.self) { group in
                    Button(group) { app.move(bookmark.id, toGroup: group) }.disabled(bookmark.group == group)
                }
            }
            Button("Duplicar") {
                var copy = bookmark
                copy.id = UUID()
                copy.nickname = bookmark.displayName + String(localized: " (cópia)")
                app.save(copy)
            }
        } else {
            Button("Adicionar aos Servidores") { app.save(bookmark) }
        }
        if app.bookmark(id: bookmark.id) != nil {
            Divider()
            Button(app.mountedDisks.contains(bookmark.id) ? "Desmontar do Finder" : "Montar no Finder") {
                Task { await app.toggleDisk(bookmark) }
            }
            if app.mountedDisks.contains(bookmark.id) {
                Button("Mostrar no Finder") { Task { await Disk.reveal(bookmark) } }
            }
            Button("Salvar como Droplet…") { Droplets.save(bookmark) }
        }
        if let url = bookmark.url {
            Divider()
            Button("Copiar Endereço") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        if app.bookmark(id: bookmark.id) != nil {
            Divider()
            Button("Apagar", role: .destructive) { app.remove(bookmark) }
        }
    }

    // MARK: Barra inferior: + | importar | editar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            BarButton(title: String(localized: "Novo servidor"), symbol: "plus", action: newServer)
            BarButton(title: String(localized: "Novo grupo"), symbol: "folder.badge.plus") { groupName = ""; creatingGroup = true }
            BarButton(title: String(localized: "Editar servidor"), symbol: "pencil") {
                if let id = slot.selectedServer, let bookmark = app.bookmark(id: id) { edit(bookmark) }
            }
            .disabled(slot.selectedServer.flatMap(app.bookmark(id:)) == nil)
            Spacer()
            ImportMenu()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    /// Aviso flutuante enquanto conecta: vidro sobre o conteúdo, como os HUDs do sistema.
    private func connectingOverlay(_ bookmark: Bookmark) -> some View {
        VStack(spacing: 12) {
            ServerIconView(bookmark, size: 48)
            ProgressView().controlSize(.small)
            Text("Conectando a “\(bookmark.displayName)”…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    // MARK: Ações

    private func connect(_ bookmark: Bookmark) {
        Task { await window.connect(bookmark, in: slot, app: app) }
    }

    private func newServer() {
        var bookmark = Bookmark(nickname: "", connectionProtocol: .sftp)
        if case .group(let name) = slot.serversPage { bookmark.group = name }
        bookmark.icon = .default(for: .sftp)
        slot.editing = ServerDraft(bookmark: bookmark, isNew: true)
    }

    private func edit(_ bookmark: Bookmark) {
        slot.editing = ServerDraft(bookmark: bookmark, password: Keychain.password(for: bookmark) ?? "", isNew: false)
    }
}

/// Menu de importar/exportar da barra de servidores (o mesmo do menu Arquivo).
struct ImportMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            ImportMenuItems(app: app)
        } label: {
            Label("Importar e exportar servidores", systemImage: "square.and.arrow.down.on.square")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .tint(.secondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Importar e exportar servidores")
    }
}

struct ImportMenuItems: View {
    var app: AppModel

    var body: some View {
        Section("Importar") {
            ForEach(ServerImporter.allCases) { source in
                Button(source.isAvailable && source.defaultLocation != nil ? "Do \(source.title)" : "Do \(source.title)…") {
                    app.importServers(from: source)
                }
            }
        }
        Divider()
        Button("Exportar Servidores…") { app.exportServers() }
        Button("Restaurar de Backup…") { app.restoreServers() }
    }
}

// MARK: - Senha

/// Pedido de senha no próprio painel, no desenho dos diálogos de autenticação do macOS.
struct PasswordPrompt: View {
    @Environment(AppModel.self) private var app
    @State var request: PasswordRequest
    var slot: PaneSlot
    var window: WindowModel

    var body: some View {
        VStack(spacing: 16) {
            ServerIconView(request.bookmark, size: 64)
            VStack(spacing: 6) {
                Text("Conectar a “\(request.bookmark.displayName)”").font(.headline)
                Text(request.bookmark.username.isEmpty
                     ? "Digite usuário e senha para “\(request.bookmark.displayName)”."
                     : "Digite a senha de “\(request.bookmark.username)” em “\(request.bookmark.displayName)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if request.failed {
                    Label("Senha incorreta. Tente de novo.", systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            VStack(spacing: 8) {
                if request.bookmark.username.isEmpty {
                    TextField("Usuário", text: $request.bookmark.username)
                        .textContentType(.username)
                }
                SecureField(request.bookmark.connectionProtocol == .s3 ? "Secret Access Key" : "Senha", text: $request.password)
                    .textContentType(.password)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            Toggle("Lembrar no Chaves", isOn: $request.remember)
                .disabled(app.bookmark(id: request.bookmark.id) == nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancelar") { slot.passwordRequest = nil }.keyboardShortcut(.cancelAction)
                Button("Conectar", action: submit).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: 300)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        slot.passwordRequest = request
        window.submitPassword(in: slot, app: app)
    }
}
