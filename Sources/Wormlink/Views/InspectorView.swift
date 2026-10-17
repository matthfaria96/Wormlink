import SwiftUI
import WormlinkCore

/// "Obter Informações": detalhes do item selecionado no lado ativo e edição de permissões.
struct InspectorView: View {
    var window: WindowModel
    @State private var mode: UInt16 = 0
    @State private var editedPath: String?

    private var pane: PaneModel? { window.activeFiles }
    private var item: FileItem? { pane?.selectedItems.first }

    var body: some View {
        ScrollView {
            if let pane, let item {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 8) {
                        Image(nsImage: FileIcons.icon(for: item, size: 64))
                        Text(item.name).font(.headline).multilineTextAlignment(.center).textSelection(.enabled)
                        Text(FileIcons.kind(of: item)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    section("Informações") {
                        info("Tamanho", item.size.map { "\($0.formatted(.byteCount(style: .file))) (\($0.formatted()) bytes)" } ?? "—")
                        info("Modificado", item.modified?.formatted(date: .long, time: .shortened) ?? "—")
                        info("Onde", RemotePath.parent(item.path))
                        if let target = item.linkTarget { info("Aponta para", target) }
                        if let owner = item.owner { info("Dono", owner + (item.group.map { " : \($0)" } ?? "")) }
                        if let bookmark = pane.bookmark, let url = bookmark.publicURL(for: item.path) {
                            info("URL", url.absoluteString)
                        }
                    }

                    if let s3 = pane.fs as? S3FileSystem {
                        S3InspectorSection(fs: s3, item: item) { title, content in AnyView(section(title) { content }) }
                    }

                    if pane.fs.supportsPermissions, item.mode != nil {
                        section("Permissões") {
                            permissions(pane: pane, item: item)
                        }
                    }
                }
                .padding(16)
                .onAppear { sync(item) }
                .onChange(of: item) { sync(item) }
            } else {
                ContentUnavailableView("Nada selecionado", systemImage: "info.circle",
                                       description: Text("Selecione um arquivo ou pasta para ver os detalhes."))
                    .padding(.top, 60)
            }
        }
    }

    private func sync(_ item: FileItem) {
        mode = item.mode ?? 0
        editedPath = item.path
    }

    @ViewBuilder
    private func permissions(pane: PaneModel, item: FileItem) -> some View {
        Grid(alignment: .center, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("")
                Text("Ler").font(.caption).foregroundStyle(.secondary)
                Text("Gravar").font(.caption).foregroundStyle(.secondary)
                Text("Executar").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(["Dono", "Grupo", "Todos"].enumerated()), id: \.offset) { index, who in
                GridRow {
                    Text(who).font(.callout).gridColumnAlignment(.leading)
                    ForEach(0..<3) { bit in
                        let mask = UInt16(1) << UInt16((2 - index) * 3 + (2 - bit))
                        Toggle("", isOn: Binding(get: { mode & mask != 0 }, set: { mode = $0 ? mode | mask : mode & ~mask }))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
        HStack {
            Text(String(format: "%03o", mode)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            Text(FileItem.permissionString(mode)).font(.caption.monospaced()).foregroundStyle(.tertiary)
            Spacer()
            Button("Aplicar") { Task { await pane.setPermissions(item, mode: mode) } }
                .buttonStyle(.glassProminent)
                .tint(.wormlink)
                .disabled(mode == (item.mode ?? 0))
        }
        .padding(.top, 6)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).lineLimit(3)
        }
    }
}
