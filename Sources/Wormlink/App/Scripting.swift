import AppKit
import WormlinkCore

// Comandos AppleScript (Resources/Wormlink.sdef). Rodam na thread principal; os que falam com o servidor
// suspendem o script até terminar e devolvem os erros para ele.

/// Base: acha o servidor pelo nome e roda trabalho assíncrono com o script suspenso.
nonisolated class WormlinkScriptCommand: NSScriptCommand {
    func bookmark(named name: String?) -> Bookmark? {
        guard let name, !name.isEmpty else { fail("Falta o nome do servidor."); return nil }
        let all = BookmarkStore(fileURL: AppModel.currentStoreURL).load()
        guard let found = all.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame })
                ?? all.first(where: { $0.hostname.caseInsensitiveCompare(name) == .orderedSame }) else {
            fail("Nenhum servidor salvo chamado “\(name)”.")
            return nil
        }
        return found
    }

    func fail(_ message: String) {
        scriptErrorNumber = errOSAGeneralError
        scriptErrorString = message
    }

    /// Suspende o script, roda `work` e devolve o resultado (ou o erro) quando terminar.
    func suspend(_ work: @escaping @MainActor @Sendable () async throws -> Any?) -> Any? {
        suspendExecution()
        nonisolated(unsafe) let command = self
        Task { @MainActor in
            do {
                let result = try await work()
                command.resumeExecution(withResult: result)
            } catch {
                command.fail(error.localizedDescription)
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    @MainActor
    static func connect(_ bookmark: Bookmark) async throws -> any FileSystem {
        try await Connector.connect(bookmark, password: Keychain.password(for: bookmark), trust: TrustPrompter.trust)
    }

    static func resolve(_ path: String?, in fs: any FileSystem) -> String {
        guard let path, !path.isEmpty else { return fs.homePath }
        return path.hasPrefix("/") ? RemotePath.normalize(path) : RemotePath.join(fs.homePath, path)
    }
}

@objc(WormlinkServerNamesCommand)
nonisolated final class WormlinkServerNamesCommand: WormlinkScriptCommand {
    override func performDefaultImplementation() -> Any? {
        BookmarkStore(fileURL: AppModel.currentStoreURL).load().map(\.displayName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

@objc(WormlinkConnectCommand)
nonisolated final class WormlinkConnectCommand: WormlinkScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let bookmark = bookmark(named: directParameter as? String) else { return nil }
        MainActor.assumeIsolated { NSApp.activate() }
        if let url = URL(string: "wormlink://bookmark/\(bookmark.id.uuidString)") { NSWorkspace.shared.open(url) }
        return nil
    }
}

@objc(WormlinkListCommand)
nonisolated final class WormlinkListCommand: WormlinkScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let bookmark = bookmark(named: evaluatedArguments?["server"] as? String) else { return nil }
        let path = directParameter as? String
        return suspend {
            let fs = try await Self.connect(bookmark)
            defer { Task { await fs.disconnect() } }
            return try await fs.list(Self.resolve(path, in: fs))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { $0.name + ($0.isDirectory ? "/" : "") }
        }
    }
}

@objc(WormlinkUploadCommand)
nonisolated final class WormlinkUploadCommand: WormlinkScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let bookmark = bookmark(named: evaluatedArguments?["server"] as? String) else { return nil }
        let files: [URL] = (directParameter as? [URL]) ?? (directParameter as? URL).map { [$0] } ?? []
        guard !files.isEmpty else { fail("Nenhum arquivo para enviar."); return nil }
        let path = evaluatedArguments?["path"] as? String
        return suspend {
            let fs = try await Self.connect(bookmark)
            defer { Task { await fs.disconnect() } }
            var copier = Copier(from: LocalFileSystem(), to: fs, skip: TransferSettings.skipRules, resolver: { _, _ in .overwrite },
                                preserveDates: TransferSettings.preserveDates)
            copier.atomicUploads = TransferSettings.atomicUploads
            let folder = Self.resolve(path, in: fs)
            for url in files {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let item = FileItem(path: url.path, isDirectory: values?.isDirectory ?? false, size: values?.fileSize.map(Int64.init))
                try await copier.copy(item, into: folder) { _ in }
            }
            return nil
        }
    }
}

@objc(WormlinkDownloadCommand)
nonisolated final class WormlinkDownloadCommand: WormlinkScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let bookmark = bookmark(named: evaluatedArguments?["server"] as? String) else { return nil }
        guard let remote = directParameter as? String, let destination = evaluatedArguments?["destination"] as? URL else {
            fail("Diga o caminho remoto e a pasta local (to).")
            return nil
        }
        return suspend {
            let fs = try await Self.connect(bookmark)
            defer { Task { await fs.disconnect() } }
            let path = Self.resolve(remote, in: fs)
            guard let item = try await fs.list(RemotePath.parent(path)).first(where: { $0.path == path }) else {
                throw WormlinkError.notFound(path)
            }
            let copier = Copier(from: fs, to: LocalFileSystem(), skip: TransferSettings.skipRules, resolver: { _, _ in .overwrite },
                                preserveDates: TransferSettings.preserveDates)
            try await copier.copy(item, into: destination.path) { _ in }
            return nil
        }
    }
}
