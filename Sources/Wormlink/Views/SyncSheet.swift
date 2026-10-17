import SwiftUI
import WormlinkCore

/// Sincronização entre as pastas abertas nos dois lados: opções → comparação → prévia → aplicar.
struct SyncSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var window: WindowModel
    @State private var leftToRight = true
    @State private var options = SyncOptions()
    @State private var skipText = TransferSettings.skipRules.patterns.joined(separator: ", ")
    @State private var phase: Phase = .options
    @State private var changes: [SyncChange] = []
    @State private var selected = Set<String>()
    @State private var comparing: Task<Void, Never>?

    enum Phase: Equatable { case options, comparing(String), preview, failed(String) }

    private var source: PaneModel? { leftToRight ? window.left.visibleFiles : window.right.visibleFiles }
    private var destination: PaneModel? { leftToRight ? window.right.visibleFiles : window.left.visibleFiles }

    var body: some View {
        VStack(spacing: 16) {
            header
            switch phase {
            case .options: optionsForm
            case .comparing(let folder): comparingView(folder)
            case .preview: preview
            case .failed(let message):
                ContentUnavailableView("Não foi possível comparar", systemImage: "exclamationmark.triangle", description: Text(message))
            }
            footer
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 380)
    }

    // MARK: Origem → destino

    private var header: some View {
        HStack(spacing: 12) {
            folderCard(source, role: "Origem")
            Button {
                leftToRight.toggle()
                phase = .options
            } label: {
                Image(systemName: "arrow.right").font(.title2.weight(.semibold))
                    .rotationEffect(.degrees(leftToRight ? 0 : 180))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Color.wormlink.opacity(0.35)).interactive(), in: .circle)
            .help("Inverter a direção")
            .disabled(phase != .options && phase != .preview)
            folderCard(destination, role: "Destino")
        }
    }

    private func folderCard(_ pane: PaneModel?, role: String) -> some View {
        VStack(spacing: 4) {
            Text(role).font(.caption).foregroundStyle(.secondary)
            Image(systemName: pane?.isLocal == false ? (pane?.bookmark?.icon.symbolName ?? "server.rack") : "desktopcomputer")
                .font(.title2).foregroundStyle(Color.wormlink)
            Text(pane?.title ?? "—").font(.headline).lineLimit(1)
            Text(pane?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: Opções

    private var optionsForm: some View {
        Form {
            Picker("Comparar por", selection: $options.compare) {
                ForEach(SyncOptions.Compare.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Apagar no destino o que não existe na origem", isOn: $options.deleteOrphans)
            TextField("Ignorar", text: $skipText, prompt: Text(".DS_Store, *.tmp, node_modules"))
            Stepper(value: $options.timeOffset, in: -86_400...86_400, step: 3_600) {
                LabeledContent("Diferença de fuso", value: options.timeOffset == 0 ? "Nenhuma" : "\(Int(options.timeOffset / 3_600)) h")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func comparingView(_ folder: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Comparando…").font(.headline)
            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Prévia ("Show Changes")

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if changes.isEmpty {
                ContentUnavailableView("Tudo sincronizado", systemImage: "checkmark.circle",
                                       description: Text("As duas pastas já estão iguais."))
            } else {
                HStack {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(selected.count == changes.count ? "Desmarcar Tudo" : "Marcar Tudo") {
                        selected = selected.count == changes.count ? [] : Set(changes.map(\.id))
                    }
                    .buttonStyle(.link)
                }
                List(changes) { change in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { selected.contains(change.id) },
                                                 set: { if $0 { selected.insert(change.id) } else { selected.remove(change.id) } }))
                            .labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: icon(change.kind)).foregroundStyle(color(change.kind))
                        Image(systemName: change.isDirectory ? "folder.fill" : "doc").foregroundStyle(.secondary)
                        Text(change.relativePath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(change.kind == .delete ? "apagar" : change.size.formatted(.byteCount(style: .file)))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 220)
            }
        }
    }

    private var summary: String {
        let adds = changes.filter { $0.kind == .add }.count
        let updates = changes.filter { $0.kind == .update }.count
        let deletes = changes.filter { $0.kind == .delete }.count
        let bytes = changes.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
        return "\(adds) novo(s), \(updates) alterado(s), \(deletes) para apagar — \(bytes.formatted(.byteCount(style: .file))) a transferir"
    }

    private func icon(_ kind: SyncChange.Kind) -> String {
        switch kind {
        case .add: "plus.circle.fill"
        case .update: "arrow.triangle.2.circlepath.circle.fill"
        case .delete: "minus.circle.fill"
        }
    }

    private func color(_ kind: SyncChange.Kind) -> Color {
        switch kind {
        case .add: .green
        case .update: .wormlink
        case .delete: .red
        }
    }

    // MARK: Botões

    private var footer: some View {
        HStack {
            if phase == .preview || { if case .failed = phase { return true }; return false }() {
                Button("Voltar às Opções") { phase = .options }
            }
            Spacer()
            Button("Cancelar") {
                comparing?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if phase == .preview && !changes.isEmpty {
                Button("Sincronizar") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent).tint(.wormlink)
                    .disabled(selected.isEmpty)
            } else if phase == .options {
                Button("Comparar") { compare() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent).tint(.wormlink)
                    .disabled(source == nil || destination == nil)
            }
        }
        .controlSize(.large)
    }

    private var synchronizer: Synchronizer? {
        guard let source, let destination else { return nil }
        var options = options
        options.skip = SkipRules(patterns: skipText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return Synchronizer(from: source.fs, to: destination.fs, options: options)
    }

    private func compare() {
        guard let synchronizer, let source, let destination else { return }
        phase = .comparing("/")
        comparing = Task {
            do {
                let found = try await synchronizer.compare(source.path, destination.path) { folder in
                    Task { @MainActor in if case .comparing = phase { phase = .comparing(folder) } }
                }
                changes = found
                // Apagar nunca vem marcado por padrão; o usuário confirma na prévia.
                selected = Set(found.filter { $0.kind != .delete }.map(\.id))
                phase = .preview
            } catch is CancellationError {
                phase = .options
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply() {
        guard let synchronizer, let source, let destination else { return }
        let chosen = changes.filter { selected.contains($0.id) }
        app.transfers.enqueueSync(chosen, with: synchronizer, sourceRoot: source.path, destinationRoot: destination.path,
                                  title: "Sincronizar \(RemotePath.name(source.path))") { [destination] in
            Task { await destination.reload() }
        }
        dismiss()
    }
}
