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

    // MARK: Cabeçalho: 🌐 | Servidores ⚡ Quick Connect | grade

    private var header: some View {
        ZStack {
            HStack(spacing: 0) {
                UnderlineTab(title: String(localized: "Servidores"), symbol: "globe", selected: slot.serversTab == .servers && slot.editing == nil) {
                    slot.editing = nil
                    slot.passwordRequest = nil
                    slot.serversTab = .servers
                }
                UnderlineTab(title: String(localized: "Quick Connect"), symbol: "bolt.fill", selected: slot.serversTab == .quickConnect && slot.editing == nil) {
                    slot.editing = nil
                    slot.passwordRequest = nil
                    slot.serversTab = .quickConnect
                }
            }
            HStack {
                LocationMenu(window: window, slot: slot)
                Spacer()
                BarButton(title: slot.serversAsGrid ? String(localized: "Ver como lista") : String(localized: "Ver como grade"),
                          symbol: slot.serversAsGrid ? "list.bullet" : "square.grid.2x2") { slot.serversAsGrid.toggle() }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 30)
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

    @ViewBuilder
    private var serverList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if slot.serversPage != .all { pageHeader }
                if slot.serversAsGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 14) {
                        ForEach(filtered) { bookmark in tile(bookmark) }
                    }
                    .padding(16)
                } else {
                    ForEach(filtered) { bookmark in row(bookmark) }
                }
                if filtered.isEmpty { emptyState }
                if slot.serversPage == .all && window.search.isEmpty {
                    Divider().padding(.horizontal, 24).padding(.vertical, 8)
                    ForEach(app.groups, id: \.self) { group in
                        let count = app.bookmarks.filter { $0.group == group }.count
                        groupRow(group, symbol: "folder.fill", detail: count == 1 ? String(localized: "1 servidor") : String(localized: "\(count) servidores")) {
                            slot.serversPage = .group(group)
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            ids.compactMap(UUID.init(uuidString:)).forEach { app.move($0, toGroup: group) }
                            return true
                        }
                        .contextMenu {
                            Button("Renomear Grupo…") { renamingGroup = group; groupName = group }
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
            .padding(.vertical, 10)
        }
        .scrollContentBackground(.hidden)
    }

    private var pageHeader: some View {
        HStack {
            Button {
                slot.serversPage = .all
            } label: {
                Label(pageTitle, systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            Spacer()
            if slot.serversPage == .history && !app.history.isEmpty {
                Button("Limpar Histórico") { app.clearHistory() }.buttonStyle(.link).font(.system(size: 12))
            }
            if slot.serversPage == .cyberduck && !app.cyberduckCandidates.isEmpty {
                Button("Importar Todos") { app.importFromCyberduck() }.buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
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
        let selected = slot.selectedServer == bookmark.id
        return HStack(spacing: 10) {
            ServerIconView(bookmark, size: 28)
            Text(bookmark.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if app.mountedDisks.contains(bookmark.id) {
                Image(systemName: "externaldrive.fill.badge.checkmark").foregroundStyle(.secondary).help("Montado no Finder")
            }
            Spacer(minLength: 12)
            Text(detail(for: bookmark)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.wormlink.opacity(0.22) : .clear, in: .rect(cornerRadius: 7))
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture(count: 2) { connect(bookmark) }
        .onTapGesture { slot.selectedServer = bookmark.id; window.active = window.side(of: slot) }
        .draggable(bookmark.id.uuidString)
        .contextMenu { menu(for: bookmark) }
    }

    private func tile(_ bookmark: Bookmark) -> some View {
        let selected = slot.selectedServer == bookmark.id
        return VStack(spacing: 6) {
            ServerIconView(bookmark, size: 56)
            Text(bookmark.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(bookmark.hostname).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .glassEffect(selected ? .regular.tint(Color.wormlink.opacity(0.35)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .onTapGesture(count: 2) { connect(bookmark) }
        .onTapGesture { slot.selectedServer = bookmark.id }
        .contextMenu { menu(for: bookmark) }
    }

    private func detail(for bookmark: Bookmark) -> String {
        if slot.serversPage == .history, let entry = app.history.first(where: { $0.bookmark.id == bookmark.id }) {
            return entry.date.formatted(.relative(presentation: .named))
        }
        return bookmark.connectionProtocol == .s3 && bookmark.hostname.isEmpty ? "Amazon S3" : bookmark.hostname
    }

    private func groupRow(_ title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: .rect(cornerRadius: 7))
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onTapGesture(perform: action)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: slot.serversPage == .history ? "clock" : slot.serversPage == .bonjour ? "bonjour" : "server.rack").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(emptyText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if slot.serversPage == .all && window.search.isEmpty {
                Button("Adicionar Servidor") { newServer() }.buttonStyle(.glassProminent).tint(.wormlink)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyText: String {
        if !window.search.isEmpty { return String(localized: "Nenhum servidor encontrado.") }
        switch slot.serversPage {
        case .all: return String(localized: "Nenhum servidor ainda.\nAdicione um ou use o Quick Connect.")
        case .history: return String(localized: "Nenhuma conexão recente.")
        case .cyberduck: return String(localized: "Nenhum favorito novo do Cyberduck neste Mac.")
        case .bonjour: return String(localized: "Nenhum servidor anunciado na rede local.\nSFTP, FTP, WebDAV e SMB aparecem aqui sozinhos.")
        case .group: return String(localized: "Grupo vazio. Arraste servidores para cá\nou crie um com o botão +.")
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
            Button(app.mountedDisks.contains(bookmark.id) ? "Desmontar do Finder" : "Montar no Finder") {
                Task { await app.toggleDisk(bookmark) }
            }
            if app.mountedDisks.contains(bookmark.id) {
                Button("Mostrar no Finder") { Task { await Disk.reveal(bookmark) } }
            }
            Button("Salvar como Droplet…") { Droplets.save(bookmark) }
        }
        if let url = bookmark.url {
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
        HStack(spacing: 4) {
            BarButton(title: String(localized: "Novo servidor"), symbol: "plus", action: newServer)
            BarButton(title: String(localized: "Novo grupo"), symbol: "folder.badge.plus") { groupName = ""; creatingGroup = true }
            BarButton(title: String(localized: "Editar servidor"), symbol: "pencil") {
                if let id = slot.selectedServer, let bookmark = app.bookmark(id: id) { edit(bookmark) }
            }
            .disabled(slot.selectedServer.flatMap(app.bookmark(id:)) == nil)
            Spacer()
            ImportMenu()
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private func connectingOverlay(_ bookmark: Bookmark) -> some View {
        VStack(spacing: 12) {
            ServerIconView(bookmark, size: 48)
            ProgressView().controlSize(.small)
            Text("Conectando a “\(bookmark.displayName)”…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
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
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 14))
        }
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

struct PasswordPrompt: View {
    @Environment(AppModel.self) private var app
    @State var request: PasswordRequest
    var slot: PaneSlot
    var window: WindowModel

    var body: some View {
        VStack(spacing: 14) {
            ServerIconView(request.bookmark, size: 56)
            Text(request.bookmark.username.isEmpty
                 ? "Digite usuário e senha para “\(request.bookmark.displayName)”."
                 : "Digite a senha de “\(request.bookmark.username)” em “\(request.bookmark.displayName)”.")
                .font(.callout)
                .multilineTextAlignment(.center)
            if request.failed {
                Text("Senha incorreta. Tente de novo.").font(.caption).foregroundStyle(.red)
            }
            if request.bookmark.username.isEmpty {
                TextField("Usuário", text: $request.bookmark.username).textFieldStyle(.roundedBorder)
            }
            SecureField(request.bookmark.connectionProtocol == .s3 ? "Secret Access Key" : "Senha", text: $request.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Toggle("Lembrar no Chaves", isOn: $request.remember)
                .disabled(app.bookmark(id: request.bookmark.id) == nil)
            HStack {
                Button("Cancelar") { slot.passwordRequest = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Conectar", action: submit).keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).tint(.wormlink)
            }
        }
        .frame(maxWidth: 320)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        slot.passwordRequest = request
        window.submitPassword(in: slot, app: app)
    }
}
