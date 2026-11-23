// Draws the Photo Drop app icon and writes a macOS asset catalog.
// Usage: swift Tools/make_icon.swift <output-folder>

import AppKit
import SwiftUI
import UniformTypeIdentifiers

let designSize: CGFloat = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    return CGColor(colorSpace: sRGB, components: [red, green, blue, alpha])!
}

func smoothRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

struct IconRenderer {
    let ctx: CGContext
    let pixels: Int

    var scale: CGFloat { CGFloat(pixels) / designSize }
    var isSmall: Bool { pixels <= 32 }

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tileRadius: CGFloat = 185.4

    let tilt: CGFloat = -7 * .pi / 180

    // Small sizes drop the fine detail and enlarge what is left.
    var printCenter: CGPoint { isSmall ? CGPoint(x: 512, y: 452) : CGPoint(x: 512, y: 500) }
    var printSize: CGSize { isSmall ? CGSize(width: 500, height: 456) : CGSize(width: 450, height: 410) }
    var printBorder: CGFloat { isSmall ? 58 : 36 }
    var trayFront: CGRect {
        isSmall ? CGRect(x: 196, y: 636, width: 632, height: 180) : CGRect(x: 222, y: 664, width: 580, height: 154)
    }
    var trayBack: CGRect {
        CGRect(x: trayFront.minX + 30, y: trayFront.minY - 34, width: trayFront.width - 60, height: 150)
    }

    func draw() {
        drawTile()
        if !isSmall { drawMotionStreaks() }
        drawTrayBack()
        drawPrint()
        drawTrayFront()
    }

