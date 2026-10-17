import QuickLookThumbnailing
import SwiftUI
import WormlinkCore

/// Ordem do Finder: pastas primeiro, nomes em ordem natural; ocultos só se o painel mostra.
private func arranged(_ items: [FileItem], showHidden: Bool) -> [FileItem] {
    let shown = showHidden ? items : items.filter { !$0.isHidden }
    let sorted = shown.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
}

// MARK: - Colunas

/// Visualização em colunas (como o Finder e o Transmit): cada pasta escolhida abre uma coluna à direita.
struct ColumnBrowser: View {
    var pane: PaneModel
    var open: (FileItem) -> Void
    var menu: ([FileItem]) -> AnyView
    var activate: () -> Void
    /// Pastas abertas depois da pasta do painel, uma por coluna.
    @State private var trail: [String] = []
    @State private var listings: [String: [FileItem]] = [:]
    @State private var selected: [String: FileItem.ID] = [:]
    @State private var failed: [String: String] = [:]

    private var columns: [String] { [pane.path] + trail }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element) { index, folder in
                        column(index, folder).frame(width: 230)
                        Divider()
                    }
                    if let file = selectedFile { FileSummary(item: file, pane: pane).frame(width: 240).id("resumo") }
                }
            }
            .onChange(of: trail) { withAnimation(.snappy) { proxy.scrollTo(selectedFile == nil ? columns.last : "resumo", anchor: .trailing) } }
        }
        .onChange(of: pane.path) { trail = []; selected = [:] }
        .onAppear {
            // Vindo de outra visualização: abre a pasta que estava selecionada.
            if let id = pane.selection.first, items(in: pane.path).contains(where: { $0.id == id }) { choose(id, in: pane.path, at: 0) }
        }
    }

    private var selectedFile: FileItem? {
        guard let id = selected[columns.last ?? ""] else { return nil }
        return items(in: columns.last!).first { $0.id == id && !$0.isDirectory }
    }

    private func items(in folder: String) -> [FileItem] {
        folder == pane.path ? pane.rows.filter { $0.depth == 0 }.map(\.item) : arranged(listings[folder] ?? [], showHidden: pane.showHidden)
    }

    private func column(_ index: Int, _ folder: String) -> some View {
        let list = items(in: folder)
        return List(selection: Binding(get: { selected[folder] }, set: { id in choose(id, in: folder, at: index) })) {
            ForEach(list) { item in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: item))
                    Text(item.name).lineLimit(1).foregroundStyle(item.isHidden ? .secondary : .primary)
                    Spacer(minLength: 4)
                    if item.isDirectory {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
                .draggable(PaneDrag(pane: pane.id, paths: [item.path]))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if let error = failed[folder] {
                Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            } else if folder != pane.path && listings[folder] == nil {
                ProgressView().controlSize(.small)
            } else if list.isEmpty {
                Text("Pasta vazia").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            menu(list.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let item = list.first(where: { ids.contains($0.id) }), !item.isDirectory { open(item) }
        }
    }

    private func choose(_ id: FileItem.ID?, in folder: String, at index: Int) {
        selected[folder] = id
        activate()
        trail = Array(trail.prefix(index))
        guard let id, let item = items(in: folder).first(where: { $0.id == id }) else { return }
        if folder == pane.path { pane.selection = [id] }
        guard item.isDirectory else { return }
        trail.append(item.path)
        Task { await load(item.path) }
    }

    private func load(_ folder: String) async {
        do {
            listings[folder] = try await pane.fs(for: folder).list(folder)
            failed[folder] = nil
        } catch {
            failed[folder] = error.localizedDescription
        }
    }
}

/// Coluna final com o resumo do arquivo escolhido.
private struct FileSummary: View {
    let item: FileItem
    let pane: PaneModel

    var body: some View {
        VStack(spacing: 10) {
            Thumbnail(item: item, pane: pane, size: 150)
            Text(item.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            Text(FileIcons.kind(of: item)).font(.caption).foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                if let size = item.size {
                    GridRow { Text("Tamanho").foregroundStyle(.secondary); Text(size.formatted(.byteCount(style: .file))) }
                }
                if let date = item.modified {
                    GridRow { Text("Modificado").foregroundStyle(.secondary); Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
                if let mode = item.mode {
                    GridRow { Text("Permissões").foregroundStyle(.secondary); Text(FileItem.permissionString(mode)).monospaced() }
                }
            }
            .font(.caption)
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Galeria

/// Galeria: visualização grande do item escolhido e uma faixa de miniaturas embaixo.
struct GalleryBrowser: View {
    var pane: PaneModel
    var open: (FileItem) -> Void
    var menu: ([FileItem]) -> AnyView
    var activate: () -> Void

    private var items: [FileItem] { pane.rows.filter { $0.depth == 0 }.map(\.item) }
    private var current: FileItem? { items.first { pane.selection.contains($0.id) } ?? items.first }

    var body: some View {
        VStack(spacing: 0) {
            if let current {
                VStack(spacing: 8) {
                    Thumbnail(item: current, pane: pane, size: 260)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture(count: 2) { open(current) }
                    Text(current.name).font(.headline).lineLimit(1)
                    Text([FileIcons.kind(of: current), current.size.map { $0.formatted(.byteCount(style: .file)) },
                          current.modified?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " — "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .contextMenu { menu([current]) }
            } else {
                Spacer()
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(items) { item in
                            let isCurrent = item.id == current?.id
                            Thumbnail(item: item, pane: pane, size: 64, remoteThumbnails: false)
                                .frame(width: 76, height: 76)
                                .background(isCurrent ? Color.wormlink.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
                                .overlay { if isCurrent { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.wormlink, lineWidth: 2) } }
                                .contentShape(.rect)
                                .onTapGesture(count: 2) { open(item) }
                                .onTapGesture { pane.selection = [item.id]; activate() }
                                .draggable(PaneDrag(pane: pane.id, paths: [item.path]))
                                .contextMenu { menu([item]) }
                                .help(item.name)
                                .id(item.id)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 98)
                .onChange(of: current?.id) { if let id = current?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                .onAppear { if let id = current?.id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard let current, let index = items.firstIndex(of: current) else { return .ignored }
        let next = min(max(index + delta, 0), items.count - 1)
        pane.selection = [items[next].id]
        return .handled
    }
}

// MARK: - Miniaturas

/// Miniatura do Quick Look: direto para arquivos locais; imagens remotas pequenas são baixadas para um cache.
struct Thumbnail: View {
    let item: FileItem
    let pane: PaneModel
    let size: CGFloat
    var remoteThumbnails = true
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: size > 100 ? 8 : 4))
                    .shadow(color: .black.opacity(0.2), radius: size > 100 ? 6 : 2, y: 2)
            } else {
                Image(nsImage: FileIcons.icon(for: item, size: size)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: size, maxHeight: size)
        .task(id: item.path) { image = await ThumbnailCache.thumbnail(for: item, pane: pane, size: size, remote: remoteThumbnails) }
    }
}

enum ThumbnailCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    static let previewable: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg", "pdf", "avif"]
    static let remoteLimit: Int64 = 8 * 1024 * 1024

    static func thumbnail(for item: FileItem, pane: PaneModel, size: CGFloat, remote: Bool) async -> NSImage? {
        guard !item.isDirectory else { return nil }
        let key = "\(pane.id)|\(item.path)|\(item.modified?.timeIntervalSince1970 ?? 0)|\(Int(size))" as NSString
        if let cached = images.object(forKey: key) { return cached }
        var url: URL
        if pane.isLocal {
            url = URL(filePath: item.path)
        } else {
            let ext = (item.name as NSString).pathExtension.lowercased()
            guard remote, previewable.contains(ext), let bytes = item.size, bytes <= remoteLimit else { return nil }
            url = FileManager.default.temporaryDirectory.appending(path: "Wormlink-Galeria")
                .appending(path: "\(abs(key.hash))." + ext)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try await pane.fs.download(item.path, to: url) { _ in } } catch { return nil }
            }
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        images.setObject(image, forKey: key)
        return image
    }
}
