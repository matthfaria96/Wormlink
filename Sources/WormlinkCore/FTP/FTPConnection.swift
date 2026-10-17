import Foundation
import NIOCore
import NIOPosix
import NIOTLS
@preconcurrency import NIOSSL

/// Resposta do servidor FTP (código de 3 dígitos + texto, possivelmente em várias linhas).
struct FTPReply: Sendable {
    let code: Int
    let lines: [String]
    var text: String { lines.joined(separator: "\n") }
    var isPositive: Bool { (100..<400).contains(code) }
}

enum FTPSecurity: Sendable { case none, explicitTLS, implicitTLS }

struct FTPConfig: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let security: FTPSecurity
    let certificateTrust: CertificateTrust
    var encoding: String.Encoding = .utf8
    var useMLSD = true
    var timeout = 20
    /// Extensões transferidas em modo ASCII (vazio = sempre binário).
    var asciiExtensions: Set<String> = []

    func isASCII(_ path: String) -> Bool {
        !asciiExtensions.isEmpty && asciiExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    func tlsHandler(context: NIOSSLContext) throws -> NIOSSLClientHandler {
        try NIOSSLClientHandler(context: context, serverHostname: FTPConnection.sniName(host),
                                customVerificationCallback: CertificateTrustStore.nioCallback(host: host, trust: certificateTrust))
    }
}

/// Uma conexão de controle FTP. Não é segura para uso simultâneo: quem chama garante a ordem.
final class FTPConnection: @unchecked Sendable {
    let config: FTPConfig
    private let channel: Channel
    private let replies: FTPReplyHandler
    private(set) var features: Set<String> = []
    private var protectedData = false

    private init(config: FTPConfig, channel: Channel, replies: FTPReplyHandler) {
        self.config = config
        self.channel = channel
        self.replies = replies
    }

