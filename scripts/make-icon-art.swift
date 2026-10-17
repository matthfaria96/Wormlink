// Gera as camadas do ícone do Wormlink (PNG 1024×1024, Display P3, fundo transparente)
// para o documento do Icon Composer em Resources/AppIcon.icon.
// Uso: swift scripts/make-icon-art.swift Resources/AppIcon.icon/Assets
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S = 1024.0
let P3 = CGColorSpace(name: CGColorSpace.displayP3)!
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - Geometria

struct V { var x, y: Double }
func + (a: V, b: V) -> V { V(x: a.x + b.x, y: a.y + b.y) }
func - (a: V, b: V) -> V { V(x: a.x - b.x, y: a.y - b.y) }
func * (a: V, k: Double) -> V { V(x: a.x * k, y: a.y * k) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func lerp(_ a: V, _ b: V, _ t: Double) -> V { a + (b - a) * t }
func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
}

/// Boca do buraco de minhoca: elipse com eixo maior `a` (em `u`) e menor `b` (em `v`, ao longo do túnel).
struct Mouth { var c: V; var a: Double; var b: Double }

// Boca A (embaixo, à esquerda) e boca B (em cima, à direita), em coordenadas com y para baixo.
let A = Mouth(c: V(x: 292, y: 632), a: 212, b: 142)
let B = Mouth(c: V(x: 734, y: 396), a: 232, b: 158)
let axis: V = { let d = B.c - A.c; let l = (d.x * d.x + d.y * d.y).squareRoot(); return d * (1 / l) }()
let u = V(x: -axis.y, y: axis.x)   // eixo maior das bocas (perpendicular ao túnel)
let v = axis                        // eixo menor (ao longo do túnel)

func point(_ c: V, _ a: Double, _ b: Double, _ phi: Double) -> V {
    c + u * (a * cos(phi)) + v * (b * sin(phi))
}

/// Seção do túnel em t∈[0,1]: perfil de catenoide (garganta estreita no meio) e leve curvatura.
func section(_ t: Double) -> (c: V, a: Double, b: Double) {
    let k = 1.62
    let p = cosh(k * (2 * t - 1)) / cosh(k)
    let bend = u * (-34 * sin(.pi * t))
    let c = lerp(A.c, B.c, t) + bend
    return (c, lerp(A.a, B.a, t) * p, lerp(A.b, B.b, t) * p)
}

// MARK: - Cores

struct C { var r, g, b: Double }
func mix(_ a: C, _ b: C, _ t: Double) -> C { C(r: lerp(a.r, b.r, t), g: lerp(a.g, b.g, t), b: lerp(a.b, b.b, t)) }
func hex(_ h: UInt32) -> C { C(r: Double(h >> 16 & 255) / 255, g: Double(h >> 8 & 255) / 255, b: Double(h & 255) / 255) }
func cg(_ c: C, _ alpha: Double) -> CGColor { CGColor(colorSpace: P3, components: [c.r, c.g, c.b, max(0, min(1, alpha))])! }

let violet = hex(0x7A3CFF), purple = hex(0xA24DFF), magenta = hex(0xD45BFF)
let pink = hex(0xFF9CE6), blush = hex(0xFFE2F7), white = hex(0xFFFFFF)
let blue = hex(0x3D6BFF), cyan = hex(0x6CC8FF), ice = hex(0xD9F1FF), ink = hex(0x070826)

// MARK: - Aleatório determinístico

var seed: UInt64 = 0x5EED_1A2B
func rnd() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 11) / Double(1 << 53)
}
func rnd(_ a: Double, _ b: Double) -> Double { lerp(a, b, rnd()) }

// MARK: - Canvas

func canvas() -> CGContext {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 16, bytesPerRow: 0,
                        space: P3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.interpolationQuality = .high
    return ctx
}

let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                             .outputColorSpace: P3])

func blurred(_ img: CGImage, _ sigma: Double) -> CGImage {
    let input = CIImage(cgImage: img)
    let out = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
    return ci.createCGImage(out, from: input.extent, format: .RGBAh, colorSpace: P3)!
}

/// Desenha uma imagem já em coordenadas de pixel no contexto invertido.
func paint(_ ctx: CGContext, _ img: CGImage, blend: CGBlendMode = .normal, alpha: Double = 1) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
    ctx.setBlendMode(blend); ctx.setAlpha(alpha)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.restoreGState()
}

func save(_ ctx: CGContext, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("✓ \(name)")
}

func segment(_ ctx: CGContext, _ p: V, _ q: V, _ color: CGColor, _ width: Double) {
    ctx.setStrokeColor(color); ctx.setLineWidth(width)
    ctx.move(to: CGPoint(x: p.x, y: p.y)); ctx.addLine(to: CGPoint(x: q.x, y: q.y)); ctx.strokePath()
}

