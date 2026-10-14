import AppKit
import CoreGraphics
import Foundation

// The PWE iMac Display app icon, drawn once and rasterised to every size the
// sender's asset catalogue and the receiver's .icns need. Nothing is hand-traced.
//
// Construction is the PWE house tile (navy plate, amber wing at 60 % of the
// plate's width, centred), the same as PWE Loan Bar, PWE Monitor and
// PWE Lumen Bar. This product's one addition is a thin iMac outline around
// the mark: the wing becomes the picture on a screen, which is what the app
// does to an old iMac. The outline sits on the plate, clear of the wing, in a
// brand colour, so it does not modify the mark (brand standard §7).
//
// BrandMark.swift is a verbatim copy of PWE Lumen Bar's generated geometry
// (from `01 BRAND ASSETS/source/wing_gen.py`); never hand-edit it.

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let navy = CGColor(red: 14 / 255, green: 23 / 255, blue: 41 / 255, alpha: 1)
let amber = CGColor(red: 245 / 255, green: 179 / 255, blue: 53 / 255, alpha: 1)

func drawAppIcon(in ctx: CGContext, side: CGFloat) {
    let pad = side * 0.085
    let plate = CGRect(x: pad, y: pad, width: side - pad * 2, height: side - pad * 2)
    let plateRadius = plate.width * 0.2237

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius,
                       cornerHeight: plateRadius, transform: nil))
    ctx.clip()
    ctx.setFillColor(navy)
    ctx.fill(plate)

    let markWidth = plate.width * 0.60
    let mark = CGRect(x: plate.midX - markWidth / 2,
                      y: plate.midY - markWidth / BrandMark.aspect / 2,
                      width: markWidth, height: markWidth / BrandMark.aspect)
    ctx.setFillColor(amber)
    ctx.addPath(BrandMark.path(in: mark).cgPath)
    ctx.fillPath()

    // The display: a thin outline of an iMac around the mark — screen, chin and
    // stand. The wing becomes the picture on the screen. The outline is a
    // separate element on the plate, never touching the wing.
    let line = max(plate.width * 0.018, 1)
    let screen = CGRect(x: plate.midX - plate.width * 0.40, y: mark.midY - plate.width * 0.27,
                        width: plate.width * 0.80, height: plate.width * 0.54)
    let screenRadius = plate.width * 0.055
    ctx.setStrokeColor(amber)
    ctx.setLineWidth(line)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius,
                       cornerHeight: screenRadius, transform: nil))
    ctx.strokePath()
    // Stand: a tapered neck and a foot, as on an iMac.
    ctx.setFillColor(amber)
    let neckTop = screen.minY - line / 2
    let neckH = plate.width * 0.085, neckTopW = plate.width * 0.10, neckBottomW = plate.width * 0.14
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: plate.midX - neckTopW / 2, y: neckTop))
    neck.addLine(to: CGPoint(x: plate.midX + neckTopW / 2, y: neckTop))
    neck.addLine(to: CGPoint(x: plate.midX + neckBottomW / 2, y: neckTop - neckH))
    neck.addLine(to: CGPoint(x: plate.midX - neckBottomW / 2, y: neckTop - neckH))
    neck.closeSubpath()
    ctx.addPath(neck)
    ctx.fillPath()
    ctx.restoreGState()
}

func png(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawAppIcon(in: ctx, side: CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])!
}

// Asset catalogue for the sender (Xcode), and an .iconset for the receiver's .icns.
let catalogue = out.appendingPathComponent("AppIcon.appiconset")
let iconset = out.appendingPathComponent("AppIcon.iconset")
for dir in [catalogue, iconset] {
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}
var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let data = png(pt * scale)
    try! data.write(to: catalogue.appendingPathComponent(name))
    try! data.write(to: iconset.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: catalogue.appendingPathComponent("Contents.json"))
try! png(1024).write(to: out.appendingPathComponent("icon_1024.png"))
print("wrote \(catalogue.path), \(iconset.path), icon_1024.png")
