// Gera a camada de arte do ícone do Wormlink para o documento do Icon Composer
// em Resources/AppIcon.icon, a partir da ilustração original em Resources/AppIcon-source.png.
//
// A ilustração vem pintada sobre um fundo verde quase preto. O script remove esse fundo
// ("cor para alfa": cada pixel vira a cor que, composta sobre o fundo, reproduz o original),
// de modo que os brilhos continuam suaves e sem halo, e o fundo passa a ser o preenchimento
// em gradiente do icon.json. Depois recentraliza e reduz a arte para caber na grade do
// ícone do macOS (o Icon Composer aplica a máscara arredondada; nada de cantos ou sombra aqui).
//
// Uso: swift scripts/make-icon-art.swift Resources/AppIcon-source.png Resources/AppIcon.icon/Assets
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let srcPath = args.count > 1 ? args[1] : "Resources/AppIcon-source.png"
let outDir = args.count > 2 ? args[2] : "Resources/AppIcon.icon/Assets"

let canvas = 1024
/// Fração da tela ocupada pelo maior lado da arte visível (alfa ≥ `bboxAlpha`).
let fill = 0.90
let bboxAlpha = 0.30
/// Cor do fundo da ilustração (sRGB 0–255), medida nos cantos.
let backdrop: (r: Double, g: Double, b: Double) = (0, 14, 0)
/// Zona morta: variações do fundo (vinheta, ruído de compressão) abaixo disto viram transparência total.
let deadZone = 0.035

// MARK: - Leitura (RGBA 8 bits em sRGB)

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("não consegui ler \(srcPath)")
}
let w = image.width, h = image.height
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
var px = [UInt8](repeating: 0, count: w * h * 4)
px.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}

// MARK: - Cor para alfa

func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
}

let B = [backdrop.r / 255, backdrop.g / 255, backdrop.b / 255]
var out = [Float](repeating: 0, count: w * h * 4)   // RGBA pré-multiplicado, 0–1
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let C = [Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255]
        // Alfa mínimo que explica o pixel como "cor sobre o fundo", canal a canal.
        var a = 0.0
        for k in 0..<3 {
            if C[k] > B[k] {
                a = max(a, (C[k] - B[k]) / (1 - B[k]))
            } else if C[k] < B[k] {
                // Mais escuro que o fundo (contornos pretos): o fundo é tão escuro que basta uma rampa curta.
                a = max(a, smooth(0.15, 1, (B[k] - C[k]) / B[k]))
            }
        }
        a = max(0, (a - deadZone) / (1 - deadZone))
        guard a > 0 else { continue }
        for k in 0..<3 {
            // Cor de primeiro plano F com C = F·a + B·(1−a), já pré-multiplicada (F·a).
            let fa = min(a, max(0, C[k] - B[k] * (1 - a)))
            out[i + k] = Float(fa)
        }
        out[i + 3] = Float(a)
        if a >= bboxAlpha {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}

// MARK: - Enquadramento na grade do ícone

let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
let scale = Double(canvas) * fill / max(bw, bh)
let cx = Double(minX + maxX + 1) / 2, cy = Double(minY + maxY + 1) / 2
print(String(format: "arte visível: %.0f×%.0f em (%d,%d); escala %.3f", bw, bh, minX, minY, scale))

// 16 bits por canal para não serrilhar os brilhos fracos.
var words = [UInt16](repeating: 0, count: w * h * 4)
for i in 0..<(w * h * 4) { words[i] = UInt16(max(0, min(65535, (out[i] * 65535).rounded()))) }
let provider = CGDataProvider(data: words.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!
let layer = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: sRGB,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                             | CGBitmapInfo.byteOrder16Little.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!

let P3 = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 16, bytesPerRow: 0, space: P3,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
ctx.interpolationQuality = .high
// Coordenadas do CG com y para cima: o centro da arte (y para baixo na imagem) vai para o centro da tela.
let dw = Double(w) * scale, dh = Double(h) * scale
let ox = Double(canvas) / 2 - cx * scale
let oy = Double(canvas) / 2 - (Double(h) - cy) * scale
ctx.draw(layer, in: CGRect(x: ox, y: oy, width: dw, height: dh))

try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let url = URL(fileURLWithPath: outDir).appendingPathComponent("artwork.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("não consegui gravar \(url.path)") }
print("gravado \(url.path)")