func ellipsePath(_ c: V, _ a: Double, _ b: Double, steps: Int = 180) -> CGPath {
    let path = CGMutablePath()
    for i in 0...steps {
        let p = point(c, a, b, Double(i) / Double(steps) * 2 * .pi)
        i == 0 ? path.move(to: CGPoint(x: p.x, y: p.y)) : path.addLine(to: CGPoint(x: p.x, y: p.y))
    }
    path.closeSubpath()
    return path
}

// MARK: - Camadas

func point(_ c: V, _ a: Double, _ b: Double, _ phi: Double, rot: Double) -> V {
    let (cr, sr) = (cos(rot), sin(rot))
    let ru = u * cr + v * sr, rv = v * cr - u * sr
    return c + ru * (a * cos(phi)) + rv * (b * sin(phi))
}

/// Fios luminosos que formam o aro de cada portal (onde o Liquid Glass atua).
func drawRims(_ ctx: CGContext, glowOnly: Bool = false) {
    ctx.setBlendMode(.plusLighter)
    for (m, hot) in [(A, 3.55), (B, 0.35)] {   // `hot`: ângulo do lado incandescente de cada aro
        let strands = 64
        for s in 0..<strands {
            let f = Double(s) / Double(strands - 1)
            let d = lerp(-0.06, 0.15, f) + rnd(-0.02, 0.02)
            let a = m.a * (1 + d), b = m.b * (1 + d * 1.2)
            let rot = rnd(-0.07, 0.07)
            let shift = V(x: rnd(-5, 5), y: rnd(-5, 5))
            let phase = rnd(0, 2 * .pi)
            let edge = sin(.pi * f)                          // fios do meio da faixa mais fortes
            let base = rnd(0.07, 0.22) * (0.5 + 0.6 * edge)
            let w = rnd(2.0, 7.5) * (glowOnly ? 2.4 : 1)
            let n = 260
            var prev = point(m.c + shift, a, b, 0, rot: rot)
            for i in 1...n {
                let phi = Double(i) / Double(n) * 2 * .pi
                let p = point(m.c + shift, a, b, phi, rot: rot)
                let heat = pow(max(0, cos(phi - hot)), 3.2) * (0.35 + 0.65 * f)
                let ripple = 0.6 + 0.4 * sin(phi * 3 + phase)
                let front = 0.6 + 0.4 * max(0, sin(phi - 0.4))       // metade da frente mais viva
                let col = mix(mix(violet, magenta, front * 0.7 + f * 0.2), mix(pink, blush, heat), heat)
                let alpha = (base * ripple * front + heat * 0.24) * (glowOnly ? 0.55 : 1)
                segment(ctx, prev, p, cg(col, alpha), w * (0.75 + 0.5 * heat))
                prev = p
            }
        }
        // Filete de luz quase branco no lado incandescente.
        let n = 160
        for k in 0..<2 {
            let a = m.a * (1.10 + Double(k) * 0.03), b = m.b * (1.12 + Double(k) * 0.035)
            var prev = point(m.c, a, b, hot - 1.5)
            for i in 1...n {
                let phi = hot - 1.5 + 3.0 * Double(i) / Double(n)
                let p = point(m.c, a, b, phi)
                let e = sin(.pi * Double(i) / Double(n))
                segment(ctx, prev, p, cg(mix(pink, blush, e), 0.38 * e * e), (glowOnly ? 8 : 2.6) * e + 0.5)
                prev = p
            }
        }
    }
    ctx.setBlendMode(.normal)
}

/// Redemoinho que entra em cada portal (sem vidro, só luz).
func drawSwirls(_ ctx: CGContext) {
    ctx.setBlendMode(.plusLighter)
    for m in [A, B] {
        for _ in 0..<16 {
            let phase = rnd(0, 2 * .pi), turns = rnd(0.8, 1.5)
            let r0 = rnd(0.9, 1.02), r1 = rnd(0.35, 0.6)
            let gain = rnd(0.15, 0.4), w = rnd(1.2, 3.5)
            let n = 220
            var prev = point(m.c, m.a * r0, m.b * r0, phase)
            for i in 1...n {
                let t = Double(i) / Double(n)
                let r = lerp(r0, r1, t * t)
                let phi = phase + turns * 2 * .pi * t
                let p = point(m.c, m.a * r, m.b * r, phi)
                let col = mix(magenta, mix(blue, cyan, t), smooth(0.0, 0.7, t))
                segment(ctx, prev, p, cg(col, gain * (1 - t) * (0.5 + 0.5 * sin(.pi * min(1, t * 3)))), w * (1 - 0.6 * t))
                prev = p
            }
        }
    }
    ctx.setBlendMode(.normal)
}

