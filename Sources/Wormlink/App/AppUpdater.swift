import AppKit
import Sparkle
import SwiftUI

/// Atualizações dentro do app pelo Sparkle, como no Sirena e no Wineup. O feed (SUFeedURL), a chave
/// pública EdDSA (SUPublicEDKey) e a verificação diária ficam no Resources/Info.plist. As versões são
/// assinadas com a chave EdDSA do witchmymac e o app com o certificado witchmymac.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Falso enquanto uma verificação ou instalação já está em andamento.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private init() {}

    /// Liga o agendador do Sparkle (verificação diária). Uma vez, ao abrir o app.
    /// Cópias de teste (outro bundle id) não verificam, a não ser com WORMLINK_UPDATES=1.
    func start() {
        guard controller == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "app.wormlink.mac" || env["WORMLINK_UPDATES"] != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
        controller.startUpdater()
    }

    /// "Verificar Atualizações…": sempre mostra um resultado, mesmo "Você já está atualizado".
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Item do menu do app e botão do Sobre: desabilitado enquanto já há uma verificação em andamento.
struct CheckForUpdatesButton: View {
    private var updater = AppUpdater.shared

    var body: some View {
        Button("Verificar Atualizações…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
