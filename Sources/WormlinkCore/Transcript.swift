import Foundation
import Logging

/// Registro das operações de protocolo (o "Transcript" do Transmit), para diagnosticar conexões.
/// Senhas nunca entram aqui.
public final class Transcript: @unchecked Sendable {
    public struct Line: Identifiable, Sendable {
        public let id: Int
        public let date: Date
        public let host: String
        public let text: String
        public let isReply: Bool
    }

    public static let shared = Transcript()
    private let lock = NSLock()
    private var lines: [Line] = []
    private var counter = 0
    private var observers: [UUID: @Sendable (Line) -> Void] = [:]
    static let limit = 5_000

    public static func log(_ host: String, _ text: String, reply: Bool = false) { shared.append(host, text, reply: reply) }

    public func append(_ host: String, _ text: String, reply: Bool = false) {
        let (line, observers) = lock.withLock { () -> (Line, [@Sendable (Line) -> Void]) in
            counter += 1
            let line = Line(id: counter, date: .now, host: host, text: text, isReply: reply)
            lines.append(line)
            if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
            return (line, Array(self.observers.values))
        }
        observers.forEach { $0(line) }
    }

    public var snapshot: [Line] { lock.withLock { lines } }

    public func clear() { lock.withLock { lines.removeAll() } }

    /// Recebe cada linha nova (em qualquer thread). Devolve um token para `stopObserving`.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (Line) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    public func stopObserving(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
}

public enum WormlinkLogging {
    /// A Citadel registra cada operação SFTP em nível info; o Wormlink mostra isso no Transcript,
    /// então o console só recebe avisos e erros.
    public static func configure() {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .warning
            return handler
        }
    }
}
