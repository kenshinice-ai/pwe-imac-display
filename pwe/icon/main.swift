import AppKit
import CoreGraphics
import Foundation

// The PWE iMac Display icon pair, drawn once and rasterised to every size the
// sender's asset catalogue and the receiver's .icns need. Nothing is hand-traced.
//
//     swiftc pwe/icon/main.swift pwe/icon/BrandMark.swift -o <tmp>/pwe-icon && <tmp>/pwe-icon pwe/assets
//
// Construction is the PWE house tile (night plate, amber line wing), the same
// ground as PWE Loan Bar, PWE Monitor, PWE AI Bar and PWE Lumen Bar. This
// product's one addition is the front of a 27-inch iMac (2014-2017) around the
// mark: a 16:9 panel, the chin and the stand. The wing becomes the picture on
// the screen, which is what the app does to an old iMac. The frame sits on the
// plate, clear of the wing, so it does not modify the mark (brand standard §7).
// It is the product's registered second shape (BRAND-iMac-Display doc, 2.4).
//
// The two apps differ only in the frame's colour: amber for the sender (amber
// is the signal; the sender sends the picture), paper for the receiver (the lit
// iMac). Numbers: BRAND-iMac-Display doc 2.4; colours: `armature.json`.
//
// BrandMark.swift is a verbatim copy of PWE Lumen Bar's generated geometry
// (from `01 BRAND ASSETS/source/wing_gen.py`); never hand-edit it.

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

// sRGB end to end: the tokens are sRGB hex values, and a colour made with
// CGColor(red:green:blue:) is Generic RGB, which drew #0E1729 as #101F36.
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, 1])!
}
enum Token {
    static let night = rgb(0x0E1729)   // `night`
    static let amber = rgb(0xF5B335)   // `signal-strong`
    static let paper = rgb(0xF7F5F2)   // light `ground`
}

enum Frame {
    case amber, paper   // sender, receiver
    var color: CGColor { self == .amber ? Token.amber : Token.paper }
}

func drawAppIcon(in ctx: CGContext, side: CGFloat, frame: Frame) {
    let pad = side * 0.085
    let plate = CGRect(x: pad, y: pad, width: side - pad * 2, height: side - pad * 2)
    let P = plate.width
    let plateRadius = P * 0.2237

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plateRadius,
                       cornerHeight: plateRadius, transform: nil))
    ctx.clip()
    ctx.setFillColor(Token.night)
    ctx.fill(plate)

    // The iMac's front, from the real machine: body 650 x 450 mm without the
    // stand, the chin 19 % of that. Every edge lands on a whole pixel, and lines
    // are at least one pixel, so the 16 and 32 px sizes stay crisp; at 1024 px
    // the rounding moves nothing by more than half a pixel.
    let cx = side / 2, cy = side / 2
    let bodyW = P * 0.80, bodyH = bodyW * 450 / 650
    let line = max(1, (P * 0.024).rounded())
    let radius = P * 0.045
    let standH = max(1, (P * 0.07).rounded())
    func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }   // symmetric about cx

    // Outer edges of the body (stroke included). The group is centred, then
    // raised 0.01 P; y grows upward here.
    let outerW = even(bodyW + line)
    let outerTop = (cy + (bodyH + P * 0.07) / 2 + P * 0.01 + line / 2).rounded()
    let outerBottom = outerTop - (bodyH + line).rounded()
    let body = CGRect(x: cx - outerW / 2 + line / 2, y: outerBottom + line / 2,
                      width: outerW - line, height: outerTop - outerBottom - line)
    // The chin's top edge, a line as thick as the outline.
    let chinBottom = (body.minY + body.height * 0.19 - line / 2).rounded()
    let chin = CGRect(x: body.minX, y: chinBottom, width: body.width, height: line)

    ctx.setStrokeColor(frame.color)
    ctx.setFillColor(frame.color)
    ctx.setLineWidth(line)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()
    ctx.fill(chin)
    // The stand: a tapered foot under the chin.
    let neckTopW = even(P * 0.12), neckBottomW = even(P * 0.17)
    let stand = CGMutablePath()
    stand.move(to: CGPoint(x: cx - neckTopW / 2, y: outerBottom))
    stand.addLine(to: CGPoint(x: cx + neckTopW / 2, y: outerBottom))
    stand.addLine(to: CGPoint(x: cx + neckBottomW / 2, y: outerBottom - standH))
    stand.addLine(to: CGPoint(x: cx - neckBottomW / 2, y: outerBottom - standH))
    stand.closeSubpath()
    ctx.addPath(stand)
    ctx.fillPath()

    // The wing, the picture on the screen: 0.66 of the body's width, centred in
    // the panel between the outline's inner edge and the chin line. Always amber.
    let panelTop = outerTop - line, panelBottom = chin.maxY
    let markW = bodyW * 0.66, markH = markW / BrandMark.aspect
    let mark = CGRect(x: cx - markW / 2, y: (panelTop + panelBottom) / 2 - markH / 2,
                      width: markW, height: markH)
    ctx.setFillColor(Token.amber)
    ctx.addPath(BrandMark.path(in: mark).cgPath)
    ctx.fillPath()
    ctx.restoreGState()
}

func png(_ px: Int, _ frame: Frame) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawAppIcon(in: ctx, side: CGFloat(px), frame: frame)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])!
}

let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

/// An .iconset (for `iconutil`) and the 1024 px master in `dir`; with `catalogue`,
/// also the asset catalogue Xcode builds the sender's icon from.
func write(_ frame: Frame, to dir: URL, catalogue: Bool) {
    let iconset = dir.appendingPathComponent("AppIcon.iconset")
    let appiconset = dir.appendingPathComponent("AppIcon.appiconset")
    for d in catalogue ? [iconset, appiconset] : [iconset] {
        try? FileManager.default.removeItem(at: d)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
    var images: [[String: String]] = []
    for (pt, scale) in sizes {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        let data = png(pt * scale, frame)
        try! data.write(to: iconset.appendingPathComponent(name))
        if catalogue { try! data.write(to: appiconset.appendingPathComponent(name)) }
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
    if catalogue {
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: appiconset.appendingPathComponent("Contents.json"))
    }
    try! png(1024, frame).write(to: dir.appendingPathComponent("icon_1024.png"))
    print("wrote \(dir.path): \(catalogue ? "AppIcon.appiconset, " : "")AppIcon.iconset, icon_1024.png")
}

// Sender: the asset catalogue (Xcode), the .iconset (the disk image's volume
// icon) and the master (README). Receiver: the .iconset for its .icns, and the
// master for upstream's own receiver build script.
write(.amber, to: out, catalogue: true)
write(.paper, to: out.appendingPathComponent("receiver"), catalogue: false)