/// Corpo do túnel: silhueta lisa de ampulheta, para o vidro ter forma limpa.
func drawTunnelBody(_ ctx: CGContext) {
    for i in 0...240 {
        let t = 0.24 + 0.52 * Double(i) / 240
        let s = section(t)
        let mid = sin(.pi * t)
        let col = mix(mix(hex(0x5B2FD6), hex(0x3346E0), mid), hex(0x4C7BFF), pow(mid, 6))
        ctx.setFillColor(cg(col, 1))
        ctx.addPath(ellipsePath(s.c, s.a, s.b, steps: 120)); ctx.fillPath()
    }
    // Some nas pontas (dentro das bocas) e fica translúcido no meio.
    ctx.saveGState()
    ctx.setBlendMode(.destinationIn)
    let g = CGGradient(colorsSpace: P3, colors: [cg(white, 0), cg(white, 0.42), cg(white, 0.42), cg(white, 0)] as CFArray,
                       locations: [0.24, 0.40, 0.60, 0.76])!
    ctx.drawLinearGradient(g, start: CGPoint(x: A.c.x, y: A.c.y), end: CGPoint(x: B.c.x, y: B.c.y), options: [])
    ctx.restoreGState()
}

/// Fluxo de luz que atravessa a garganta.
func drawTunnel(_ ctx: CGContext, glowOnly: Bool = false) {
    ctx.setBlendMode(.plusLighter)
    // Linhas de fluxo ao longo da superfície, com torção leve (espiral).
    let lines = 110
    for l in 0..<lines {
        let phi0 = Double(l) / Double(lines) * 2 * .pi + rnd(-0.05, 0.05)
        let twist = rnd(0.5, 1.1)
        let gain = rnd(0.35, 1.0)
        let width = rnd(0.9, 3.0) * (glowOnly ? 2.2 : 1)
        let n = 160
        var prev: V?
        for i in 0...n {
            let t = 0.03 + 0.94 * Double(i) / Double(n)
            let s = section(t)
            let phi = phi0 + twist * (t - 0.5) * 2.4
            let p = point(s.c, s.a, s.b, phi)
            if let q = prev {
                let front = 0.32 + 0.68 * pow(max(0, sin(phi + 0.35)), 1.5)
                let mid = sin(.pi * t)
                let col = mix(mix(purple, blue, smooth(0.08, 0.38, t) * (1 - smooth(0.62, 0.94, t))), mix(cyan, ice, mid * front), mid * 0.9)
                let rim = pow(abs(cos(phi)), 6) * 0.75 * (1 - pow(mid, 4))      // silhueta do funil
                let alpha = (gain * front * (0.12 + 0.75 * pow(mid, 1.4)) + rim) * (glowOnly ? 0.6 : 1)
                segment(ctx, q, p, cg(col, alpha), width * (0.6 + 0.6 * mid))
            }
            prev = p
        }
    }
    // Feixe central que cruza a garganta.
    let n = 160
    for k in 0..<5 {
        var prev = section(0.06).c
        for i in 1...n {
            let t = 0.06 + 0.88 * Double(i) / Double(n)
            let p = section(t).c + u * (Double(k - 2) * 7 * sin(.pi * t))
            let e = pow(sin(.pi * t), 0.8)
            segment(ctx, prev, p, cg(mix(cyan, white, e), 0.3 * e), (glowOnly ? 40 : 7) * e + 1)
            prev = p
        }
    }
    ctx.setBlendMode(.normal)
}

/// Interior escuro das bocas, com estrelas e o brilho do túnel ao fundo.
func drawInteriors(_ ctx: CGContext) {
    for m in [A, B] {
        ctx.saveGState()
        ctx.addPath(ellipsePath(m.c, m.a * 0.99, m.b * 0.99)); ctx.clip()
        let grad = CGGradient(colorsSpace: P3, colors: [cg(hex(0x1C2C9E), 0.95), cg(hex(0x0B0E4A), 0.97), cg(ink, 0.98)] as CFArray,
                              locations: [0, 0.45, 1])!
        let toward = m.c + axis * (m.c.x < 500 ? 70 : -70)
        ctx.drawRadialGradient(grad, startCenter: CGPoint(x: toward.x, y: toward.y), startRadius: 0,
                               endCenter: CGPoint(x: m.c.x, y: m.c.y), endRadius: m.a * 1.05, options: [.drawsAfterEndLocation])
        ctx.setBlendMode(.plusLighter)
        for _ in 0..<70 {
            let r = rnd().squareRoot() * 0.9, phi = rnd(0, 2 * .pi)
            let p = point(m.c, m.a * r, m.b * r, phi)
            let size = rnd(0.8, 2.6)
            ctx.setFillColor(cg(mix(cyan, white, rnd()), rnd(0.25, 0.9)))
            ctx.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        }
        ctx.restoreGState()
    }
}

