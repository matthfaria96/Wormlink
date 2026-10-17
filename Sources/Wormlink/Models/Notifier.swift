import AppKit
import UserNotifications

/// Avisa no Central de Notificações quando uma transferência termina com o app em segundo plano.
enum Notifier {
    /// Fora de um .app (binário de depuração) a Central de Notificações lança exceção.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func transferFinished(_ transfer: Transfer) {
        guard available, !NSApp.isActive, UserDefaults.standard.object(forKey: "notifyTransfers") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = transfer.kind == .sync ? String(localized: "Sincronização concluída") : String(localized: "Transferência concluída")
        content.body = "\(transfer.title) → \(transfer.destination)"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: transfer.id.uuidString, content: content, trigger: nil))
    }
}
