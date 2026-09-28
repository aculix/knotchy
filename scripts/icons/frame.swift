// swift scripts/icons/frame.swift <screenshot> <out.png>: fits a screenshot into the 1280×800 frame the
// Chrome Web Store requires, on the icon's navy, as a 24-bit PNG. Window captures keep their own shadow.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let shot = NSImage(contentsOfFile: args[1]),
      let image = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: swift scripts/icons/frame.swift <screenshot> <out.png>")
    exit(1)
}
let width = 1280, height = 800, margin: CGFloat = 40
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [CGColor(srgbRed: 0x1C / 255, green: 0x35 / 255, blue: 0x63 / 255, alpha: 1),
              CGColor(srgbRed: 0x0D / 255, green: 0x1A / 255, blue: 0x33 / 255, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
let scale = min((CGFloat(width) - 2 * margin) / CGFloat(image.width), (CGFloat(height) - 2 * margin) / CGFloat(image.height))
let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
ctx.interpolationQuality = .high
ctx.draw(image, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
                           width: size.width, height: size.height))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(args[2])")