// Nebulosa: halo de fundo + brilho difuso dos aros e do túnel + interiores.
seed = 1
let nebula = canvas()
do {
    let halo = canvas()
    halo.setBlendMode(.plusLighter)
    for (c, r, col, a) in [(lerp(A.c, B.c, 0.5), 470.0, purple, 0.34), (A.c, 300.0, violet, 0.38), (B.c, 320.0, violet, 0.38),
                           (lerp(A.c, B.c, 0.5), 200.0, blue, 0.40)] {
        let g = CGGradient(colorsSpace: P3, colors: [cg(col, a), cg(col, 0)] as CFArray, locations: [0, 1])!
        halo.drawRadialGradient(g, startCenter: CGPoint(x: c.x, y: c.y), startRadius: 0, endCenter: CGPoint(x: c.x, y: c.y),
                                endRadius: r, options: [])
    }
    paint(nebula, halo.makeImage()!)
    let glow = canvas()
    seed = 7; drawRims(glow, glowOnly: true)
    seed = 9; drawTunnel(glow, glowOnly: true)
    let g = glow.makeImage()!
    paint(nebula, blurred(g, 34), blend: .plusLighter, alpha: 0.95)
    paint(nebula, blurred(g, 12), blend: .plusLighter, alpha: 0.7)
    seed = 11; drawInteriors(nebula)
}
save(nebula, "nebula.png")

let body = canvas()
drawTunnelBody(body)
save(body, "tunnel-body.png")

seed = 9
let tunnel = canvas()
drawTunnel(tunnel)
paint(tunnel, blurred(tunnel.makeImage()!, 3), blend: .plusLighter, alpha: 0.6)
save(tunnel, "tunnel-flow.png")

seed = 13
let swirl = canvas()
drawSwirls(swirl)
paint(swirl, blurred(swirl.makeImage()!, 4), blend: .plusLighter, alpha: 0.8)
save(swirl, "portals-swirl.png")

seed = 7
let rims = canvas()
drawRims(rims)
paint(rims, blurred(rims.makeImage()!, 2.5), blend: .plusLighter, alpha: 0.7)
save(rims, "portals.png")

// Faíscas: pontos de luz com rastros orbitais finos.
seed = 21
let sparks = canvas()
do {
    let dots: [(V, Double, Double)] = [   // posição, raio, ângulo do rastro
        (V(x: 216, y: 330), 9, 0.0), (V(x: 396, y: 520), 4.5, 0.7), (V(x: 392, y: 722), 7, 2.4),
        (V(x: 616, y: 590), 5, 3.2), (V(x: 584, y: 236), 3.5, 1.4), (V(x: 846, y: 640), 4, 4.4),
    ]
    sparks.setBlendMode(.plusLighter)
    for (p, r, ang) in dots {
        // Rastro curvo que some aos poucos.
        let n = 70, len = r * 26
        var prev = p
        for i in 1...n {
            let t = Double(i) / Double(n)
            let a = ang + t * 1.1
            let q = p + V(x: cos(a), y: sin(a)) * (len * t)
            segment(sparks, prev, q, cg(mix(cyan, purple, t), 0.5 * (1 - t) * (1 - t)), 1.6 * (1 - t) + 0.4)
            prev = q
        }
        let g = CGGradient(colorsSpace: P3, colors: [cg(white, 1), cg(ice, 0.95), cg(blue, 0.55), cg(violet, 0)] as CFArray,
                           locations: [0, 0.35, 0.6, 1])!
        sparks.drawRadialGradient(g, startCenter: CGPoint(x: p.x, y: p.y), startRadius: 0, endCenter: CGPoint(x: p.x, y: p.y),
                                  endRadius: r * 2.6, options: [])
    }
    for _ in 0..<38 {   // poeira estelar ao longo do túnel
        let s = section(rnd(0.15, 0.85))
        let p = point(s.c, s.a * rnd(0.2, 1.5), s.b * rnd(0.2, 1.5), rnd(0, 2 * .pi))
        let size = rnd(1, 3)
        sparks.setFillColor(cg(mix(ice, white, rnd()), rnd(0.35, 0.9)))
        sparks.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
    }
}
save(sparks, "sparks.png")
