import SwiftUI
import UniformTypeIdentifiers
import WormlinkCore

extension Color {
    /// Violeta dos portais do ícone.
    static let wormlink = Color(red: 0.55, green: 0.36, blue: 1.0)
}

extension ServerColor {
    var color: Color {
        switch self {
        case .violet: .wormlink
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .graphite: .gray
        }
    }
}

/// Ícone de um servidor: bloco arredondado na cor escolhida, com o símbolo e um brilho de vidro.
struct ServerIconView: View {
    var icon: ServerIcon
    var color: ServerColor
    var size: CGFloat

    init(_ bookmark: Bookmark, size: CGFloat) {
        icon = bookmark.icon
        color = bookmark.color
        self.size = size
    }

    init(icon: ServerIcon, color: ServerColor, size: CGFloat) {
        self.icon = icon
        self.color = color
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(systemName: icon.symbolName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.02)
            .frame(width: size, height: size)
            .background(color.color.gradient, in: shape)
            .overlay {
                // Reflexo e borda clara, como as superfícies de vidro do sistema.
                shape.fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                shape.strokeBorder(.white.opacity(0.25), lineWidth: max(0.5, size / 64))
            }
    }
}

/// Aba com sublinhado na cor de destaque ("Servidores" | "Quick Connect").
struct UnderlineTab: View {
    var title: String
    var symbol: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.wormlink : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Color.wormlink : .clear).frame(height: 2)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Botão só com ícone, discreto, usado nas barras dos painéis.
struct BarButton: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Ícones do sistema por tipo de arquivo, em cache por extensão e tamanho.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem, size: CGFloat = 16) -> NSImage {
        let ext = item.isDirectory ? "/folder" : (item.name.split(separator: ".").count > 1 ? String(item.name.split(separator: ".").last!).lowercased() : "")
        let key = "\(ext)@\(size)"
        if let image = cache[key] { return image }
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: size, height: size)
        cache[key] = image
        return image
    }

    static func kind(of item: FileItem) -> String {
        if item.isDirectory { return "Pasta" }
        if item.isSymlink { return "Link simbólico" }
        let ext = (item.name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.localizedDescription ?? "Documento"
    }
}

extension Date {
    /// "13/10/26, 23:13", como a coluna Data do Transmit.
    var shortStamp: String {
        formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

/// Itens arrastados de um painel para o outro.
nonisolated struct PaneDrag: Codable, Transferable {
    let pane: UUID
    let paths: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wormlinkItems)
    }
}

extension UTType {
    nonisolated static let wormlinkItems = UTType(exportedAs: "app.wormlink.items")
}

/// Dá acesso à `NSWindow` que hospeda a view (abas nativas).
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HostView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HostView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
