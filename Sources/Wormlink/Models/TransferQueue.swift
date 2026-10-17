import AppKit
import SwiftUI
import WormlinkCore

/// Preferências de transferência (Ajustes › Transferências).
nonisolated enum TransferSettings {
    static var maxConcurrent: Int { max(1, UserDefaults.standard.object(forKey: "maxConcurrentTransfers") as? Int ?? 2) }
    /// "ask", "overwrite", "skip", "rename" ou "resume".
    static var conflictPolicy: String { UserDefaults.standard.string(forKey: "conflictPolicy") ?? "ask" }
    static var preserveDates: Bool { UserDefaults.standard.object(forKey: "preserveDates") as? Bool ?? true }
    static var atomicUploads: Bool { UserDefaults.standard.object(forKey: "atomicUploads") as? Bool ?? true }
    static var verifyChecksums: Bool { UserDefaults.standard.bool(forKey: "verifyChecksums") }
    static var copyURLsAfterUpload: Bool { UserDefaults.standard.bool(forKey: "copyURLsAfterUpload") }

    /// Aplica os limites de velocidade guardados (KB/s; 0 = sem limite).
    static func applyBandwidthLimits() {
        BandwidthLimiter.shared.setLimit(Int64(UserDefaults.standard.integer(forKey: "limitUploadKB")) * 1024, for: .upload)
        BandwidthLimiter.shared.setLimit(Int64(UserDefaults.standard.integer(forKey: "limitDownloadKB")) * 1024, for: .download)
    }

    static var skipRules: SkipRules {
        SkipRules(patterns: UserDefaults.standard.stringArray(forKey: "skipPatterns") ?? SkipRules.default.patterns)
    }
}

/// Uma tarefa na fila: cópia de itens de um lado para o outro, ou uma sincronização.
@Observable
final class Transfer: Identifiable {
    enum Kind { case upload, download, copy, sync }
    enum State: Equatable { case waiting, preparing, running, paused, finished, failed(String), cancelled }

    let id = UUID()
    let kind: Kind
    let title: String
    let destination: String
    var total: Int64 = 0
    var done: Int64 = 0
    var state: State = .waiting
    var detail: String?
    let started = Date()
    private var resumeFrom: Date?
    fileprivate var task: Task<Void, Never>?
    /// O trabalho em si; pode rodar de novo em "Tentar de novo".
    fileprivate let job: @MainActor (Transfer) async throws -> Void

    init(kind: Kind, title: String, destination: String, job: @escaping @MainActor (Transfer) async throws -> Void) {
        self.kind = kind
        self.title = title
        self.destination = destination
        self.job = job
    }

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var isActive: Bool { state == .waiting || state == .preparing || state == .running }
    var canRetry: Bool { if case .failed = state { return true }; return state == .cancelled }
    /// Ao continuar depois de pausar, arquivos já completos são pulados e os parciais retomados.
    fileprivate var resuming = false
    fileprivate var pausing = false
    /// O que o usuário escolheu para cada conflito na primeira passada (vale de novo ao continuar).
    fileprivate let decisions = DecisionLog()
    /// Cada execução tem um número: o fim atrasado de uma execução antiga não mexe no estado da nova.
    fileprivate var run = 0

    func pause() {
        guard isActive else { return }
        pausing = true
        task?.cancel()
        state = .paused
    }

    /// Velocidade média desde o início (bytes/s).
    var speed: Double {
        let elapsed = Date().timeIntervalSince(resumeFrom ?? started)
        return elapsed > 0.5 ? Double(done) / elapsed : 0
    }

    func cancel() {
        task?.cancel()
        if isActive { state = .cancelled }
    }

    fileprivate func markStarted() { resumeFrom = .now }
}

@Observable
final class TransferQueue {
    private(set) var transfers: [Transfer] = []

    var activeCount: Int {
        let count = transfers.filter(\.isActive).count
        ActiveTransfers.count = count
        return count
    }

    /// Progresso somado das transferências em andamento (para o indicador da barra).
    var overallFraction: Double {
        let active = transfers.filter(\.isActive)
        let total = active.reduce(0) { $0 + $1.total }
        return total > 0 ? Double(active.reduce(0) { $0 + $1.done }) / Double(total) : 0
    }