    static func tlsContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        // A verificação (inclusive do nome do servidor) é feita pelo SecTrust em `CertificateTrustStore`.
        configuration.certificateVerification = .noHostnameVerification
        return try NIOSSLContext(configuration: configuration)
    }

    /// NIOSSL não aceita IP como nome para SNI.
    static func sniName(_ host: String) -> String? {
        (try? SocketAddress(ipAddress: host, port: 0)) == nil ? host : nil
    }

    static func open(_ config: FTPConfig) async throws -> FTPConnection {
        let replies = FTPReplyHandler(encoding: config.encoding)
        let tls = config.security == .implicitTLS ? try tlsContext() : nil
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(Int64(config.timeout)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(config.tlsHandler(context: tls)) }
                    try channel.pipeline.syncOperations.addHandler(replies)
                }
            }
            .connect(host: config.host, port: config.port).get()
        let connection = FTPConnection(config: config, channel: channel, replies: replies)
        do {
            try await connection.handshake()
        } catch {
            try? await channel.close()
            throw error
        }
        return connection
    }

    private func handshake() async throws {
        try await expect(await nextReply(), 220)
        if config.security == .explicitTLS {
            try await expect(await command("AUTH TLS"), 234)
            let context = try Self.tlsContext(), config = config, channel = channel
            try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(config.tlsHandler(context: context), position: .first)
            }.get()
        }
        if config.security != .none {
            _ = try await command("PBSZ 0")
            protectedData = try await command("PROT P").code == 200
        }
        // Login (anônimo quando não há usuário).
        let user = config.username.isEmpty ? "anonymous" : config.username
        var reply = try await command("USER \(user)")
        if reply.code == 331 || reply.code == 332 {
            reply = try await command("PASS \(config.username.isEmpty ? "anonymous@" : config.password)")
        }
        guard reply.code == 230 || reply.code == 202 else {
            throw reply.code == 530 ? WormlinkError.authenticationFailed : Self.error(reply)
        }
        let feat = try await command("FEAT")
        if feat.code == 211 {
            features = Set(feat.lines.dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
        }
        if features.contains(where: { $0.hasPrefix("UTF8") }) { _ = try await command("OPTS UTF8 ON") }
        // Pede os fatos de permissão e dono no MLSD, como o Cyberduck.
        if features.contains(where: { $0.hasPrefix("MLST") }) {
            _ = try await command("OPTS MLST type;size;modify;UNIX.mode;UNIX.owner;UNIX.group;UNIX.ownername;UNIX.groupname;")
        }
        _ = try await command("TYPE I")
    }

    // MARK: Comandos

    func nextReply() async throws -> FTPReply {
        let reply = try await channel.eventLoop.flatSubmit { self.replies.next(on: self.channel.eventLoop) }.get()
        Transcript.log(config.host, reply.text, reply: true)
        return reply
    }

    func send(_ line: String) async throws {
        Transcript.log(config.host, line.hasPrefix("PASS ") ? "PASS ••••••" : line)
        var buffer = channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeBytes(line.data(using: config.encoding, allowLossyConversion: true) ?? Data(line.utf8))
        buffer.writeString("\r\n")
        do {
            try await channel.writeAndFlush(buffer)
        } catch {
            // Uma escrita que falha por canal fechado esconde a causa (ex.: falha no TLS).
            throw (try? await channel.eventLoop.submit { self.replies.failure }.get()) ?? error
        }
    }

    @discardableResult
    func command(_ line: String) async throws -> FTPReply {
        try await send(line)
        return try await nextReply()
    }

    @discardableResult
    func expect(_ reply: FTPReply, _ codes: Int...) async throws -> FTPReply {
        guard codes.contains(reply.code) else { throw Self.error(reply) }
        return reply
    }

    static func error(_ reply: FTPReply) -> WormlinkError {
        reply.code == 550 && reply.text.localizedCaseInsensitiveContains("no such")
            ? .notFound(reply.text) : .server(status: reply.code, message: reply.lines.last ?? "")
    }

    func close() async {
        _ = try? await command("QUIT")
        try? await channel.close()
    }

    var isOpen: Bool { channel.isActive }

    // MARK: Conexão de dados (modo passivo)

    private func passiveAddress() async throws -> (String, Int) {
        let epsv = try await command("EPSV")
        if epsv.code == 229, let port = epsv.text.split(separator: "|").compactMap({ Int($0) }).first {
            return (config.host, port)
        }
        let pasv = try await expect(command("PASV"), 227)
        let numbers = pasv.text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 7 else { throw WormlinkError.invalidResponse }
        let p = numbers.suffix(6).map { $0 }
        // Como o Cyberduck, usa o endereço do controle: servidores atrás de NAT anunciam IPs internos.
        return (config.host, p[4] * 256 + p[5])
    }

    /// Abre a conexão de dados, envia `command` e entrega o canal a `body`.
    private func withData<T>(_ command: String, sink: FTPDataSink? = nil,
                             _ body: (Channel, FTPDataSink) async throws -> T) async throws -> T {
        let sink = sink ?? FTPDataSink(handle: nil, progress: nil)
        let (host, port) = try await passiveAddress()
        let tls = protectedData ? try Self.tlsContext() : nil
        let config = config
        let data = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(Int64(config.timeout)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    sink.expectsTLS = tls != nil
                    if let tls { try channel.pipeline.syncOperations.addHandler(config.tlsHandler(context: tls)) }
                    try channel.pipeline.syncOperations.addHandler(sink)
                }
            }
            .connect(to: Self.dataAddress(control: channel.remoteAddress, host: host, port: port)).get()
        do {
            let start = try await self.command(command)
            guard start.code == 125 || start.code == 150 else { throw Self.error(start) }
            let result = try await body(data, sink)
            try await expect(await nextReply(), 226, 250)
            return result
        } catch {
            try? await data.close()
            throw error
        }
    }

    /// Endereço da conexão de dados: o mesmo IP do controle (sem nova resolução de nome, que tentaria IPv6 e
    /// IPv4 em paralelo e criaria dois canais com o mesmo coletor).
    static func dataAddress(control: SocketAddress?, host: String, port: Int) throws -> SocketAddress {
        if let ip = control?.ipAddress { return try SocketAddress(ipAddress: ip, port: port) }
        return try SocketAddress.makeAddressResolvingHost(host, port: port)
    }

    /// Fecha a conexão de dados sem esperar para sempre pelo close_notify do TLS
    /// (alguns servidores nunca respondem quando nada foi enviado).
    static func closeData(_ channel: Channel) async {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.close(promise: promise)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { promise.succeed() }
        _ = try? await promise.futureResult.get()
        timeout.cancel()
    }

    /// LF → CRLF (normaliza CRLF existentes antes, para não virar CRCRLF).
    static func unixToNetwork(_ data: Data, previous: inout UInt8) -> Data {
        var out = Data(capacity: data.count + data.count / 20)
        for byte in data {
            if byte == 10, previous != 13 { out.append(13) }
            out.append(byte)
            previous = byte
        }
        return out
    }

    func list(_ path: String) async throws -> [FileItem] {
        let mlsd = config.useMLSD && features.contains { $0.hasPrefix("MLST") }
        let text: String
        if mlsd {
            text = try await read("MLSD \(path)")
        } else {
            // Como o Cyberduck: entra na pasta e lista sem caminho (muitos servidores leem "-a /x" como nome).
            try await expect(await command("CWD \(path)"), 250)
            do { text = try await read("LIST -a") } catch WormlinkError.server { text = try await read("LIST") }
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let items = mlsd ? lines.compactMap { FTPListParser.mlsd($0, in: path) }
                         : lines.compactMap { FTPListParser.list($0, in: path) }
        return items.filter { $0.name != "." && $0.name != ".." }
    }

    private func read(_ command: String) async throws -> String {
        let sink = FTPDataSink(handle: nil, progress: nil)
        return try await withData(command, sink: sink) { _, _ in
            try await sink.finished.get()
            return String(data: sink.collected, encoding: self.config.encoding) ?? String(decoding: sink.collected, as: UTF8.self)
        }
    }

    func download(_ path: String, to local: URL, offset: Int64 = 0, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if offset == 0 || !FileManager.default.fileExists(atPath: local.path) {
            FileManager.default.createFile(atPath: local.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()
        let ascii = config.isASCII(path) && offset == 0
        try await inASCII(ascii) {
            if offset > 0 { try await expect(await command("REST \(offset)"), 350) }
            let sink = FTPDataSink(handle: handle, progress: { progress(offset + $0) })
            sink.asciiToUnix = ascii
            try await withData("RETR \(path)", sink: sink) { channel, _ in
                try await withTaskCancellationHandler {
                    try await sink.finished.get()
                } onCancel: { channel.close(promise: nil) }
            }
        }
    }

    /// TYPE A durante a transferência e TYPE I logo depois, antes de qualquer outro comando.
    private func inASCII(_ ascii: Bool, _ body: () async throws -> Void) async throws {
        guard ascii else { return try await body() }
        _ = try await command("TYPE A")
        do {
            try await body()
        } catch {
            _ = try? await command("TYPE I")
            throw error
        }
        _ = try await command("TYPE I")
    }

    func upload(_ local: URL, to path: String, offset: Int64 = 0, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(offset))
        let ascii = config.isASCII(path) && offset == 0
        try await inASCII(ascii) {
            // Retomada com APPE (acrescentar), como o Cyberduck.
            try await withData(offset > 0 ? "APPE \(path)" : "STOR \(path)") { channel, sink in
                // Fechar antes do fim do handshake TLS (arquivo vazio) faz o servidor descartar o envio.
                try await sink.handshake.get()
                var sent: Int64 = offset
                var previous: UInt8 = 0
                while let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    await BandwidthLimiter.shared.throttle(chunk.count, .upload)
                    // Modo ASCII: fim de linha da rede é CRLF.
                    let payload = ascii ? Self.unixToNetwork(chunk, previous: &previous) : chunk
                    try await channel.writeAndFlush(ByteBuffer(data: payload))
                    sent += Int64(chunk.count)
                    progress(sent)
                }
                await Self.closeData(channel)
            }
        }
    }
}

