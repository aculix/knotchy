// swift scripts/icons/render.swift <out-dir>; run via scripts/make-icons.sh.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Knot: Decodable {
    let icon: [[[Double]]]
    let iconStroke: Double
}

let args = CommandLine.arguments
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let knot = try JSONDecoder().decode(Knot.self, from: Data(contentsOf: here.appendingPathComponent("knot.json")))
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple's icon shape is close to a superellipse with exponent 5.
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * CGFloat(copysign(pow(abs(c), 2.0 / 5), c))
        let y = r.midY + r.height / 2 * CGFloat(copysign(pow(abs(s), 2.0 / 5), s))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func verticalGradient(_ ctx: CGContext, in rect: CGRect, top: CGColor, bottom: CGColor) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
}

/// The knot as drawn on the icon: `box` is the icon's body, and the knot keeps the icon's margins inside it.
func drawKnot(_ ctx: CGContext, in box: CGRect) {
    let scale = box.width / 100
    let width = knot.iconStroke * scale
    for strand in knot.icon {
        let line = CGMutablePath()
        for (i, p) in strand.enumerated() {
            let point = CGPoint(x: box.minX + p[0] * scale, y: box.minY + p[1] * scale)
            if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        let stroked = line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
        ctx.saveGState()
        ctx.addPath(stroked)
        ctx.clip()
        verticalGradient(ctx, in: box, top: color(0xFFA37A), bottom: color(0xFF7345))
        ctx.restoreGState()
    }
}

func render(size: Int, body: CGRect, shadow: Bool, to url: URL) {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let shape = squircle(body)

    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.028, color: color(0x000000, 0.32))
        ctx.addPath(shape)
        ctx.setFillColor(color(0x132441))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    verticalGradient(ctx, in: body, top: color(0x1C3563), bottom: color(0x0D1A33))
    drawKnot(ctx, in: body)
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// Apple's grid: an 824-point body on a 1024-point canvas.
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let size = points * scale
    let inset = CGFloat(size) * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    render(size: size, body: body, shadow: size >= 64, to: iconset.appendingPathComponent(name))
}

// The Chrome Web Store wants 96 points of art with 16 of padding at 128.
for (size, pad) in [(128, 16.0), (48, 2.0), (32, 1.0), (16, 0.0)] {
    let body = CGRect(x: pad, y: pad, width: Double(size) - 2 * pad, height: Double(size) - 2 * pad)
    render(size: size, body: body, shadow: false, to: out.appendingPathComponent("chrome-\(size).png"))
}
// The disk image window: Finder puts Knotchy at (180, 175) and Applications at (460, 175).
// It's drawn taller than the 400-point window so a slightly taller window never shows an edge, and it's light
// because Finder always draws the file names in black over a background picture, even in dark mode.
func renderBackground(scale: Int, to url: URL) {
    let width = 640, height = 440
    let ctx = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(color(0xF5F5F7))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 272, y: 175))
    arrow.addLine(to: CGPoint(x: 366, y: 175))
    arrow.move(to: CGPoint(x: 356, y: 165))
    arrow.addLine(to: CGPoint(x: 368, y: 175))
    arrow.addLine(to: CGPoint(x: 356, y: 185))
    ctx.addPath(arrow)
    ctx.setStrokeColor(color(0xFF8456))
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let caption = NSAttributedString(string: "Drag Knotchy to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(cgColor: color(0x86868B))!,
    ])
    let size = caption.size()
    caption.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2, y: 300))
    NSGraphicsContext.current = nil

    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
renderBackground(scale: 1, to: out.appendingPathComponent("dmg-background.png"))
renderBackground(scale: 2, to: out.appendingPathComponent("dmg-background@2x.png"))
// Chrome Web Store promo images. The store takes 24-bit PNGs only, hence no alpha.
func renderPromo(width: Int, height: Int, to url: URL) {
    let w = CGFloat(width), h = CGFloat(height), unit = h / 280
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: h)
    ctx.scaleBy(x: 1, y: -1)
    verticalGradient(ctx, in: CGRect(x: 0, y: 0, width: w, height: h), top: color(0x1C3563), bottom: color(0x0D1A33))

    let title = NSAttributedString(string: "Open in Knotchy", attributes: [
        .font: NSFont.systemFont(ofSize: 28 * unit, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    let subtitle = NSAttributedString(string: "Open suspicious links in a\ndisposable, isolated browser.", attributes: [
        .font: NSFont.systemFont(ofSize: 14 * unit, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.72),
    ])
    let knotSide = 140 * unit, gap = 14 * unit, lineGap = 8 * unit
    let left = (w - knotSide - gap - max(title.size().width, subtitle.size().width)) / 2
    drawKnot(ctx, in: CGRect(x: left, y: (h - knotSide) / 2, width: knotSide, height: knotSide))

    let top = (h - title.size().height - lineGap - subtitle.size().height) / 2
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    title.draw(at: CGPoint(x: left + knotSide + gap, y: top))
    subtitle.draw(at: CGPoint(x: left + knotSide + gap, y: top + title.size().height + lineGap))
    NSGraphicsContext.current = nil

    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
renderPromo(width: 440, height: 280, to: out.appendingPathComponent("promo-440x280.png"))
renderPromo(width: 1400, height: 560, to: out.appendingPathComponent("marquee-1400x560.png"))
print("rendered AppIcon.iconset, chrome-{16,32,48,128}.png, dmg-background{,@2x}.png and the store promos into \(out.path)")