    /// Copia `items` de `source` para a pasta `directory` de `destination` e chama `completion` ao terminar.
    func enqueue(_ items: [FileItem], from source: any FileSystem, to destination: any FileSystem,
                 into directory: String, bookmark: Bookmark? = nil, completion: @escaping () -> Void) {
        guard !items.isEmpty else { return }
        let kind: Transfer.Kind = source is LocalFileSystem ? .upload : (destination is LocalFileSystem ? .download : .copy)
        let title = items.count == 1 ? items[0].name : "\(items.count) itens"
        add(Transfer(kind: kind, title: title, destination: "\(destination.title): \(directory)") { transfer in
            let ask = ConflictPrompter.resolver(for: transfer.title)
            let resuming = transfer.resuming
            var copier = Copier(from: source, to: destination, skip: TransferSettings.skipRules,
                                resolver: { [decisions = transfer.decisions] item, existing in
                                    if resuming, !item.isDirectory {
                                        // Continuando: repete a escolha feita antes. Só o que esta transferência criou
                                        // (ou mandou retomar) é medido pelo tamanho; um arquivo antigo nunca é "continuado".
                                        switch decisions[item.path] {
                                        case .overwrite?: return .overwrite
                                        case .skip?: return .skip
                                        case .rename?: return .rename
                                        case .resume?, nil:
                                            if let have = existing.size, let want = item.size {
                                                return have == want ? .skip : (have < want ? .resume : .overwrite)
                                            }
                                        }
                                    }
                                    let action = await ask(item, existing)
                                    decisions[item.path] = action
                                    return action
                                },
                                preserveDates: TransferSettings.preserveDates)
            copier.atomicUploads = TransferSettings.atomicUploads
            copier.verifyChecksums = TransferSettings.verifyChecksums
            var total: Int64 = 0
            for item in items { total += try await copier.totalSize(of: item) }
            transfer.total = total
            transfer.state = .running
            do {
                for item in items {
                    try Task.checkCancellation()
                    transfer.detail = item.name
                    try await copier.copy(item, into: directory) { delta in
                        Task { @MainActor in transfer.done += delta }
                    }
                }
            } catch {
                // Pausada fica para continuar; falha ou cancelamento também avisam quem esperava (fechar conexões).
                if !transfer.pausing { completion() }
                throw error
            }
            // "Copiar URLs depois do envio" (Transmit): endereços públicos dos itens enviados.
            if let bookmark, kind == .upload, TransferSettings.copyURLsAfterUpload {
                let urls = items.compactMap { bookmark.publicURL(for: RemotePath.join(directory, $0.name))?.absoluteString }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
            }
            completion()
        })
    }

    /// Aplica uma sincronização já comparada (as mudanças escolhidas na prévia).
    func enqueueSync(_ changes: [SyncChange], with synchronizer: Synchronizer, sourceRoot: String, destinationRoot: String,
                     title: String, completion: @escaping () -> Void) {
        add(Transfer(kind: .sync, title: title, destination: "\(synchronizer.destination.title): \(destinationRoot)") { transfer in
            transfer.total = changes.reduce(0) { $0 + $1.size }
            transfer.state = .running
            let failures = FailureList()
            try await synchronizer.apply(changes, sourceRoot: sourceRoot, destinationRoot: destinationRoot,
                                         progress: { delta in Task { @MainActor in transfer.done += delta } },
                                         done: { change, error in
                                             if let error { failures.add("\(change.relativePath): \(error.localizedDescription)") }
                                             Task { @MainActor in transfer.detail = change.relativePath }
                                         })
            completion()
            if let first = failures.first { throw SyncFailure(message: String(localized: "\(failures.count) erro(s). \(first)")) }
        })
    }

    var isPaused: Bool { transfers.contains { $0.state == .paused } && activeCount == 0 }

    func pauseAll() { transfers.filter(\.isActive).forEach { $0.pause() } }

    func resumeAll() { transfers.filter { $0.state == .paused }.forEach(resume) }

