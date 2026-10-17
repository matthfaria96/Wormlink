import SwiftUI
import WormlinkCore

/// Recebe as linhas do Transcript do núcleo e as publica na interface.
@Observable
final class TranscriptModel {
    private(set) var lines: [Transcript.Line] = Transcript.shared.snapshot
    private var token: UUID?

    init() {
        token = Transcript.shared.observe { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.lines.append(line)
                if self.lines.count > 5_000 { self.lines.removeFirst(self.lines.count - 5_000) }
            }
        }
    }

    func clear() {
        Transcript.shared.clear()
        lines.removeAll()
    }
}

/// Janela "Transcript": comandos enviados e respostas dos servidores, para diagnosticar conexões.
struct TranscriptView: View {
    @State private var model = TranscriptModel()
    @State private var host = ""
    @State private var follow = true

    private var hosts: [String] { Array(Set(model.lines.map(\.host))).sorted() }
    private var visible: [Transcript.Line] { host.isEmpty ? model.lines : model.lines.filter { $0.host == host } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(visible) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.date.formatted(.dateTime.hour().minute().second()))
                            .foregroundStyle(.tertiary)
                        Text(line.host).foregroundStyle(Color.wormlink).lineLimit(1).frame(width: 110, alignment: .leading)
                        Text(line.text)
                            .foregroundStyle(line.isReply ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    .font(.callout.monospaced())
                    .id(line.id)
                }
                .listStyle(.plain)
                .onChange(of: model.lines.count) {
                    if follow, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Picker("Servidor", selection: $host) {
                    Text("Todos").tag("")
                    ForEach(hosts, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Toggle("Acompanhar", isOn: $follow)
                Spacer()
                Button("Copiar") {
                    let text = visible.map { "\($0.date.formatted(.iso8601)) \($0.host) \($0.isReply ? "<" : ">") \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Limpar") { model.clear() }
            }
            .padding(8)
        }
        .frame(minWidth: 560, minHeight: 300)
    }
}
