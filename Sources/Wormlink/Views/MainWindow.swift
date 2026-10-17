import CoreSpotlight
import SwiftUI
import WormlinkCore

/// Janela (ou aba) do Wormlink: dois lados lado a lado, como no Transmit.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var model = WindowModel()
    @State private var showTransfers = false

    var body: some View {
        HSplitView {
            if !model.singlePane || model.active == .left {
                side(model.left).frame(minWidth: 260, maxWidth: .infinity)
            }
            if !model.singlePane || model.active == .right {
                side(model.right).frame(minWidth: 260, maxWidth: .infinity)
            }
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(window: model).inspectorColumnWidth(min: 240, ideal: 270, max: 340)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showSync) { SyncSheet(window: model).environment(app) }
        .sheet(isPresented: Binding(get: { model.installKeyOn != nil }, set: { if !$0 { model.installKeyOn = nil } })) {
            if let fs = model.installKeyOn { InstallKeySheet(fs: fs) }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .searchable(text: $model.search, placement: .toolbar, prompt: model.activeFiles == nil ? "Buscar servidores" : "Filtrar")
        .onChange(of: model.search) {
            for slot in [model.left, model.right] { slot.files?.filter = slot.showingServers ? "" : model.search }
        }
        .focusedSceneValue(\.windowModel, model)
        .background(WindowAccessor { window in
            TabOpener.attach(window)
            model.disconnectOnClose(window)
        })
        .task {
            await app.refreshDisks()
            app.startBonjourIfEnabled()
            await model.left.files?.reload()
            #if DEBUG
            // Só em depuração: WORMLINK_PREVIEW=editor|quick|password abre essa tela, para capturas.
            switch ProcessInfo.processInfo.environment["WORMLINK_PREVIEW"] {
            case "editor": model.right.editing = app.bookmarks.first.map { ServerDraft(bookmark: $0, isNew: false) }
            case "quick": model.right.serversTab = .quickConnect
            case "password": model.right.passwordRequest = app.bookmarks.dropFirst().first.map { PasswordRequest(bookmark: $0) }
            case "search":
                let root = ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_PATH"] ?? NSTemporaryDirectory()
                await model.left.files?.go(to: root)
                model.left.files?.filter = "*.txt"
                model.left.files?.startSearch("*.txt")
            case "settings":
                UserDefaults.standard.set(ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_TAB"] ?? "transfers", forKey: "settingsTab")
                if let folder = ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_SSH"] { SSHKeyManager.folder = URL(filePath: folder) }
                openSettings()
            case "bonjour": model.right.serversPage = .bonjour
            case "history": model.right.serversPage = .history
            case "grid": model.right.serversAsGrid = true
            case "local", "sync", "inspectorLocal":
                // Os dois lados no Mac (pastas de WORMLINK_PREVIEW_PATH e WORMLINK_PREVIEW_PATH2).
                let env = ProcessInfo.processInfo.environment
                await model.showLocal(model.right)
                if let root = env["WORMLINK_PREVIEW_PATH"] { await model.left.files?.go(to: root) }
                if let root = env["WORMLINK_PREVIEW_PATH2"] { await model.right.files?.go(to: root) }
                if let name = env["WORMLINK_PREVIEW_SELECT"], let files = model.left.files,
                   let item = files.items.first(where: { $0.name == name }) { files.selection = [item.id] }
                model.active = .left
                if env["WORMLINK_PREVIEW"] == "sync" { model.showSync = true }
                if env["WORMLINK_PREVIEW"] == "inspectorLocal" { model.showInspector = true }
            case "transfersEmpty": openWindow(id: "transfers")
            case "vault":
                let env = ProcessInfo.processInfo.environment
                guard let files = model.left.files, let root = env["WORMLINK_PREVIEW_PATH"] else { break }
                await files.go(to: root)
                if let secret = env["WORMLINK_PREVIEW_SECRET"] { try? await files.unlockVault(password: secret) }
                if let sub = env["WORMLINK_PREVIEW_SELECT"] { await files.go(to: RemotePath.join(root, sub)) }
            case "columns", "gallery", "single", "icons":
                let env = ProcessInfo.processInfo.environment
                guard let files = model.left.files else { break }
                if let root = env["WORMLINK_PREVIEW_PATH"] { await files.go(to: root) }
                if let name = env["WORMLINK_PREVIEW_SELECT"], let item = files.items.first(where: { $0.name == name }) { files.selection = [item.id] }
                let mode = env["WORMLINK_PREVIEW"]!
                files.layout = mode == "gallery" ? .gallery : mode == "icons" ? .icons : .columns
                if mode == "single" { model.singlePane = true }
            case "inspector":
                // Conecta o primeiro servidor à direita, abre a pasta, seleciona um item e mostra o Obter Informações.
                let env = ProcessInfo.processInfo.environment
                guard let bookmark = app.bookmarks.first else { break }
                await model.connect(bookmark, in: model.right, password: env["WORMLINK_PREVIEW_SECRET"], app: app)
                guard let files = model.right.files else { break }
                if let root = env["WORMLINK_PREVIEW_PATH"] { await files.go(to: root) }
                if let name = env["WORMLINK_PREVIEW_SELECT"], let item = files.items.first(where: { $0.name == name }) { files.selection = [item.id] }
                model.active = .right
                model.showInspector = true
            case "script":
                // Roda um AppleScript pelo próprio app (sem pedir permissão de Automação) e grava a saída.
                let env = ProcessInfo.processInfo.environment
                guard let source = env["WORMLINK_SCRIPT"], let out = env["WORMLINK_SCRIPT_OUT"] else { break }
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try? process.run()
                Task.detached {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    try? data.write(to: URL(filePath: out))
                }
            case "transfers":
                let root = ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_PATH"] ?? NSTemporaryDirectory()
                BandwidthLimiter.shared.setLimit(1_000_000, for: .upload)
                let local = LocalFileSystem()
                let items = ((try? await local.list(root + "/origem")) ?? [])
                guard let bookmark = app.bookmarks.first,
                      let remote = try? await Connector.connect(bookmark, password: nil, trust: TrustPrompter.trust) else { break }
                app.transfers.enqueue(items, from: local, to: remote, into: remote.homePath) {}
                openWindow(id: "transfers")
                try? await Task.sleep(for: .seconds(3))
                app.transfers.transfers.first?.pause()
                app.transfers.enqueue(Array(items.prefix(1)), from: local, to: remote, into: remote.homePath) {}
            default: break
            }
            #endif
        }
        .userActivity(Handoff.browsing, isActive: model.activeFiles?.bookmark != nil) { activity in
            Handoff.update(activity, bookmark: model.activeFiles?.bookmark, path: model.activeFiles?.path)
        }
        .onContinueUserActivity(Handoff.browsing) { activity in
            continueBrowsing(activity.userInfo?["bookmark"] as? String, path: activity.userInfo?["path"] as? String)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            continueBrowsing(activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, path: nil)
        }
        .onOpenURL { url in
            guard url.scheme == "wormlink" else { return }
            switch url.host() {
            case "bookmark":
                // wormlink://bookmark/<id> abre um servidor salvo no lado direito.
                guard let id = UUID(uuidString: url.lastPathComponent), let bookmark = app.bookmark(id: id) else { return }
                Task { await model.connect(bookmark, in: model.right, app: app) }
            case "mount":
                // wormlink://mount/<id> monta (ou desmonta) o servidor no Finder.
                guard let id = UUID(uuidString: url.lastPathComponent), let bookmark = app.bookmark(id: id) else { return }
                Task { await app.toggleDisk(bookmark) }
            case "upload":
                // Droplets e Atalhos: envia arquivos para um servidor sem mexer nos painéis.
                openWindow(id: "transfers")
                Task {
                    do { try await app.handleUploadURL(url) } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            default: break
            }
        }
    }

    /// Handoff e Spotlight: abre o servidor (e a pasta) no lado direito.
    private func continueBrowsing(_ id: String?, path: String?) {
        guard let id = id.flatMap(UUID.init(uuidString:)), var bookmark = app.bookmark(id: id) else { return }
        if let path { bookmark.path = path }
        Task { await model.connect(bookmark, in: model.right, app: app) }
    }

    @ViewBuilder
    private func side(_ slot: PaneSlot) -> some View {
        Group {
            if let files = slot.visibleFiles {
                FilesPane(window: model, slot: slot, pane: files)
            } else {
                ServersPane(window: model, slot: slot)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { model.active = model.side(of: slot) })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Voltar/Avançar do lado ativo, como no Finder.
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button {
                    Task { await model.activeFiles?.goBack() }
                } label: {
                    Label("Voltar", systemImage: "chevron.left")
                }
                .help("Voltar")
                .disabled(!(model.activeFiles?.canGoBack ?? false))
                Button {
                    Task { await model.activeFiles?.goForward() }
                } label: {
                    Label("Avançar", systemImage: "chevron.right")
                }
                .help("Avançar")
                .disabled(!(model.activeFiles?.canGoForward ?? false))
            }
            .controlGroupStyle(.navigation)
        }

        ToolbarItemGroup {
            Button {
                withAnimation(.snappy) { model.singlePane.toggle() }
            } label: {
                Label(model.singlePane ? "Dois Painéis" : "Um Painel",
                      systemImage: model.singlePane ? "rectangle.split.2x1" : "rectangle")
            }
            .help(model.singlePane ? "Mostrar os dois lados" : "Mostrar só o lado ativo")
            if model.singlePane {
                Button {
                    withAnimation(.snappy) { model.active = model.active == .left ? .right : .left }
                } label: {
                    Label("Trocar de Lado", systemImage: "arrow.left.arrow.right")
                }
                .help("Mostrar o outro lado")
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Toggle(isOn: Binding(get: { model.linking }, set: { _ in model.toggleLinking() })) {
                Label("Folder Linking", systemImage: "link")
            }
            .help("Ligar a navegação dos dois lados (Folder Linking)")
            .disabled(model.left.visibleFiles == nil || model.right.visibleFiles == nil)

            Button {
                model.showSync = true
            } label: {
                Label("Sincronizar", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Sincronizar as pastas abertas nos dois lados")
            .disabled(model.left.visibleFiles == nil || model.right.visibleFiles == nil)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Button {
                showTransfers.toggle()
            } label: {
                Label {
                    Text("Transferências")
                } icon: {
                    // Em andamento: o próprio botão vira o progresso geral (como o Safari com downloads).
                    if app.transfers.activeCount > 0 {
                        ProgressView(value: app.transfers.overallFraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .help(app.transfers.activeCount > 0 ? "\(app.transfers.activeCount) transferência(s) em andamento" : "Transferências")
            .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                TransfersView().environment(app).frame(width: 440, height: 320)
            }
        }

        ToolbarItem {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("Informações", systemImage: "info.circle")
            }
            .help("Mostrar ou ocultar o inspetor")
        }
    }
}

extension FocusedValues {
    @Entry var windowModel: WindowModel?
}

/// Abas nativas: "Nova Aba" junta a próxima janela à janela da frente.
enum TabOpener {
    static weak var parent: NSWindow?

    static func attach(_ window: NSWindow) {
        guard let parent, parent !== window else { return }
        self.parent = nil
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}