    /// Continua de onde parou (arquivos completos são pulados, parciais retomados).
    func resume(_ transfer: Transfer) {
        guard transfer.state == .paused else { return }
        transfer.resuming = true
        transfer.done = 0
        transfer.state = .waiting
        pump()
    }

    func retry(_ transfer: Transfer) {
        guard transfer.canRetry else { return }
        transfer.resuming = true
        transfer.done = 0
        transfer.state = .waiting
        transfer.detail = nil
        pump()
    }

    func clearFinished() { transfers.removeAll { !$0.isActive } }

    private func add(_ transfer: Transfer) {
        transfers.insert(transfer, at: 0)
        pump()
    }

    /// Inicia as que estão esperando, respeitando o limite de transferências simultâneas.
    private func pump() {
        let running = transfers.filter { $0.state == .preparing || $0.state == .running }.count
        let waiting = transfers.filter { $0.state == .waiting }.reversed()   // a mais antiga primeiro
        for transfer in waiting.prefix(max(0, TransferSettings.maxConcurrent - running)) {
            transfer.state = .preparing
            transfer.markStarted()
            transfer.run += 1
            let run = transfer.run, previous = transfer.task
            transfer.task = Task {
                // A execução anterior (pausada ou cancelada) precisa terminar antes: nunca duas no mesmo arquivo.
                await previous?.value
                guard transfer.run == run else { return }
                transfer.pausing = false
                do {
                    try await transfer.job(transfer)
                    guard transfer.run == run else { return }
                    transfer.done = max(transfer.done, transfer.total)
                    transfer.state = .finished
                    Notifier.transferFinished(transfer)
                } catch is CancellationError {
                    guard transfer.run == run else { return }
                    transfer.state = transfer.pausing ? .paused : .cancelled
                } catch {
                    guard transfer.run == run else { return }
                    transfer.state = transfer.pausing ? .paused : (Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
                }
                ActiveTransfers.count = self.transfers.filter(\.isActive).count
                pump()
            }
        }
        ActiveTransfers.count = transfers.filter(\.isActive).count
    }
}

private struct SyncFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated private final class FailureList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var count: Int { lock.withLock { items.count } }
    var first: String? { lock.withLock { items.first } }
}

/// Pergunta o que fazer quando o destino já tem o item, conforme os Ajustes.
enum ConflictPrompter {
    static func resolver(for title: String) -> ConflictResolver {
        let memory = ConflictMemory()
        let policy = TransferSettings.conflictPolicy
        return { source, existing in
            if let fixed = ConflictAction(rawValue: policy) { return fixed }
            if let all = memory.choice { return all }
            let (action, applyToAll) = await ask(source, existing)
            if applyToAll { memory.choice = action }
            return action
        }
    }

    @MainActor
    private static func ask(_ source: FileItem, _ existing: FileItem) -> (ConflictAction, Bool) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(source.name)” já existe no destino")
        let mine = source.size.map { $0.formatted(.byteCount(style: .file)) } ?? "—"
        let theirs = existing.size.map { $0.formatted(.byteCount(style: .file)) } ?? "—"
        alert.informativeText = "Origem: \(mine), \(source.modified?.shortStamp ?? "—")\nDestino: \(theirs), \(existing.modified?.shortStamp ?? "—")"
        let canResume = !source.isDirectory && (existing.size ?? 0) < (source.size ?? 0)
        var actions: [ConflictAction] = [.overwrite]
        if canResume { actions.append(.resume) }
        actions += [.rename, .skip]
        for action in actions { alert.addButton(withTitle: action.title) }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Aplicar a todos nesta transferência")
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let action = actions.indices.contains(response) ? actions[response] : .skip
        return (action, alert.suppressionButton?.state == .on)
    }
}

nonisolated private final class ConflictMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ConflictAction?
    var choice: ConflictAction? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

nonisolated final class DecisionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var choices: [String: ConflictAction] = [:]
    subscript(path: String) -> ConflictAction? {
        get { lock.withLock { choices[path] } }
        set { lock.withLock { choices[path] = newValue } }
    }
}
