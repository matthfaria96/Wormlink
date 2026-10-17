// Wormlink: retomada de sessão TLS do lado do cliente.
// FTPS (vsftpd, ProFTPD, FileZilla Server) exige que cada conexão de dados retome a sessão TLS da conexão de
// controle. O cache guarda a primeira sessão recebida e toda conexão nova criada pelo contexto a retoma.

@_implementationOnly import CNIOBoringSSL
import NIOConcurrencyHelpers

public final class NIOSSLClientSessionCache: @unchecked Sendable {
    private let lock = NIOLock()
    private var session: OpaquePointer?

    public init() {}

    /// Já existe uma sessão para retomar?
    public var hasSession: Bool { lock.withLock { session != nil } }

    /// Fica com a primeira sessão (a da conexão de controle). Devolve true se assumiu a referência.
    func offer(_ newSession: OpaquePointer) -> Bool {
        lock.withLock {
            guard session == nil else { return false }
            session = newSession
            return true
        }
    }

    /// Aplica a sessão guardada a uma conexão nova, antes do handshake.
    func apply(to ssl: OpaquePointer) {
        lock.withLock {
            guard let session else { return }
            CNIOBoringSSL_SSL_set_session(ssl, session)
        }
    }

    deinit {
        if let session { CNIOBoringSSL_SSL_SESSION_free(session) }
    }
}

/// Chamado pelo BoringSSL a cada sessão nova (no TLS 1.3, quando o ticket chega depois do handshake).
internal func wormlinkNewSessionCallback(_ ssl: OpaquePointer?, _ session: OpaquePointer?) -> CInt {
    guard let ssl, let session,
          let connectionPointer = CNIOBoringSSL_SSL_get_ex_data(ssl, sslConnectionExDataIndex) else { return 0 }
    let connection = Unmanaged<SSLConnection>.fromOpaque(connectionPointer).takeUnretainedValue()
    guard let cache = connection.parentContext.clientSessionCache else { return 0 }
    // 1 = o cache ficou com a referência; 0 = o BoringSSL libera.
    return cache.offer(session) ? 1 : 0
}
