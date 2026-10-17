import AppKit
import WormlinkCore

/// Droplets: mini-apps que enviam para um servidor o que for solto sobre eles (como os do Transmit).
enum Droplets {
    /// Gera o applet com `osacompile` (JavaScript for Automation) e o ícone do Wormlink.
    static func create(for bookmark: Bookmark, at destination: URL) throws {
        let id = bookmark.id.uuidString
        let script = """
        // Droplet do Wormlink para “\(bookmark.displayName.replacingOccurrences(of: "\"", with: ""))”.
        function openDocuments(docs) {
            var app = Application.currentApplication();
            app.includeStandardAdditions = true;
            var query = docs.map(function (d) { return "file=" + encodeURIComponent(d.toString()); }).join("&");
            app.openLocation("wormlink://upload?bookmark=\(id)&" + query);
        }
        function run() {
            var app = Application.currentApplication();
            app.includeStandardAdditions = true;
            app.openLocation("wormlink://bookmark/\(id)");
        }
        """
        let source = FileManager.default.temporaryDirectory.appending(path: "wormlink-droplet-\(UUID().uuidString).js")
        try script.write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }

        let compile = Process()
        compile.executableURL = URL(filePath: "/usr/bin/osacompile")
        compile.arguments = ["-l", "JavaScript", "-o", destination.path, source.path]
        let errors = Pipe()
        compile.standardError = errors
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DropletError(message: message.isEmpty ? String(localized: "osacompile falhou.") : message)
        }
        // Ícone do Wormlink no lugar do ícone padrão de script; depois reassina (ad hoc),
        // porque mexer no bundle invalida a assinatura que o osacompile fez.
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            let resources = destination.appending(path: "Contents/Resources")
            try? FileManager.default.removeItem(at: resources.appending(path: "droplet.icns"))
            try? FileManager.default.copyItem(at: icon, to: resources.appending(path: "droplet.icns"))
            try? FileManager.default.removeItem(at: resources.appending(path: "Assets.car"))
            let plist = destination.appending(path: "Contents/Info.plist")
            if let info = NSMutableDictionary(contentsOf: plist) {
                info.removeObject(forKey: "CFBundleIconName")
                info["CFBundleIdentifier"] = "app.wormlink.droplet.\(id)"
                info.write(to: plist, atomically: true)
            }
        }
        try run("/usr/bin/codesign", ["--force", "--sign", "-", destination.path])
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DropletError(message: "\(tool) falhou.") }
    }

    /// Pergunta onde salvar e cria o droplet.
    @MainActor
    static func save(_ bookmark: Bookmark) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(bookmark.displayName).app"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = String(localized: "Arquivos soltos sobre o droplet serão enviados para “\(bookmark.displayName)”.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try create(for: bookmark, at: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Não foi possível criar o droplet")
            alert.runModal()
        }
    }

    struct DropletError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

extension AppModel {
    /// `wormlink://upload?bookmark=<id>&file=<caminho>…`: envia arquivos locais para a pasta remota do servidor,
    /// numa conexão própria que é fechada no fim (usado pelos droplets e pelo app Atalhos).
    func handleUploadURL(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let id = items.first(where: { $0.name == "bookmark" })?.value.flatMap(UUID.init(uuidString:)),
              let bookmark = bookmark(id: id) else { throw WormlinkError.invalidBookmark }
        let files = items.filter { $0.name == "file" }.compactMap(\.value).map { URL(filePath: $0) }
        guard !files.isEmpty else { return }
        let fs = try await Connector.connect(bookmark, password: Keychain.password(for: bookmark), trust: TrustPrompter.trust)
        recordConnection(bookmark)
        let local = files.map { url in
            FileItem(path: url.path, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false,
                     size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init))
        }
        transfers.enqueue(local, from: LocalFileSystem(), to: fs, into: fs.homePath) {
            Task { await fs.disconnect() }
        }
    }
}
