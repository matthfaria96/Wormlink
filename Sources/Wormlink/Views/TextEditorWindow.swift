import SwiftUI
import WormlinkCore

/// Editor embutido ("Editar no Wormlink"): texto puro, monoespaçado, salvo direto no servidor.
struct TextEditorWindow: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    @AppStorage("editorFontSize") private var fontSize = 13.0
    @AppStorage("editorWraps") private var wraps = true

    var body: some View {
        if let document = app.textDocuments[id] {
            content(document)
        } else {
            ContentUnavailableView("Documento fechado", systemImage: "doc.text")
        }
    }

    @ViewBuilder
    private func content(_ document: TextDocument) -> some View {
        @Bindable var document = document
        VStack(spacing: 0) {
            if document.isLoading {
                ProgressView("Abrindo “\(document.name)”…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $document.text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 6)
                    .lineLimit(wraps ? nil : 1)
            }
            Divider()
            HStack(spacing: 12) {
                Picker("Codificação", selection: Binding(get: { document.encoding.rawValue },
                                                         set: { document.reinterpret(as: String.Encoding(rawValue: $0)) })) {
                    ForEach(TextDocument.encodings, id: \.0.rawValue) { Text($0.1).tag($0.0.rawValue) }
                }
                .fixedSize()
                .disabled(document.isDirty)
                .help(document.isDirty ? "Salve antes de trocar a codificação" : "Reler o arquivo noutra codificação")
                Text("\(document.text.split(separator: "\n", omittingEmptySubsequences: false).count) linhas")
                    .foregroundStyle(.secondary)
                if let error = document.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(1)
                } else if let saved = document.lastSaved, !document.isDirty {
                    Text("Salvo no servidor às \(saved.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("Fonte \(Int(fontSize))", value: $fontSize, in: 9...28).fixedSize()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .navigationTitle(document.name)
        .navigationSubtitle("\(document.fs.title) — \(RemotePath.parent(document.remotePath))")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await document.save() }
                } label: {
                    if document.isSaving { ProgressView().controlSize(.small) } else { Label("Salvar", systemImage: "square.and.arrow.up") }
                }
                .keyboardShortcut("s")
                .disabled(!document.isDirty || document.isSaving)
                .help("Salvar no servidor (⌘S)")
            }
        }
        .task { if document.text.isEmpty && document.isLoading { await document.load() } }
        .onDisappear { if !document.isDirty { app.textDocuments[id] = nil } }
    }
}
