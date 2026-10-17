import AppKit
import SwiftUI
import WormlinkCore

/// Selo colorido de cada protocolo e serviço (quadrado arredondado, símbolo branco, brilho de vidro),
/// na mesma família dos ícones de servidor.
struct ProtocolBadge: View {
    let style: Style
    var size: CGFloat = 16

    struct Style: Hashable {
        let symbol: String
        let top: Color
        let bottom: Color
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.56, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: size * 0.03, y: size * 0.02)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
                shape.strokeBorder(.white.opacity(0.22), lineWidth: max(0.5, size / 48))
            }
    }

    // MARK: Paleta

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    private static func style(_ symbol: String, _ top: UInt32, _ bottom: UInt32) -> Style {
        Style(symbol: symbol, top: hex(top), bottom: hex(bottom))
    }

    static func style(for proto: ConnectionProtocol) -> Style {
        switch proto {
        case .sftp: style("terminal.fill", 0x4CC22A, 0x28851B)   // verde do app: é o primeiro e o padrão
        case .ftp: style("arrow.up.arrow.down", 0x4A9DF5, 0x1F64C7)
        case .ftps: style("lock.fill", 0x3B7BE8, 0x1A47A8)
        case .webdav: style("globe", 0xF5A33B, 0xD6721A)
        case .webdavs: style("globe.badge.chevron.backward", 0xEF8A2F, 0xB8520F)
        case .smb: style("externaldrive.fill", 0x8A96A8, 0x55606F)
        case .s3: style("shippingbox.fill", 0xF7A23A, 0xE0631C)
        case .b2: style("flame.fill", 0xF0524A, 0xB8211C)
        case .azure: style("cloud.fill", 0x3AA0F0, 0x0B63C4)
        case .swift: style("bird.fill", 0xE95A5A, 0xA32D3A)
        case .dropbox: style("archivebox.fill", 0x3D8BFF, 0x0050E0)
        case .box: style("cube.fill", 0x2E8BEA, 0x0A5BC0)
        case .googleDrive: style("triangle.fill", 0x34B566, 0x1A8A45)
        case .oneDrive: style("cloud.fill", 0x2F8FE8, 0x0A5FB8)
        case .sharePoint: style("person.2.fill", 0x18A3A6, 0x036B6E)
        }
    }

    /// Serviços prontos: o símbolo do protocolo na cor da marca.
    static func style(for preset: ConnectionPreset) -> Style {
        let base = style(for: preset.connectionProtocol)
        let colors: (UInt32, UInt32)? = switch preset.id {
        case "wasabi": (0x3FC35A, 0x1E8C38)
        case "r2": (0xF8A33E, 0xE36F17)
        case "spaces": (0x2E8DF7, 0x0B5FD0)
        case "gcs": (0x5B9BF2, 0x2F6FD6)
        case "linode": (0x3CC27A, 0x1B8E50)
        case "scaleway": (0x8B5CF0, 0x5A2FC2)
        case "hetzner-s3", "storagebox": (0xE84A4A, 0xB01E25)
        case "dreamobjects": (0x34A3E6, 0x1572B5)
        case "minio": (0xE0485A, 0xA8213A)
        case "rackspace": (0xD8343A, 0x9E1A20)
        case "nextcloud": (0x2C9CE8, 0x0067B8)
        case "owncloud": (0x3A5C9E, 0x1E3A73)
        default: nil
        }
        guard let colors else { return base }
        return style(base.symbol, colors.0, colors.1)
    }

    /// O selo do que o favorito usa: o serviço pronto, se houver, ou o protocolo.
    static func style(for bookmark: Bookmark) -> Style {
        if let id = bookmark.preset, let preset = PresetStore.all.first(where: { $0.id == id }) { return style(for: preset) }
        return style(for: bookmark.connectionProtocol)
    }

    // MARK: Imagem para menus

    private static var cache: [Style: NSImage] = [:]

    /// Menus do macOS pintam símbolos numa cor só; uma imagem pronta (não "template") mantém as cores.
    static func image(_ style: Style, size: CGFloat = 16) -> NSImage {
        if let cached = cache[style] { return cached }
        let renderer = ImageRenderer(content: ProtocolBadge(style: style, size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        cache[style] = image
        return image
    }
}
