import Foundation
import Network
import dnssd
import CryptoKit

/// Servidores anunciados na rede local (Bonjour), como a lista "Bonjour" do Cyberduck e do Transmit.
/// O NWBrowser encontra os serviços; o DNSServiceResolve dá o nome do computador e a porta sem abrir conexão.
@MainActor
@Observable
public final class BonjourBrowser {
    public private(set) var servers: [Bookmark] = []
    private var browsers: [NWBrowser] = []
    private var resolvers: [String: Resolver] = [:]
    private var found: [String: Bookmark] = [:]

    /// Tipos de serviço anunciados e o protocolo correspondente.
    public static let serviceTypes: [(type: String, protocol: ConnectionProtocol)] = [
        ("_sftp-ssh._tcp", .sftp), ("_ssh._tcp", .sftp), ("_ftp._tcp", .ftp),
        ("_webdav._tcp", .webdav), ("_webdavs._tcp", .webdavs), ("_smb._tcp", .smb),
    ]

    public init() {}

    public var isRunning: Bool { !browsers.isEmpty }

    public func start() {
        guard browsers.isEmpty else { return }
        for (type, proto) in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.update(results, type: type, proto: proto) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        resolvers.values.forEach { $0.cancel() }
        resolvers = [:]
        found = [:]
        servers = []
    }

    private func update(_ results: Set<NWBrowser.Result>, type: String, proto: ConnectionProtocol) {
        var current = Set<String>()
        for result in results {
            guard case .service(let name, _, let domain, _) = result.endpoint else { continue }
            let key = Self.key(name: name, type: type)
            current.insert(key)
            guard found[key] == nil, resolvers[key] == nil else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            let resolver = Resolver(name: name, type: type, domain: domain) { [weak self] host, port in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resolvers[key] = nil
                    guard let host else { return }
                    self.found[key] = Self.bookmark(name: name, type: type, proto: proto, host: host, port: port, txt: txt)
                    self.publish()
                }
            }
            resolvers[key] = resolver
            resolver.start()
        }
        // Serviços que sumiram da rede.
        let suffix = "|" + type
        for key in found.keys where key.hasSuffix(suffix) && !current.contains(key) { found[key] = nil }
        for key in resolvers.keys where key.hasSuffix(suffix) && !current.contains(key) { resolvers.removeValue(forKey: key)?.cancel() }
        publish()
    }

    private func publish() {
        // Um Mac anuncia _ssh e _sftp-ssh; mostra um só.
        var seen = Set<String>()
        servers = found.values
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .filter { seen.insert("\($0.connectionProtocol.rawValue)|\($0.hostname)|\($0.port)").inserted }
    }

    static func key(name: String, type: String) -> String { name + "|" + type }

    /// Favorito com id estável (o mesmo serviço sempre gera o mesmo UUID), para a seleção sobreviver às atualizações.
    nonisolated static func bookmark(name: String, type: String, proto: ConnectionProtocol, host: String, port: Int,
                                     txt: [String: String]) -> Bookmark {
        let digest = Array(Insecure.MD5.hash(data: Data((name + "|" + type).utf8)))
        let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6] & 0x0F | 0x30,
                               digest[7], digest[8] & 0x3F | 0x80, digest[9], digest[10], digest[11], digest[12], digest[13],
                               digest[14], digest[15]))
        var hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
        if hostname.isEmpty { hostname = name }
        var bookmark = Bookmark(id: uuid, nickname: name, connectionProtocol: proto, hostname: hostname, port: port,
                                username: txt["u"] ?? "", path: txt["path"] ?? "")
        bookmark.comment = "Bonjour"
        bookmark.icon = .default(for: proto)
        return bookmark
    }

    /// Resolução de um serviço com o dns_sd (fila principal).
    final class Resolver: @unchecked Sendable {
        private var ref: DNSServiceRef?
        private let name: String, type: String, domain: String
        private let completion: (String?, Int) -> Void
        private var finished = false

        init(name: String, type: String, domain: String, completion: @escaping (String?, Int) -> Void) {
            self.name = name
            self.type = type
            self.domain = domain
            self.completion = completion
        }

        func start() {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = DNSServiceResolve(&ref, 0, 0, name, type, domain, { _, _, _, error, _, hostTarget, port, _, _, context in
                guard let context else { return }
                let resolver = Unmanaged<Resolver>.fromOpaque(context).takeUnretainedValue()
                let host = error == kDNSServiceErr_NoError ? hostTarget.map { String(cString: $0) } : nil
                resolver.finish(host, Int(UInt16(bigEndian: port)))
            }, context)
            guard status == kDNSServiceErr_NoError, let ref else { finish(nil, 0); return }
            DNSServiceSetDispatchQueue(ref, .main)
            // Sem resposta em 5 s: desiste (o serviço pode ter sumido).
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(nil, 0) }
        }

        private func finish(_ host: String?, _ port: Int) {
            guard !finished else { return }
            finished = true
            cancel()
            completion(host, port)
        }

        func cancel() {
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
        }

        deinit { cancel() }
    }
}
