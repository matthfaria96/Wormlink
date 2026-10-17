import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WormlinkCore

/// Um lado da janela mostrando arquivos: Places, cabeçalho com o caminho e a lista.
struct FilesPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var window: WindowModel
    var slot: PaneSlot
    @Bindable var pane: PaneModel
    @State private var renaming: FileItem?
    @State private var newName = ""
    @State private var creating: CreateKind?
    @State private var previewURL: URL?
    @State private var isDropTarget = false
    @State private var showCommand = false

    enum CreateKind { case folder, file }

    private var isActive: Bool { window.slot(window.active) === slot }

    var body: some View {
        VStack(spacing: 0) {
            PlacesBar(window: window, slot: slot, pane: pane)
            Divider()
            header
            Divider()
            if !pane.filter.isEmpty || pane.searchResults != nil { searchBar; Divider() }
            if pane.lockedVault != nil || pane.vault(at: pane.path) != nil { VaultBar(pane: pane); Divider() }
            Group {
                switch pane.layout {
                case .list: list
                case .icons: icons
                case .columns:
                    ColumnBrowser(pane: pane, open: { item in Task { await primaryAction(item) } }, menu: menu,
                                  activate: { window.active = window.side(of: slot) })
                case .gallery:
                    GalleryBrowser(pane: pane, open: { item in Task { await primaryAction(item) } }, menu: menu,
                                   activate: { window.active = window.side(of: slot) })
                }
            }
            .overlay { overlay }
        }
        .background { if isDropTarget { Color.wormlink.opacity(0.08) } }
        .dropDestination(for: URL.self) { urls, _ in dropFromFinder(urls) } isTargeted: { isDropTarget = $0 }
        .quickLookPreview($previewURL)
        .alert("Renomear “\(renaming?.name ?? "")”", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") { if let item = renaming { Task { await pane.rename(item, to: newName) } } }
            Button("Cancelar", role: .cancel) {}
        }
        .alert(creating == .folder ? "Nova Pasta" : "Novo Arquivo",
               isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Nome", text: $newName)
            Button("Criar") {
                let kind = creating, name = newName
                Task { kind == .folder ? await pane.createFolder(named: name) : await pane.createFile(named: name) }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Não foi possível concluir", isPresented: Binding(get: { pane.operationError != nil },
                                                                  set: { if !$0 { pane.operationError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(pane.operationError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .wormlinkCreate)) { note in
            guard isActive else { return }
            newName = note.object as? String == "file" ? String(localized: "sem título.txt") : String(localized: "sem título")
            creating = note.object as? String == "file" ? .file : .folder
        }
        .onReceive(NotificationCenter.default.publisher(for: .wormlinkNewVault)) { _ in
            if isActive { Task { await VaultPrompts.create(in: pane) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wormlinkCommand)) { note in
            if note.object as? UUID == pane.id { showCommand = true }
        }
        .sheet(isPresented: $showCommand) { CommandSheet(pane: pane) }
        .onReceive(NotificationCenter.default.publisher(for: .wormlinkRename)) { _ in
            guard isActive, let item = pane.selectedItems.first else { return }
            newName = item.name
            renaming = item
        }
    }

    // MARK: Cabeçalho: local | caminho ⌄ ……… modo de exibição

    private var header: some View {
        HStack(spacing: 8) {
            LocationMenu(window: window, slot: slot)
            Divider().frame(height: 14)
            Menu {
                ForEach(RemotePath.components(pane.path).reversed(), id: \.self) { p in
                    Button {
                        Task { await pane.go(to: p) }
                    } label: {
                        Label(p == "/" ? "/" : RemotePath.name(p), systemImage: p == "/" ? "internaldrive" : "folder")
                    }
                }
            } label: {
                Text(pane.path == "/" ? pane.title : RemotePath.name(pane.path)).font(.headline)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .tint(.primary)
            .fixedSize()
            .help("Pastas acima desta")
            if pane.isLoading { ProgressView().controlSize(.mini) }
            Spacer()
            Picker("Exibição", selection: $pane.layout) {
                ForEach(PaneModel.Layout.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.menu)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .labelsHidden()
            .tint(.secondary)
            .fixedSize()
            .help("Ver como lista, ícones, colunas ou galeria")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color.accentColor.opacity(0.07) : .clear)
    }

    // MARK: Busca (barra de escopo, como a do Finder)

    private var searchScope: Binding<Bool> {
        Binding(get: { pane.searchResults != nil }, set: { subfolders in
            if subfolders { pane.startSearch(pane.filter) } else { pane.clearSearch() }
        })
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Text("Buscar:").foregroundStyle(.secondary)
            Toggle("Esta Pasta", isOn: Binding(get: { !searchScope.wrappedValue }, set: { if $0 { searchScope.wrappedValue = false } }))
            Toggle("Subpastas", isOn: Binding(get: { searchScope.wrappedValue }, set: { if $0 { searchScope.wrappedValue = true } }))
                .disabled(pane.filter.isEmpty && pane.searchResults == nil)
            Spacer()
            if pane.isSearching {
                ProgressView().controlSize(.mini)
                Text("Buscando em \(RemotePath.name(pane.searchFolder ?? pane.path))…").foregroundStyle(.secondary).lineLimit(1)
                Button("Parar") { pane.stopSearch() }
            } else if let results = pane.searchResults {
                Text(results.count == 1 ? String(localized: "1 resultado") : String(localized: "\(results.count) resultados"))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    // MARK: Lista com subpastas expansíveis

    private var list: some View {
        Table(of: PaneModel.Row.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Nome", value: \.item.name, comparator: .localizedStandard) { row in
                HStack(spacing: 4) {
                    Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
                    if row.item.isDirectory {
                        Button {
                            Task { await pane.toggle(row.item) }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(pane.expanded.contains(row.item.path) ? 90 : 0))
                                .frame(width: 14, height: 14)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(pane.expanded.contains(row.item.path) ? "Recolher" : "Expandir")
                    } else {
                        Color.clear.frame(width: 14, height: 14)
                    }
                    Image(nsImage: FileIcons.icon(for: row.item))
                    Text(row.item.name)
                        .foregroundStyle(row.item.isHidden ? .secondary : .primary)
                        .lineLimit(1)
                    if pane.searchResults != nil {
                        // Na busca, onde o item está (relativo à pasta aberta).
                        Text(RemotePath.parent(row.item.path).replacingOccurrences(of: pane.path, with: "").ifEmpty("/"))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                .draggable(PaneDrag(pane: pane.id, paths: dragPaths(for: row.item)))
            }
            .width(min: 120, ideal: 240)
            TableColumn("Tamanho", value: \.item.sortSize) { row in
                Text(row.item.size.map { $0.formatted(.byteCount(style: .file)) } ?? "--")
                    .foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 64, max: 96)
            TableColumn("Data", value: \.item.sortDate) { row in
                Text(row.item.modified?.shortStamp ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 96, ideal: 112, max: 150)
        } rows: {
            ForEach(pane.rows) { TableRow($0) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            FileMenu(window: window, pane: pane, items: pane.rows.map(\.item).filter { ids.contains($0.id) },
                     rename: startRename, create: { newName = $0 == .folder ? String(localized: "sem título") : String(localized: "sem título.txt"); creating = $0 },
                     preview: preview)
        } primaryAction: { ids in
            if let item = pane.rows.map(\.item).first(where: { ids.contains($0.id) }) { Task { await primaryAction(item) } }
        }
        .dropDestination(for: PaneDrag.self) { drags, _ in dropFromPane(drags) }
        .onKeyPress(.space) {
            if let item = pane.selectedItems.first { preview(item) }
            return .handled
        }
        .onChange(of: pane.selection) { if !pane.selection.isEmpty { window.active = window.side(of: slot) } }
    }

    /// Menu de contexto compartilhado pelas visualizações em colunas e galeria.
    private func menu(_ items: [FileItem]) -> AnyView {
        AnyView(FileMenu(window: window, pane: pane, items: items, rename: startRename,
                         create: { newName = $0 == .folder ? String(localized: "sem título") : String(localized: "sem título.txt"); creating = $0 }, preview: preview))
    }

    // MARK: Ícones

    private var icons: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 12) {
                ForEach(pane.rows.filter { $0.depth == 0 }) { row in
                    let selected = pane.selection.contains(row.id)
                    // Seleção do Finder no modo ícones: fundo cinza no ícone, nome na cor de destaque.
                    VStack(spacing: 3) {
                        Image(nsImage: FileIcons.icon(for: row.item, size: 56))
                            .padding(4)
                            .background(selected ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6, style: .continuous))
                        Text(row.item.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .foregroundStyle(selected ? Color.white : row.item.isHidden ? Color.secondary : Color.primary)
                            .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
                    }
                    .frame(width: 96, height: 100, alignment: .top)
                    .contentShape(.rect)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .onTapGesture(count: 2) { Task { await primaryAction(row.item) } }
                    .onTapGesture {
                        pane.selection = [row.id]
                        window.active = window.side(of: slot)
                    }
                    .draggable(PaneDrag(pane: pane.id, paths: dragPaths(for: row.item)))
                    .contextMenu {
                        FileMenu(window: window, pane: pane, items: [row.item], rename: startRename,
                                 create: { newName = $0 == .folder ? String(localized: "sem título") : String(localized: "sem título.txt"); creating = $0 }, preview: preview)
                    }
                }
            }
            .padding(12)
        }
        .dropDestination(for: PaneDrag.self) { drags, _ in dropFromPane(drags) }
    }

    @ViewBuilder
    private var overlay: some View {
        if let error = pane.error {
            ContentUnavailableView {
                Label("Não foi possível abrir a pasta", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Tentar de Novo") { Task { await pane.reload() } }
            }
        } else if pane.isLoading && pane.items.isEmpty {
            ProgressView()
        } else if pane.rows.isEmpty && !pane.isLoading && !pane.isSearching {
            if pane.filter.isEmpty {
                ContentUnavailableView("Pasta Vazia", systemImage: "folder")
            } else {
                ContentUnavailableView.search(text: pane.filter)
            }
        }
    }

    // MARK: Ações

    private func startRename(_ item: FileItem) {
        newName = item.name
        renaming = item
    }

    /// Duplo clique: pasta abre; arquivo local abre no app padrão; arquivo remoto vai para o outro lado
    /// (se for o Mac) ou abre para edição.
    private func primaryAction(_ item: FileItem) async {
        if item.isDirectory { return await pane.go(to: item.path) }
        if pane.isLocal { NSWorkspace.shared.open(URL(filePath: item.path)); return }
        switch UserDefaults.standard.string(forKey: "doubleClickRemote") ?? "transfer" {
        case "edit":
            try? await app.editor.edit(item, from: pane.fs)
            return
        case "editInternal":
            if let id = app.openText(item, from: pane.fs) { openWindow(id: "text", value: id); return }
        default: break
        }
        if let other = window.slot(window.other(window.side(of: slot))).visibleFiles, other.isLocal {
            window.transfer([item], from: pane, to: other, into: other.path, using: app.transfers)
        } else {
            try? await app.editor.edit(item, from: pane.fs)
        }
    }

    private func preview(_ item: FileItem) {
        if pane.isLocal { previewURL = URL(filePath: item.path); return }
        guard !item.isDirectory else { return }
        Task {
            let folder = URL.cachesDirectory.appending(path: "Wormlink/QuickLook/\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let local = folder.appending(path: item.name)
            do {
                try await pane.fs.download(item.path, to: local) { _ in }
                previewURL = local
            } catch { pane.operationError = error.localizedDescription }
        }
    }

    private func dragPaths(for item: FileItem) -> [String] {
        pane.selection.contains(item.id) ? Array(pane.selection) : [item.path]
    }

    private func dropFromPane(_ drags: [PaneDrag]) -> Bool {
        guard let drag = drags.first, drag.pane != pane.id, let source = window.pane(with: drag.pane) else { return false }
        let items = source.rows.map(\.item).filter { drag.paths.contains($0.path) }
        window.transfer(items, from: source, to: pane, into: pane.path, using: app.transfers)
        return true
    }

    private func dropFromFinder(_ urls: [URL]) -> Bool {
        let items = urls.filter(\.isFileURL).map { url in
            FileItem(path: url.path, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false,
                     size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init))
        }
        guard !items.isEmpty else { return false }
        app.transfers.enqueue(items, from: LocalFileSystem(), to: pane.fs, into: pane.path) { [pane] in Task { await pane.reload() } }
        return true
    }
}

// MARK: - Barra de Places

/// Atalhos de pastas no topo do painel ("macmini", "Downloads", "Desktop"…). Solte pastas aqui para adicionar.
struct PlacesBar: View {
    @Environment(AppModel.self) private var app
    var window: WindowModel
    var slot: PaneSlot
    var pane: PaneModel
    @State private var isTargeted = false

    private var places: [String] {
        if pane.isLocalConnection { return app.localPlaces }
        let home = RemotePath.normalize(pane.base.homePath)
        return [home] + (pane.bookmark.flatMap { app.bookmark(id: $0.id)?.places } ?? []).filter { $0 != home }
    }

    var body: some View {
        // Barra de atalhos no estilo das barras de acessório do sistema (escopo do Finder, Favoritos do Safari).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(places, id: \.self) { place in
                    Toggle(isOn: Binding(get: { RemotePath.normalize(place) == pane.path },
                                         set: { _ in Task { await pane.go(to: place) } })) {
                        Label(placeName(place), systemImage: placeSymbol(place))
                    }
                    .help(place)
                    .contextMenu {
                        Button("Remover dos Places") { remove(place) }
                    }
                }
                if places.count <= 1 {
                    Text("Arraste pastas aqui para acesso rápido").font(.caption).foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.accessoryBar)
            .controlSize(.small)
            .padding(.horizontal, 8)
        }
        .frame(height: 28)
        .background(isTargeted ? Color.wormlink.opacity(0.15) : .clear)
        .dropDestination(for: PaneDrag.self) { drags, _ in
            let folders = drags.flatMap(\.paths).filter { p in window.pane(with: drags[0].pane)?.rows.contains { $0.item.path == p && $0.item.isDirectory } ?? false }
            guard drags.first?.pane == pane.id, !folders.isEmpty else { return false }
            folders.forEach(add)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func placeName(_ place: String) -> String {
        if pane.isLocalConnection && place == FileManager.default.homeDirectoryForCurrentUser.path { return NSUserName() }
        return place == "/" ? "/" : RemotePath.name(place)
    }

    private func placeSymbol(_ place: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard pane.isLocalConnection else { return place == RemotePath.normalize(pane.base.homePath) ? "house" : "folder" }
        switch place {
        case home: return "house"
        case home + "/Downloads": return "arrow.down.circle"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Pictures": return "photo"
        case home + "/Music": return "music.note"
        case home + "/Movies": return "film"
        case "/Applications": return "app.dashed"
        default: return "folder"
        }
    }

    private func add(_ place: String) {
        if pane.isLocalConnection {
            if !app.localPlaces.contains(place) { app.localPlaces.append(place) }
        } else if let id = pane.bookmark?.id, var bookmark = app.bookmark(id: id), !bookmark.places.contains(place) {
            bookmark.places.append(place)
            app.save(bookmark)
        }
    }

    private func remove(_ place: String) {
        if pane.isLocalConnection {
            app.localPlaces.removeAll { $0 == place }
        } else if let id = pane.bookmark?.id, var bookmark = app.bookmark(id: id) {
            bookmark.places.removeAll { $0 == place }
            app.save(bookmark)
        }
    }
}

// MARK: - Menu de local (Mac ↔ Servidores)

/// Ícone à esquerda do cabeçalho: troca o lado entre este Mac, os servidores e as conexões abertas.
struct LocationMenu: View {
    @Environment(AppModel.self) private var app
    var window: WindowModel
    var slot: PaneSlot

    var body: some View {
        Menu {
            Button {
                Task { await window.showLocal(slot) }
            } label: { Label(Host.current().localizedName ?? String(localized: "Este Mac"), systemImage: "desktopcomputer") }
            Button {
                slot.showingServers = true
            } label: { Label("Servidores", systemImage: "globe") }
            if let files = slot.files, !files.isLocalConnection {
                Divider()
                Button {
                    slot.showingServers = false
                } label: { Label(files.title, systemImage: files.bookmark?.icon.symbolName ?? "server.rack") }
                Button("Desconectar de “\(files.title)”") { Task { await window.disconnect(slot) } }
            }
        } label: {
            Label("Trocar o local deste lado", systemImage: symbol)
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize()
        .help("Trocar o local deste lado")
    }

    private var symbol: String {
        if slot.showingServers { return "globe" }
        guard let files = slot.files, !files.isLocalConnection else { return "internaldrive" }
        return files.bookmark?.icon.symbolName ?? "server.rack"
    }
}

// MARK: - Menu de contexto dos arquivos

struct FileMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var window: WindowModel
    var pane: PaneModel
    var items: [FileItem]
    var rename: (FileItem) -> Void
    var create: (FilesPane.CreateKind) -> Void
    var preview: (FileItem) -> Void

    var body: some View {
        if let first = items.first {
            if items.count == 1 {
                if first.isDirectory {
                    Button("Abrir") { Task { await pane.go(to: first.path) } }
                } else if pane.isLocal {
                    Button("Abrir") { NSWorkspace.shared.open(URL(filePath: first.path)) }
                } else {
                    Button("Editar no Wormlink") { openInternal(first) }
                    Button("Editar no App Padrão") { Task { await edit(first, with: nil) } }
                    Button("Editar com…") { chooseEditor(for: first) }
                }
                if !first.isDirectory { Button("Visualização Rápida") { preview(first) } }
            }
            if let other = window.otherFiles {
                Button(pane.isLocal ? "Enviar para “\(other.title)”" : (other.isLocal ? "Baixar" : "Copiar para “\(other.title)”")) {
                    window.transfer(items, from: pane, to: other, into: other.path, using: app.transfers)
                }
            }
            Divider()
            Button("Obter Informações") {
                pane.selection = Set(items.map(\.id))
                window.showInspector = true
            }
            if items.count == 1 { Button("Renomear…") { rename(first) } }
            Button("Duplicar") { Task { await pane.duplicate(items) } }
            if pane.canArchive {
                Menu("Comprimir") {
                    ForEach(Archiver.Format.allCases, id: \.self) { format in
                        Button(format.title) { Task { await pane.compress(items, as: format) } }
                    }
                }
                if items.count == 1, !first.isDirectory, Archiver.format(of: first.name) != nil {
                    Button("Descomprimir") { Task { await pane.expand(first) } }
                }
            }
            if let bookmark = pane.bookmark {
                Button(bookmark.webURL?.isEmpty == false ? "Copiar URL" : "Copiar Endereço") {
                    copy(items.compactMap { bookmark.publicURL(for: $0.path)?.absoluteString })
                }
            }
            if let s3 = pane.fs as? S3FileSystem, items.allSatisfy({ !$0.isDirectory }) {
                Menu("Copiar Link Temporário") {
                    ForEach([(String(localized: "Válido por 1 Hora"), 3600.0), (String(localized: "Válido por 1 Dia"), 86_400.0), (String(localized: "Válido por 7 Dias"), 604_800.0)], id: \.0) { title, seconds in
                        Button(title) {
                            Task {
                                var links: [String] = []
                                for item in items { if let url = try? await s3.presignedURL(item.path, expires: seconds) { links.append(url.absoluteString) } }
                                copy(links)
                            }
                        }
                    }
                }
            }
            if let sharing = pane.fs as? any SharesLinks, (pane.fs as? WebDAVFileSystem)?.canShareLinks ?? true {
                Button(items.count == 1 ? "Copiar Link Compartilhado" : "Copiar Links Compartilhados") {
                    Task {
                        do {
                            var links: [String] = []
                            for item in items { links.append(try await sharing.sharedLink(item.path).absoluteString) }
                            copy(links)
                        } catch {
                            pane.operationError = String(localized: "Não foi possível criar o link: \(error.localizedDescription)")
                        }
                    }
                }
            }
            Button("Copiar Caminho") { copy(items.map(\.path)) }
            if pane.isLocal {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(filePath: $0.path) }) }
            }
            if items.count == 1, first.isDirectory, pane.isLocal || pane.bookmark?.connectionProtocol == .sftp {
                Button("Abrir no Terminal") { Terminal.open(first.path, bookmark: pane.isLocal ? nil : pane.bookmark) }
            }
            Divider()
            Button(pane.isLocal ? "Mover para o Lixo" : "Apagar", role: .destructive) { confirmDelete() }
        } else {
            Button("Nova Pasta…") { create(.folder) }
            Button("Novo Arquivo…") { create(.file) }
            if pane.vault(at: pane.path) == nil {
                Button("Novo Cofre Criptografado…") { Task { await VaultPrompts.create(in: pane) } }
            }
            Divider()
            Button("Atualizar") { Task { await pane.reload() } }
            Toggle("Mostrar Arquivos Ocultos", isOn: Binding(get: { pane.showHidden }, set: { pane.showHidden = $0 }))
            if pane.fs.supportsCommands {
                Button(pane.fs is SFTPFileSystem ? "Enviar Comando SSH…" : "Enviar Comando FTP…") {
                    NotificationCenter.default.post(name: .wormlinkCommand, object: pane.id)
                }
            }
            if pane.isLocal || pane.bookmark?.connectionProtocol == .sftp {
                Button("Abrir no Terminal") { Terminal.open(pane.path, bookmark: pane.isLocal ? nil : pane.bookmark) }
            }
        }
    }

    private func openInternal(_ item: FileItem) {
        guard let id = app.openText(item, from: pane.fs) else {
            pane.operationError = String(localized: "“\(item.name)” é grande demais para o editor embutido (máximo 8 MB).")
            return
        }
        openWindow(id: "text", value: id)
    }

    private func edit(_ item: FileItem, with application: URL?) async {
        do { try await app.editor.edit(item, from: pane.fs, with: application) } catch { pane.operationError = error.localizedDescription }
    }

    private func chooseEditor(for item: FileItem) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Editar")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        Task { await edit(item, with: app) }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? String(localized: "Apagar “\(items[0].name)”?") : String(localized: "Apagar os \(items.count) itens selecionados?")
        alert.informativeText = pane.isLocal ? String(localized: "Os itens vão para o Lixo.") : String(localized: "Esta ação não pode ser desfeita.")
        alert.addButton(withTitle: pane.isLocal ? String(localized: "Mover para o Lixo") : String(localized: "Apagar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let targets = items
        Task { await pane.delete(targets) }
    }

    private func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// "Abrir no Terminal": pasta local ou sessão SSH já na pasta remota.
enum Terminal {
    static func open(_ path: String, bookmark: Bookmark?) {
        let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app")
        guard let bookmark else {
            NSWorkspace.shared.open([URL(filePath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let quoted = path.replacingOccurrences(of: "'", with: "'\\''")
        var command = "ssh"
        if bookmark.port != 22 { command += " -p \(bookmark.port)" }
        if let key = bookmark.keyFile, !key.isEmpty { command += " -i '\(key)'" }
        command += " -t \(bookmark.username.isEmpty ? "" : bookmark.username + "@")\(bookmark.hostname) \"cd '\(quoted)' && exec \\$SHELL -l\""
        let script = URL.temporaryDirectory.appending(path: "Wormlink-\(UUID().uuidString).command")
        try? "#!/bin/sh\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension Notification.Name {
    static let wormlinkCommand = Notification.Name("wormlink.command")
    static let wormlinkCreate = Notification.Name("wormlink.create")
    static let wormlinkNewVault = Notification.Name("wormlink.newVault")
    static let wormlinkRename = Notification.Name("wormlink.rename")
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// "Enviar Comando" (Transmit/Cyberduck): shell via SSH na pasta atual, ou comando FTP bruto.
struct CommandSheet: View {
    var pane: PaneModel
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var output = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pane.fs is SFTPFileSystem ? "Comando SSH em \(pane.path)" : "Comando FTP").font(.headline)
            HStack {
                TextField("", text: $command, prompt: Text(pane.fs is SFTPFileSystem ? "ls -la" : "SITE HELP"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(run)
                Button("Enviar", action: run).buttonStyle(.borderedProminent).disabled(command.isEmpty || running)
            }
            ScrollView {
                Text(output.isEmpty ? " " : output)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 260)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            .overlay { if running { ProgressView() } }
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func run() {
        guard !command.isEmpty else { return }
        running = true
        let line = command
        Task {
            let result = await pane.sendCommand(line)
            output += "> \(line)\n\(result)\n"
            running = false
        }
    }
}
