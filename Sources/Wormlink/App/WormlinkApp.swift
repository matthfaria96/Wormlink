import SwiftUI
import WormlinkCore

@main
struct WormlinkApp: App {
    @State private var app = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        WormlinkLogging.configure()
        Notifier.requestPermission()
        TransferSettings.applyBandwidthLimits()
        SMBFileSystem.cleanupStaleMounts()
    }

    var body: some Scene {
        WindowGroup("Wormlink", id: "browser") {
            MainWindow()
                .environment(app)
                .frame(minWidth: 760, minHeight: 460)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    app.reloadFromDisk()
                }
        }
        .defaultSize(width: 1100, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            ToolbarCommands()
            InspectorCommands()
            WormlinkCommands(app: app)
        }

        Window("Transferências", id: "transfers") {
            TransfersView()
                .environment(app)
                .frame(minWidth: 420, minHeight: 260)
        }
        .defaultSize(width: 520, height: 360)

        WindowGroup("Editor", id: "text", for: UUID.self) { $id in
            if let id {
                TextEditorWindow(id: id).environment(app).frame(minWidth: 480, minHeight: 320)
            }
        }
        .defaultSize(width: 760, height: 600)

        Window("Transcript", id: "transcript") {
            TranscriptView()
        }
        .defaultSize(width: 760, height: 420)

        Settings {
            SettingsView().environment(app)
        }
    }
}

struct WormlinkCommands: Commands {
    var app: AppModel
    @FocusedValue(\.windowModel) private var window
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var files: PaneModel? { window?.activeFiles }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Sobre o Wormlink") {
                UserDefaults.standard.set("about", forKey: "settingsTab")
                openSettings()
            }
        }
        CommandGroup(after: .newItem) {
            Button("Nova Aba") {
                TabOpener.parent = NSApp.keyWindow
                openWindow(id: "browser")
            }
            .keyboardShortcut("t")
            Divider()
            Button("Quick Connect…") {
                guard let window else { return }
                let slot = window.right.showingServers || window.right.files == nil ? window.right : window.left
                slot.showingServers = true
                slot.editing = nil
                slot.serversTab = .quickConnect
            }
            .keyboardShortcut("k")
            Button("Desconectar") {
                guard let window else { return }
                Task { for slot in [window.left, window.right] where slot.files?.isLocalConnection == false { await window.disconnect(slot) } }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Nova Pasta…") { NotificationCenter.default.post(name: .wormlinkCreate, object: files?.id, userInfo: ["kind": "folder"]) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(files == nil)
            Button("Novo Arquivo…") { NotificationCenter.default.post(name: .wormlinkCreate, object: files?.id, userInfo: ["kind": "file"]) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(files == nil)
            Button("Novo Cofre Criptografado…") { NotificationCenter.default.post(name: .wormlinkNewVault, object: files?.id) }
                .disabled(files == nil || files?.vault(at: files?.path ?? "/") != nil)
            Button("Renomear…") { NotificationCenter.default.post(name: .wormlinkRename, object: files?.id) }
                .disabled(files?.selection.isEmpty ?? true)
            Button("Obter Informações") { window?.showInspector.toggle() }
                .keyboardShortcut("i")
            Divider()
            Menu("Importar e Exportar Servidores") { ImportMenuItems(app: app) }
            Button("Instalar Chave Pública no Servidor…") { window?.installKeyOn = files?.fs as? SFTPFileSystem }
                .disabled(!(files?.fs is SFTPFileSystem))
        }
        CommandMenu("Ir") {
            Button("Voltar") { Task { await files?.goBack() } }.keyboardShortcut("[")
            Button("Avançar") { Task { await files?.goForward() } }.keyboardShortcut("]")
            Button("Pasta Superior") { Task { await files?.goUp() } }.keyboardShortcut(.upArrow)
            Divider()
            Button("Atualizar") { Task { await files?.reload() } }.keyboardShortcut("r")
            Button("Transferir Seleção para o Outro Lado") { window?.transferSelection(using: app.transfers) }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled((files?.selection.isEmpty ?? true) || window?.otherFiles == nil)
            Button("Sincronizar…") { window?.showSync = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(window?.left.visibleFiles == nil || window?.right.visibleFiles == nil)
            Button(window?.linking == true ? "Desligar Folder Linking" : "Ligar Folder Linking") { window?.toggleLinking() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Mostrar/Ocultar Arquivos Ocultos") { files?.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(PaneModel.Layout.allCases.enumerated()), id: \.element) { index, layout in
                Button("Como \(layout.title)") { files?.layout = layout }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(files == nil)
            }
            Divider()
            Button(window?.singlePane == true ? "Mostrar Dois Painéis" : "Mostrar Um Painel") { window?.singlePane.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Trocar de Lado") { if let window { window.active = window.active == .left ? .right : .left } }
                .keyboardShortcut("\\", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Transferências") {
            Button(app.transfers.activeCount > 0 ? "Pausar Transferências" : "Continuar Transferências") {
                if app.transfers.activeCount > 0 { app.transfers.pauseAll() } else { app.transfers.resumeAll() }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(app.transfers.activeCount == 0 && !app.transfers.transfers.contains { $0.state == .paused })
            Button("Limpar Concluídas") { app.transfers.clearFinished() }
        }
        CommandGroup(before: .windowList) {
            Button("Transferências") { openWindow(id: "transfers") }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Transcript") { openWindow(id: "transcript") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

/// Pergunta antes de sair com transferências em andamento (como o Transmit e o Cyberduck).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = WormlinkServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = ActiveTransfers.count
        guard active > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = active == 1 ? String(localized: "Há uma transferência em andamento") : String(localized: "Há \(active) transferências em andamento")
        alert.informativeText = String(localized: "Se sair agora, elas serão interrompidas. Arquivos parciais podem ser retomados depois.")
        alert.addButton(withTitle: String(localized: "Continuar no Wormlink"))
        alert.addButton(withTitle: String(localized: "Sair Mesmo Assim"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Contagem global para o AppDelegate (atualizada pela fila).
enum ActiveTransfers {
    static var count = 0
}
