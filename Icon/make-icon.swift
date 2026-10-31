// Draws the SheetFeed app icon: a page feeding out of a compact scanner, with the scan light on it.
// Usage: swift Icon/make-icon.swift <output.png>   (1024×1024 PNG; build-app.sh turns it into AppIcon.icns)
import AppKit
import CoreGraphics

let size = 1024.0
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ path: CGPath, top: CGColor, bottom: CGColor, in rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

// Background tile on Apple's icon grid: 824 pt square, centered, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = roundedRect(tile, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x2563EB))
ctx.fillPath()
ctx.restoreGState()
fillGradient(tilePath, top: color(0x4FA3FF), bottom: color(0x1D4ED8), in: tile)

// Subtle top highlight on the tile.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let sheen = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// Scanner body.
let body = CGRect(x: 214, y: 214, width: 596, height: 190)
let bodyPath = roundedRect(body, 64)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.4))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x1F2937))
ctx.fillPath()
ctx.restoreGState()
fillGradient(bodyPath, top: color(0x4B5563), bottom: color(0x111827), in: body)

// Feed slot along the top of the scanner.
let slot = CGRect(x: 272, y: 352, width: 480, height: 20)
ctx.addPath(roundedRect(slot, 10))
ctx.setFillColor(color(0x030712))
ctx.fillPath()

// Status light.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 16, color: color(0x34D399, 0.9))
ctx.addEllipse(in: CGRect(x: 720, y: 262, width: 30, height: 30))
ctx.setFillColor(color(0x34D399))
ctx.fillPath()
ctx.restoreGState()

// The page, drawn over the scanner and cut off at the middle of the slot, so it comes out of the slot.
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: slot.midY, width: size, height: size))
let page = CGRect(x: 302, y: 300, width: 420, height: 540)
let fold = 92.0
let pagePath = CGMutablePath()
pagePath.move(to: CGPoint(x: page.minX, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
pagePath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
pagePath.addLine(to: CGPoint(x: page.minX, y: page.maxY))
pagePath.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x0B1E5B, 0.35))
ctx.addPath(pagePath)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Folded corner.
let foldPath = CGMutablePath()
foldPath.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
foldPath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 10))
foldPath.addQuadCurve(to: CGPoint(x: page.maxX - fold + 10, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
foldPath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
foldPath.closeSubpath()
fillGradient(foldPath, top: color(0xE2E8F0), bottom: color(0xC3CDDB), in: CGRect(x: page.maxX - fold, y: page.maxY - fold, width: fold, height: fold))

// Lines of text on the page.
let lineWidths = [0.62, 0.86, 0.78, 0.9, 0.55, 0.84, 0.72, 0.88]
ctx.setFillColor(color(0xBFCBDC))
for (i, fraction) in lineWidths.enumerated() {
    let y = page.maxY - 70 - Double(i) * 46
    let maxWidth = (i == 0 ? page.width - fold - 40 : page.width - 120)
    ctx.addPath(roundedRect(CGRect(x: page.minX + 60, y: y, width: maxWidth * fraction, height: 20), 10))
    ctx.fillPath()
}

// Scan light: a thin bright line with a soft glow, just above the slot.
let lightY = slot.maxY + 34
ctx.saveGState()
ctx.addPath(pagePath)
ctx.clip()
let glow = CGGradient(colorsSpace: nil, colors: [color(0x22D3EE, 0), color(0x22D3EE, 0.35), color(0x22D3EE, 0)] as CFArray,
                      locations: [0, 0.5, 1])!
ctx.drawLinearGradient(glow, start: CGPoint(x: 512, y: lightY - 36), end: CGPoint(x: 512, y: lightY + 36), options: [])
ctx.setFillColor(color(0x67E8F9))
ctx.fill(CGRect(x: page.minX, y: lightY - 3, width: page.width, height: 6))
ctx.restoreGState()
ctx.restoreGState()  // the slot clip

// Shadow the slot casts on the page where it emerges.
ctx.saveGState()
ctx.clip(to: CGRect(x: page.minX, y: slot.midY, width: page.width, height: 30))
let lip = CGGradient(colorsSpace: nil, colors: [color(0x0B1220, 0.45), color(0x0B1220, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(lip, start: CGPoint(x: 512, y: slot.midY), end: CGPoint(x: 512, y: slot.midY + 30), options: [])
ctx.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path)")
