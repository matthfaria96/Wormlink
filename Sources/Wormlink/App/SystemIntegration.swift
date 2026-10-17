import AppKit
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers
import WormlinkCore

/// Serviço do Finder "Enviar com o Wormlink…" (menu Serviços / botão direito em arquivos).
@objc final class WormlinkServices: NSObject {
    @objc func sendWithWormlink(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !files.isEmpty else { return }
        let bookmarks = BookmarkStore(fileURL: AppModel.currentStoreURL).load()
        guard !bookmarks.isEmpty else {
            error.pointee = "Nenhum servidor salvo no Wormlink." as NSString
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = files.count == 1 ? "Enviar “\(files[0].lastPathComponent)” para:" : "Enviar \(files.count) itens para:"
        alert.informativeText = "Os arquivos vão para a pasta inicial do servidor."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        for bookmark in bookmarks { popup.addItem(withTitle: bookmark.displayName) }
        if let last = UserDefaults.standard.string(forKey: "servicesLastBookmark"),
           let index = bookmarks.firstIndex(where: { $0.id.uuidString == last }) { popup.selectItem(at: index) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Enviar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let bookmark = bookmarks[popup.indexOfSelectedItem]
        UserDefaults.standard.set(bookmark.id.uuidString, forKey: "servicesLastBookmark")
        var components = URLComponents(string: "wormlink://upload")!
        components.queryItems = [URLQueryItem(name: "bookmark", value: bookmark.id.uuidString)]
            + files.map { URLQueryItem(name: "file", value: $0.path) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

/// Servidores no Spotlight: digitar o nome abre a conexão no Wormlink.
enum SpotlightIndex {
    static let domain = "app.wormlink.mac.servers"

    static func update(_ bookmarks: [Bookmark]) {
        let items = bookmarks.map { bookmark in
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = bookmark.displayName
            attributes.contentDescription = "\(bookmark.connectionProtocol.displayName) — \(bookmark.hostname.isEmpty ? "Wormlink" : bookmark.hostname)"
            attributes.keywords = [bookmark.hostname, bookmark.username, bookmark.connectionProtocol.displayName, "Wormlink"].filter { !$0.isEmpty }
            return CSSearchableItem(uniqueIdentifier: bookmark.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }
}

/// Handoff: o lado ativo (servidor e pasta) continua em outro Mac com o mesmo iCloud.
enum Handoff {
    static let browsing = "app.wormlink.mac.browsing"

    static func update(_ activity: NSUserActivity, bookmark: Bookmark?, path: String?) {
        guard let bookmark, let path else {
            activity.isEligibleForHandoff = false
            return
        }
        activity.title = "\(bookmark.displayName) — \(RemotePath.name(path).isEmpty ? "/" : RemotePath.name(path))"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.addUserInfoEntries(from: ["bookmark": bookmark.id.uuidString, "path": path])
        activity.needsSave = true
    }
}

/// Liga /usr/local/bin/wormlink à ferramenta dentro do app (pede a senha de administrador).
enum CommandLineTool {
    static var bundled: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/SharedSupport/bin/wormlink")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func install() {
        let alert = NSAlert()
        guard let tool = bundled else {
            alert.messageText = "A ferramenta não está neste app"
            alert.informativeText = "Use o Wormlink gerado pelo build-app.sh."
            alert.runModal()
            return
        }
        let link = "/usr/local/bin/wormlink"
        let quoted = tool.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(quoted)' \(link)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) == -128 { return }   // cancelado
        alert.messageText = error == nil ? "Ferramenta instalada" : "Não foi possível instalar"
        alert.informativeText = error == nil
            ? "Use “wormlink” no Terminal. Exemplos:\n  wormlink servidores\n  wormlink ls \"Meu Servidor:/pasta\"\n  wormlink put arquivo.zip \"Meu Servidor:/\""
            : (error?[NSAppleScript.errorMessage] as? String ?? "")
        alert.runModal()
    }
}
