import Foundation

/// Limite de velocidade compartilhado por todas as transferências (como o "Bandwidth" do Cyberduck).
/// Cada direção tem um relógio virtual: reservar N bytes empurra o próximo horário livre em N/limite segundos.
public final class BandwidthLimiter: @unchecked Sendable {
    public enum Direction: Sendable { case upload, download }

    public static let shared = BandwidthLimiter()
    private let lock = NSLock()
    private var limits: [Direction: Double] = [:]
    private var nextFree: [Direction: Date] = [:]
    /// Folga para rajadas curtas (sem isso, blocos pequenos esperariam à toa).
    static let burst: TimeInterval = 0.25

    /// Bytes por segundo (0 = sem limite).
    public func setLimit(_ bytesPerSecond: Int64, for direction: Direction) {
        lock.withLock {
            limits[direction] = bytesPerSecond > 0 ? Double(bytesPerSecond) : nil
            nextFree[direction] = nil
        }
    }

    public func limit(for direction: Direction) -> Int64 { lock.withLock { Int64(limits[direction] ?? 0) } }

    /// Reserva `bytes` e devolve quanto esperar antes de seguir.
    func reserve(_ bytes: Int, _ direction: Direction) -> TimeInterval {
        lock.withLock {
            guard let rate = limits[direction], bytes > 0 else { return 0 }
            let now = Date()
            let start = max(nextFree[direction] ?? now, now)
            let end = start.addingTimeInterval(Double(bytes) / rate)
            nextFree[direction] = end
            return max(0, end.timeIntervalSince(now) - Self.burst)
        }
    }

    public func throttle(_ bytes: Int, _ direction: Direction) async {
        let wait = reserve(bytes, direction)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    func throttleBlocking(_ bytes: Int, _ direction: Direction) {
        let wait = reserve(bytes, direction)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    var isLimitingUploads: Bool { lock.withLock { limits[.upload] != nil } }
}

/// Corpo de requisição HTTP lido do arquivo respeitando o limite de envio.
final class ThrottledFileStream: InputStream, @unchecked Sendable {
    private let handle: FileHandle
    private var status: Stream.Status = .notOpen

    init?(fileAt url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        super.init(data: Data())
    }

    override func open() { status = .open }
    override func close() { try? handle.close(); status = .closed }
    override var streamStatus: Stream.Status { status }
    override var hasBytesAvailable: Bool { status == .open }
    override var streamError: Error? { nil }
    override var delegate: StreamDelegate? { get { nil } set {} }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard let data = try? handle.read(upToCount: min(len, 64 * 1024)), !data.isEmpty else {
            status = .atEnd
            return 0
        }
        BandwidthLimiter.shared.throttleBlocking(data.count, .upload)
        data.copyBytes(to: buffer, count: data.count)
        return data.count
    }
}

extension URLRequest {
    /// Com limite de envio ativo, troca o upload de arquivo por um corpo em fluxo limitado.
    mutating func useThrottledBody(from file: URL) -> Bool {
        guard BandwidthLimiter.shared.isLimitingUploads, let stream = ThrottledFileStream(fileAt: file) else { return false }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        setValue(String(size), forHTTPHeaderField: "Content-Length")
        httpBodyStream = stream
        return true
    }
}