// MARK: - Handlers

/// Junta as linhas do controle em respostas completas e as entrega a quem espera.
final class FTPReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let encoding: String.Encoding

    init(encoding: String.Encoding = .utf8) { self.encoding = encoding }

    private var bytes: [UInt8] = []
    private var current: [String] = []
    private var ready: [FTPReply] = []
    private var waiters: [EventLoopPromise<FTPReply>] = []
    private(set) var failure: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bytes.append(contentsOf: buffer.readableBytesView)
        while let newline = bytes.firstIndex(of: 10) {
            var lineBytes = bytes[..<newline]
            if lineBytes.last == 13 { lineBytes = lineBytes.dropLast() }
            bytes.removeSubrange(...newline)
            let line = String(bytes: lineBytes, encoding: encoding) ?? String(bytes: lineBytes, encoding: .utf8)
                ?? String(bytes: lineBytes, encoding: .isoLatin1) ?? ""
            accept(line)
        }
    }

    private func accept(_ line: String) {
        current.append(line)
        let first = current[0]
        guard first.count >= 3, let code = Int(first.prefix(3)) else { current.removeAll(); return }
        // Fim da resposta: "123 texto" (ou linha única sem hífen).
        let isMulti = first.dropFirst(3).first == "-"
        let ends = !isMulti || (line.count >= 4 && line.hasPrefix(String(code)) && line.dropFirst(3).first == " ")
        guard ends && (!isMulti || current.count > 1) else { return }
        let reply = FTPReply(code: code, lines: current)
        current.removeAll()
        if waiters.isEmpty { ready.append(reply) } else { waiters.removeFirst().succeed(reply) }
    }

    func next(on loop: EventLoop) -> EventLoopFuture<FTPReply> {
        if !ready.isEmpty { return loop.makeSucceededFuture(ready.removeFirst()) }
        if let failure { return loop.makeFailedFuture(failure) }
        let promise = loop.makePromise(of: FTPReply.self)
        waiters.append(promise)
        // Servidor mudo: desiste depois de 2 minutos em vez de esperar para sempre.
        let timeout = loop.scheduleTask(in: .minutes(2)) { [weak self] in
            guard let self, let i = self.waiters.firstIndex(where: { $0.futureResult === promise.futureResult }) else { return }
            self.waiters.remove(at: i)
            promise.fail(WormlinkError.timedOut)
        }
        promise.futureResult.whenComplete { _ in timeout.cancel() }
        return promise.futureResult
    }

    private func fail(_ error: Error) {
        // Guarda a primeira causa (ex.: erro de TLS) em vez do "conexão fechada" que vem depois.
        if failure == nil { failure = error }
        waiters.forEach { $0.fail(failure ?? error) }
        waiters.removeAll()
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(WormlinkError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }
}