    // Shadow sizes ignore the context's scale, so they are scaled by hand.
    func withShadow(dy: CGFloat, blur: CGFloat, alpha: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale,
                      color: rgb(0x0A1030, alpha: alpha))
        body()
        ctx.restoreGState()
    }

    func fill(_ path: CGPath, _ color: CGColor) {
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    func fill(_ path: CGPath, top: CGColor, bottom: CGColor) {
        let box = path.boundingBoxOfPath
        let gradient = CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: nil)!
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY),
                               end: CGPoint(x: box.midX, y: box.maxY), options: [])
        ctx.restoreGState()
    }

    func drawTile() {
        let shape = smoothRoundedRect(tile, radius: tileRadius)
        withShadow(dy: 10, blur: 20, alpha: 0.32) { fill(shape, rgb(0x3D50D8)) }
        fill(shape, top: rgb(0x38B8DC), bottom: rgb(0x3D50D8))

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let glow = CGGradient(colorsSpace: sRGB,
                              colors: [rgb(0xFFFFFF, alpha: 0.28), rgb(0xFFFFFF, alpha: 0)] as CFArray,
                              locations: nil)!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 160), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 160), endRadius: 620, options: [])
        ctx.restoreGState()
    }

    func drawMotionStreaks() {
        let topEdgeY = printCenter.y - printSize.height / 2
        let streaks: [(dx: CGFloat, length: CGFloat)] = [(-118, 84), (0, 132), (118, 84)]
        for streak in streaks {
            let bottom = topEdgeY + streak.dx * tan(tilt) - 30
            let bar = CGRect(x: printCenter.x + streak.dx - 14, y: bottom - streak.length,
                             width: 28, height: streak.length)
            fill(CGPath(roundedRect: bar, cornerWidth: 14, cornerHeight: 14, transform: nil),
                 top: rgb(0xFFFFFF, alpha: 0.05), bottom: rgb(0xFFFFFF, alpha: 0.8))
        }
    }

    func drawTrayBack() {
        fill(smoothRoundedRect(trayBack, radius: 40), top: rgb(0x161D52), bottom: rgb(0x1A2260))
    }

    func drawPrint() {
        ctx.saveGState()
        ctx.translateBy(x: printCenter.x, y: printCenter.y)
        ctx.rotate(by: tilt)

        let paper = CGRect(x: -printSize.width / 2, y: -printSize.height / 2,
                           width: printSize.width, height: printSize.height)
        let paperShape = smoothRoundedRect(paper, radius: 30)
        withShadow(dy: 14, blur: 32, alpha: 0.38) { fill(paperShape, rgb(0xFFFFFF)) }
        fill(paperShape, top: rgb(0xFFFFFF), bottom: rgb(0xEEF1F8))

        let window = paper.insetBy(dx: printBorder, dy: printBorder)
        ctx.addPath(smoothRoundedRect(window, radius: 10))
        ctx.clip()
        drawLandscape(in: window)
        ctx.restoreGState()
    }

    func drawLandscape(in window: CGRect) {
        let w = window.width, h = window.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: window.minX + x * w, y: window.minY + y * h)
        }
        func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: center.x - rx * w, y: center.y - ry * h,
                                     width: 2 * rx * w, height: 2 * ry * h), transform: nil)
        }

        fill(CGPath(rect: window, transform: nil), top: rgb(0xFFE07A), bottom: rgb(0xFF8E5E))
        let sunRadius: CGFloat = isSmall ? 0.17 : 0.14
        let sun = point(0.68, 0.30)
        if !isSmall {
            fill(ellipse(center: sun, rx: sunRadius * 1.45, ry: sunRadius * 1.45 * w / h), rgb(0xFFFBEA, alpha: 0.35))
        }
        fill(ellipse(center: sun, rx: sunRadius, ry: sunRadius * w / h), rgb(0xFFFBEA))
        fill(ellipse(center: point(0.20, 1.05), rx: 0.56, ry: 0.60), rgb(0x2FA89A))
        fill(ellipse(center: point(0.80, 1.14), rx: 0.64, ry: 0.60), rgb(0x1B6E7C))
    }

    func drawTrayFront() {
        let shape = smoothRoundedRect(trayFront, radius: 60)
        withShadow(dy: -8, blur: 22, alpha: 0.45) { fill(shape, rgb(0x232C7A)) }
        fill(shape, rgb(0x6D7BE0))

        // The face sits a little lower than the shape, leaving a lit rim along the top.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        fill(smoothRoundedRect(trayFront.offsetBy(dx: 0, dy: 8), radius: 60),
             top: rgb(0x3A47B4), bottom: rgb(0x1D2569))
        ctx.restoreGState()

        if isSmall { return }
        let center = CGPoint(x: trayFront.midX, y: trayFront.midY + 6)
        ctx.move(to: CGPoint(x: center.x - 52, y: center.y - 20))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + 20))
        ctx.addLine(to: CGPoint(x: center.x + 52, y: center.y - 20))
        ctx.setStrokeColor(rgb(0xFFFFFF, alpha: 0.92))
        ctx.setLineWidth(28)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
}

func renderIcon(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Flip so the design is laid out with y pointing down.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: CGFloat(pixels) / designSize, y: -CGFloat(pixels) / designSize)
    IconRenderer(ctx: ctx, pixels: pixels).draw()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift Tools/make_icon.swift <output-folder>\n".utf8))
    exit(1)
}

let outputFolder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let catalog = outputFolder.appendingPathComponent("Assets.xcassets", isDirectory: true)
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var imageEntries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 1 ? "" : "@2x"
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try writePNG(renderIcon(pixels: points * factor), to: iconSet.appendingPathComponent(filename))
        imageEntries.append([
            "filename": filename,
            "idiom": "mac",
            "scale": "\(factor)x",
            "size": "\(points)x\(points)",
        ])
    }
}

let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["images": imageEntries, "info": info], to: iconSet.appendingPathComponent("Contents.json"))
try writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))
try writePNG(renderIcon(pixels: 1024), to: outputFolder.appendingPathComponent("icon-1024.png"))

print("Wrote \(imageEntries.count) icon images to \(iconSet.path)")
