// Draws the Game Center achievement art (1024×1024 PNG, no alpha, as App
// Store Connect wants). Milestones are a puzzle piece with a number;
// categories are one of that category's bundled photographs cut into the
// piece. Drawn by hand rather than from SF Symbols, whose licence forbids
// using them as artwork like this. File names are the `Achievement` cases.
//
//   swift Scripts/make-achievement-badges.swift . docs/gamecenter

import AppKit
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
CTFontManagerRegisterFontsForURL(root.appending(path: "Sources/Resources/Fonts/Caprasimo-Regular.ttf") as CFURL, .process, nil)

func color(_ hex: String) -> CGColor {
    let v = Int(hex, radix: 16)!
    return CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
// Theme.accent, Theme.sage and Theme.bg (light).
let accent = color("c67139"), sage = color("7a8a5e"), cream = color("f5ead8"), deep = color("8f4a1f")

let size: CGFloat = 1024
let s: CGFloat = 520                                                // body side
let c = CGPoint(x: size / 2 - 0.06 * s, y: size / 2 - 0.06 * s)    // body centre, nudged for the tabs
let body = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
let r = 0.12 * s, reach = 0.12 * s, neck = 0.11 * s

/// Bulb and neck of one edge. Tabs stick out on the top and right; blanks
/// bite in on the bottom and left. Coordinates are y-up.
func bulb(_ edge: Int) -> (CGRect, CGRect) {
    switch edge {
    case 0: // top tab
        let o = CGPoint(x: c.x, y: body.maxY + reach)
        return (CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r), CGRect(x: c.x - neck / 2, y: body.maxY - 2, width: neck, height: reach + 2))
    case 1: // right tab
        let o = CGPoint(x: body.maxX + reach, y: c.y)
        return (CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r), CGRect(x: body.maxX - 2, y: c.y - neck / 2, width: reach + 2, height: neck))
    case 2: // bottom blank
        let o = CGPoint(x: c.x, y: body.minY + reach)
        return (CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r), CGRect(x: c.x - neck / 2, y: body.minY - 2, width: neck, height: reach + 2))
    default: // left blank
        let o = CGPoint(x: body.minX + reach, y: c.y)
        return (CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r), CGRect(x: body.minX - 2, y: c.y - neck / 2, width: reach + 2, height: neck))
    }
}

func piecePath() -> CGPath {
    let path = CGMutablePath()
    path.addPath(CGPath(roundedRect: body, cornerWidth: 26, cornerHeight: 26, transform: nil))
    for edge in [0, 1] { let (b, n) = bulb(edge); path.addEllipse(in: b); path.addRect(n) }
    return path
}

func render(_ name: String, background: CGColor, photo: String? = nil, label: String? = nil, heart: Bool = false) {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // A soft ring so the badge reads as a medal inside Game Center's circle.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(22)
    ctx.strokeEllipse(in: CGRect(x: 60, y: 60, width: size - 120, height: size - 120))

    let piece = piecePath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(piece)
    ctx.setFillColor(cream)
    ctx.fillPath()
    ctx.restoreGState()

    if let photo {
        let url = root.appending(path: "Sources/Resources/Pictures/\(photo).jpg")
        let image = NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let bounds = piece.boundingBox
        let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.saveGState()
        ctx.addPath(piece)
        ctx.clip()
        ctx.draw(image, in: CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h))
        ctx.restoreGState()
    }
    ctx.setFillColor(background)
    for edge in [2, 3] { let (b, n) = bulb(edge); ctx.fillEllipse(in: b); ctx.fill(n) }

    if let label {
        let font = CTFontCreateWithName("Caprasimo-Regular" as CFString, label.count > 3 ? 125 : label.count > 2 ? 160 : 300, nil)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor(cgColor: deep)!])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetImageBounds(line, ctx)
        // Off-centre, onto the solid part of the piece, clear of the blanks.
        ctx.textPosition = CGPoint(x: c.x + 0.06 * s - bounds.midX, y: c.y + 0.05 * s - bounds.midY)
        CTLineDraw(line, ctx)
    }
    if heart {
        let h = CGMutablePath(), k: CGFloat = 1.25
        let p = CGPoint(x: c.x, y: c.y - 70 * k)
        h.move(to: p)
        h.addCurve(to: CGPoint(x: c.x - 110 * k, y: c.y + 30 * k), control1: CGPoint(x: c.x - 40 * k, y: c.y - 20 * k), control2: CGPoint(x: c.x - 110 * k, y: c.y - 20 * k))
        h.addArc(center: CGPoint(x: c.x - 55 * k, y: c.y + 30 * k), radius: 55 * k, startAngle: .pi, endAngle: 0, clockwise: true)
        h.addArc(center: CGPoint(x: c.x + 55 * k, y: c.y + 30 * k), radius: 55 * k, startAngle: .pi, endAngle: 0, clockwise: true)
        h.addCurve(to: p, control1: CGPoint(x: c.x + 110 * k, y: c.y - 20 * k), control2: CGPoint(x: c.x + 40 * k, y: c.y - 20 * k))
        ctx.addPath(h)
        ctx.setFillColor(accent)
        ctx.fillPath()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: "\(name).png"))
}

render("firstPuzzle", background: accent, label: "1")
render("tenPuzzles", background: accent, label: "10")
render("fiftyPuzzles", background: accent, label: "50")
render("sprinter", background: accent, label: "5:00")
render("nightmare", background: color("4a3b33"), label: "800")
render("weekStreak", background: accent, label: "7")
render("ownPhoto", background: accent, heart: true)
render("space", background: sage, photo: "space_Aurora over the Pines")
render("nature", background: sage, photo: "nature_Autumn Forest from Above")
render("mountains", background: sage, photo: "mountains_Alpine Village")
render("sea", background: sage, photo: "sea_Cliff Lighthouse")
render("city", background: sage, photo: "city_Boats of Vernazza")
render("animals", background: sage, photo: "animals_Bengal Tiger")
render("abstract", background: sage, photo: "abstract_Balloons over Cappadocia")