/// Recebe a conexão de dados: grava num arquivo ou acumula (listagens).
final class FTPDataSink: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let handle: FileHandle?
    private let progress: (@Sendable (Int64) -> Void)?
    private(set) var collected = Data()
    private var total: Int64 = 0
    private var promise: EventLoopPromise<Void>?
    private var done = false
    /// Modo ASCII: CRLF → LF ao gravar (um CR no fim do bloco espera o próximo).
    var asciiToUnix = false
    private var pendingCR = false
    private var writeError: Error?

    init(handle: FileHandle?, progress: (@Sendable (Int64) -> Void)?) {
        self.handle = handle
        self.progress = progress
    }

    /// Definido antes de o canal ficar ativo: há TLS nesta conexão de dados?
    var expectsTLS = false
    private var handshakePromise: EventLoopPromise<Void>?

    /// Conclui quando o TLS está pronto (ou imediatamente, sem TLS).
    var handshake: EventLoopFuture<Void> { handshakePromise!.futureResult }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls { handshakePromise?.succeed() }
        context.fireUserInboundEventTriggered(event)
    }

    /// Termina quando o servidor fecha a conexão de dados.
    /// (A promessa nasce em `handlerAdded`, antes de a conexão ser entregue a quem chama.)
    var finished: EventLoopFuture<Void> { promise!.futureResult }

    func handlerAdded(context: ChannelHandlerContext) {
        promise = context.eventLoop.makePromise()
        handshakePromise = context.eventLoop.makePromise()
        if !expectsTLS { handshakePromise?.succeed() }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let handle {
            var bytes = Data(buffer.readableBytesView)
            if asciiToUnix { bytes = convertToUnix(bytes) }
            do { try handle.write(contentsOf: bytes) } catch { writeError = error; context.close(promise: nil) }
        } else {
            collected.append(contentsOf: buffer.readableBytesView)
        }
        total += Int64(buffer.readableBytes)
        progress?(total)
        // Limite de velocidade: para de ler do socket até o relógio liberar.
        if handle != nil {
            let wait = BandwidthLimiter.shared.reserve(buffer.readableBytes, .download)
            if wait > 0 {
                let channel = context.channel
                channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
                    channel.eventLoop.scheduleTask(in: .milliseconds(Int64(wait * 1000))) {
                        channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in channel.read() }
                    }
                }
            }
        }
    }

    private func convertToUnix(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        if pendingCR { if data.first != 10 { out.append(13) }; pendingCR = false }
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 13 {
                let next = data.index(after: index)
                if next == data.endIndex { pendingCR = true } else if data[next] != 10 { out.append(13) }
            } else {
                out.append(byte)
            }
            index = data.index(after: index)
        }
        return out
    }

    func channelInactive(context: ChannelHandlerContext) {
        if pendingCR, let handle { try? handle.write(contentsOf: Data([13])) }
        complete(writeError.map { .failure($0) } ?? .success(()))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Muitos servidores fecham o TLS de dados sem close_notify; os dados já chegaram.
        if let ssl = error as? NIOSSLError, case .uncleanShutdown = ssl { return }
        complete(.failure(error))
        context.close(promise: nil)
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !done else { return }
        done = true
        promise?.completeWith(result)
        handshakePromise?.completeWith(result)   // sem efeito se o handshake já terminou
    }
}
