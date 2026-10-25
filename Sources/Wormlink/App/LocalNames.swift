import Foundation

/// Nomes do Mac e do usuário mostrados na interface. Em depuração, WORMLINK_PREVIEW_MAC_NAME e
/// WORMLINK_PREVIEW_USER trocam os nomes reais, para capturas de tela sem dados pessoais.
enum LocalNames {
    static var mac: String? {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_MAC_NAME"] { return name }
        #endif
        return Host.current().localizedName
    }

    static var user: String {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["WORMLINK_PREVIEW_USER"] { return name }
        #endif
        return NSUserName()
    }
}
