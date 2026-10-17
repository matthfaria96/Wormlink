import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let queue = app.transfers
        VStack(spacing: 0) {
            if queue.transfers.isEmpty {
                ContentUnavailableView("Nenhuma transferência", systemImage: "arrow.up.arrow.down",
                                       description: Text("Arraste arquivos entre os lados para começar."))
            } else {
                List(queue.transfers) { TransferRow(transfer: $0, queue: queue) }
                    .listStyle(.inset)
                HStack {
                    Text(queue.activeCount == 0 ? "Tudo pronto" : "\(queue.activeCount) em andamento")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if queue.activeCount > 0 {
                        Button("Pausar Todas", systemImage: "pause.fill") { queue.pauseAll() }.buttonStyle(.bordered)
                    } else if queue.transfers.contains(where: { $0.state == .paused }) {
                        Button("Continuar Todas", systemImage: "play.fill") { queue.resumeAll() }.buttonStyle(.bordered)
                    }
                    Button("Limpar Concluídas") { queue.clearFinished() }
                        .buttonStyle(.bordered)
                        .disabled(queue.transfers.allSatisfy(\.isActive))
                }
                .padding(10)
            }
        }
    }
}

private struct TransferRow: View {
    var transfer: Transfer
    var queue: TransferQueue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.title).font(.headline).lineLimit(1)
                    if transfer.isActive {
                        ProgressView(value: transfer.fraction).progressViewStyle(.linear)
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if transfer.isActive {
                    Button("Pausar", systemImage: "pause.circle.fill") { transfer.pause() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    Button("Cancelar", systemImage: "xmark.circle.fill") { transfer.cancel() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                } else if transfer.state == .paused {
                    Button("Continuar", systemImage: "play.circle.fill") { queue.resume(transfer) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    Button("Cancelar", systemImage: "xmark.circle.fill") { transfer.cancel(); transfer.state = .cancelled }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                } else if transfer.canRetry {
                    Button("Tentar de Novo", systemImage: "arrow.clockwise.circle.fill") { queue.retry(transfer) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Tentar de novo (arquivos que já chegaram podem ser retomados)")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var symbol: String {
        switch transfer.kind {
        case .upload: "arrow.up.circle.fill"
        case .download: "arrow.down.circle.fill"
        case .copy: "arrow.left.arrow.right.circle.fill"
        case .sync: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .failed: .red
        case .cancelled, .waiting, .paused: .secondary
        case .finished: .green
        default: .wormlink
        }
    }

    private var status: String {
        let done = transfer.done.formatted(.byteCount(style: .file))
        let total = transfer.total.formatted(.byteCount(style: .file))
        switch transfer.state {
        case .waiting: return String(localized: "Aguardando…")
        case .preparing: return String(localized: "Preparando…")
        case .running:
            var text = String(localized: "\(done) de \(total)")
            if transfer.speed > 0 {
                text += " — \(Int64(transfer.speed).formatted(.byteCount(style: .file)))/s"
                let remaining = Double(transfer.total - transfer.done) / transfer.speed
                if remaining.isFinite, remaining > 1 {
                    text += String(localized: ", cerca de \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) restantes")
                }
            }
            if let detail = transfer.detail { text += "\n\(detail)" }
            return text
        case .finished: return String(localized: "Concluída — \(total) em \(transfer.destination)")
        case .failed(let message): return String(localized: "Falhou: \(message)")
        case .cancelled: return String(localized: "Cancelada")
        case .paused: return String(localized: "Pausada — \(done) de \(total)")
        }
    }
}
