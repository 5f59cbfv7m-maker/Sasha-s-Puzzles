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

func render(_ name: String, background: CGColor, photo: String? = nil, label: String? = nil, heart: Bool = false,
            star: Bool = false) {
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
    if star {
        // Five points, the outer radius on the solid part of the piece.
        let p = CGMutablePath(), o = CGPoint(x: c.x + 0.03 * s, y: c.y + 0.02 * s)
        for i in 0..<10 {
            let radius: CGFloat = i % 2 == 0 ? 190 : 80
            let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let point = CGPoint(x: o.x + radius * cos(angle), y: o.y + radius * sin(angle))
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        p.closeSubpath()
        ctx.addPath(p)
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
// Added in 1.2: the next tiers, and the medals for points and secrets.
let night = color("4a3b33")
render("hundredPuzzles", background: accent, label: "100")
render("twoFiftyPuzzles", background: accent, label: "250")
render("thousand", background: night, label: "1000")
render("twoWeekStreak", background: accent, label: "14")
render("monthStreak", background: accent, label: "30")
render("points1k", background: accent, label: "1K")
render("points5k", background: accent, label: "5K")
render("allRewards", background: sage, photo: "mountains_Matterhorn at Sunrise")
render("firstGift", background: night, photo: "secret_Fairytale Castle")
render("allSecrets", background: night, photo: "secret_Fireflies and Stars")
// Leaderboard art for the points boards.
render("leaderboard-points_total", background: accent, star: true)
render("leaderboard-points_week", background: sage, star: true)
render("space", background: sage, photo: "space_Aurora over the Pines")
render("nature", background: sage, photo: "nature_Autumn Forest from Above")
render("mountains", background: sage, photo: "mountains_Alpine Village")
render("sea", background: sage, photo: "sea_Cliff Lighthouse")
render("city", background: sage, photo: "city_Boats of Vernazza")
render("animals", background: sage, photo: "animals_Bengal Tiger")
render("abstract", background: sage, photo: "abstract_Balloons over Cappadocia")

// MARK: - Medals (1.4)

// Five levels of eight medals, each the colour of its metal, into
// `<out>/medals/medal.<medal>.<level>.png`: a hand-drawn motif for the medal
// over the level's goal. The metals match `Medal.Tier.color`.
let medalsOut = out.appending(path: "medals")
try? FileManager.default.createDirectory(at: medalsOut, withIntermediateDirectories: true)
let metals: [(name: String, color: CGColor)] = [("bronze", color("c27d47")), ("silver", color("9ea8b5")),
                                                ("gold", color("e3ad33")), ("platinum", color("80b3b3")),
                                                ("diamond", color("66adf2"))]

func darker(_ c: CGColor, _ k: CGFloat) -> CGColor {
    let p = c.components!
    return CGColor(red: p[0] * k, green: p[1] * k, blue: p[2] * k, alpha: 1)
}

/// A motif around `o`, about 2·`m` across, filled or stroked in the current ink.
func motif(_ kind: String, _ ctx: CGContext, _ o: CGPoint, _ m: CGFloat) {
    let p = CGMutablePath()
    switch kind {
    case "puzzles": // a tick: the puzzle done
        ctx.setLineWidth(m * 0.32); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        p.move(to: CGPoint(x: o.x - m * 0.8, y: o.y + m * 0.05))
        p.addLine(to: CGPoint(x: o.x - m * 0.2, y: o.y - m * 0.55))
        p.addLine(to: CGPoint(x: o.x + m * 0.85, y: o.y + m * 0.6))
        ctx.addPath(p); ctx.strokePath(); return
    case "pieces": // a 3×3 grid of tiles
        let t = m * 0.52, g = m * 0.14
        for row in -1...1 { for col in -1...1 {
            let r = CGRect(x: o.x + CGFloat(col) * (t + g) - t / 2, y: o.y + CGFloat(row) * (t + g) - t / 2, width: t, height: t)
            p.addPath(CGPath(roundedRect: r, cornerWidth: t * 0.2, cornerHeight: t * 0.2, transform: nil))
        } }
    case "points": // a five-pointed star
        for i in 0..<10 {
            let radius = i % 2 == 0 ? m : m * 0.42
            let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let point = CGPoint(x: o.x + radius * cos(angle), y: o.y + radius * sin(angle))
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        p.closeSubpath()
    case "dailies": // the sun
        p.addEllipse(in: CGRect(x: o.x - m * 0.45, y: o.y - m * 0.45, width: m * 0.9, height: m * 0.9))
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let ray = CGAffineTransform(translationX: o.x, y: o.y).rotated(by: a)
            p.addPath(CGPath(roundedRect: CGRect(x: m * 0.62, y: -m * 0.08, width: m * 0.38, height: m * 0.16),
                             cornerWidth: m * 0.08, cornerHeight: m * 0.08, transform: nil), transform: ray)
        }
    case "bigPuzzles": // two peaks
        p.move(to: CGPoint(x: o.x - m, y: o.y - m * 0.6)); p.addLine(to: CGPoint(x: o.x - m * 0.25, y: o.y + m * 0.7))
        p.addLine(to: CGPoint(x: o.x + m * 0.2, y: o.y - m * 0.05)); p.addLine(to: CGPoint(x: o.x + m * 0.45, y: o.y + m * 0.35))
        p.addLine(to: CGPoint(x: o.x + m, y: o.y - m * 0.6)); p.closeSubpath()
    case "quick": // a lightning bolt
        let pts: [(CGFloat, CGFloat)] = [(0.15, 1), (-0.55, -0.1), (-0.05, -0.1), (-0.2, -1), (0.55, 0.15), (0.05, 0.15)]
        for (i, q) in pts.enumerated() {
            let point = CGPoint(x: o.x + q.0 * m, y: o.y + q.1 * m)
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        p.closeSubpath()
    case "together": // two people
        for (dx, k) in [(-0.42, 0.9), (0.42, 1.0)] as [(CGFloat, CGFloat)] {
            let x = o.x + dx * m, head = m * 0.27 * k
            p.addEllipse(in: CGRect(x: x - head, y: o.y + m * 0.15, width: head * 2, height: head * 2))
            let shoulders = CGRect(x: x - m * 0.45 * k, y: o.y - m * 0.75, width: m * 0.9 * k, height: m * 0.8)
            p.addPath(CGPath(roundedRect: shoulders, cornerWidth: m * 0.4 * k, cornerHeight: m * 0.4 * k, transform: nil))
        }
    default: // gallery: a framed picture
        ctx.setLineWidth(m * 0.16)
        ctx.addPath(CGPath(roundedRect: CGRect(x: o.x - m, y: o.y - m * 0.75, width: m * 2, height: m * 1.5),
                           cornerWidth: m * 0.15, cornerHeight: m * 0.15, transform: nil))
        ctx.strokePath()
        p.move(to: CGPoint(x: o.x - m * 0.75, y: o.y - m * 0.5)); p.addLine(to: CGPoint(x: o.x - m * 0.15, y: o.y + m * 0.25))
        p.addLine(to: CGPoint(x: o.x + m * 0.2, y: o.y - m * 0.15)); p.addLine(to: CGPoint(x: o.x + m * 0.4, y: o.y + m * 0.05))
        p.addLine(to: CGPoint(x: o.x + m * 0.75, y: o.y - m * 0.5)); p.closeSubpath()
        p.addEllipse(in: CGRect(x: o.x + m * 0.3, y: o.y + m * 0.25, width: m * 0.32, height: m * 0.32))
    }
    ctx.addPath(p)
    ctx.fillPath()
}

func renderMedal(_ medal: String, level: Int, label: String) {
    let metal = metals[level]
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(metal.color)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
    ctx.setLineWidth(22)
    ctx.strokeEllipse(in: CGRect(x: 60, y: 60, width: size - 120, height: size - 120))
    // The levels count up in small rings along the foot of the badge.
    for i in 0..<5 {
        let dot = CGRect(x: size / 2 - 2 * 46 + CGFloat(i) * 46 - 15, y: 118, width: 30, height: 30)
        ctx.setFillColor(i <= level ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 1, alpha: 0.3))
        ctx.fillEllipse(in: dot)
    }
    let piece = piecePath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(piece)
    ctx.setFillColor(cream)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(metal.color)
    for edge in [2, 3] { let (b, n) = bulb(edge); ctx.fillEllipse(in: b); ctx.fill(n) }

    let ink = darker(metal.color, 0.62)
    ctx.setFillColor(ink)
    ctx.setStrokeColor(ink)
    // Above the bottom blank, which would bite into the number.
    motif(medal, ctx, CGPoint(x: c.x + 0.06 * s, y: c.y + 0.21 * s), 0.17 * s)
    let font = CTFontCreateWithName("Caprasimo-Regular" as CFString, label.count > 3 ? 100 : 118, nil)
    let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink)!])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: c.x + 0.06 * s - bounds.midX, y: c.y - 0.1 * s - bounds.midY)
    CTLineDraw(line, ctx)

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: medalsOut.appending(path: "medal.\(medal).\(metal.name).png"))
}

// The goals of `Medal.goals`, shortened; the gallery's diamond is every picture.
let medalLabels: [(String, [String])] = [
    ("puzzles", ["25", "75", "150", "300", "600"]),
    ("pieces", ["2K", "10K", "30K", "75K", "150K"]),
    ("points", ["3K", "10K", "30K", "75K", "150K"]),
    ("dailies", ["10", "30", "75", "150", "365"]),
    ("bigPuzzles", ["1", "5", "15", "40", "100"]),
    ("quick", ["3", "10", "30", "75", "150"]),
    ("together", ["1", "5", "15", "40", "100"]),
    ("gallery", ["20", "50", "90", "130", "100%"]),
]
for (medal, labels) in medalLabels {
    for (level, label) in labels.enumerated() { renderMedal(medal, level: level, label: label) }
}
