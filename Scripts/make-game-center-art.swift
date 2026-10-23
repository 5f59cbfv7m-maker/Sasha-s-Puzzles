// Draws the art for Game Center activities and challenges (3840×2160 PNG,
// no alpha, as App Store Connect wants): one of the bundled photographs as
// a puzzle with one piece lifted out of its hole. The Games app lays the
// localized name over the picture, so there is no text in it. File names
// are the activity and challenge identifiers.
//
//   swift Scripts/make-game-center-art.swift . docs/gamecenter/activities

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let width: CGFloat = 3840, height: CGFloat = 2160

/// A jigsaw piece of side `s` centred at `c`: tabs on the top and right,
/// blanks on the bottom and left, as in the achievement art. y-up.
func piecePath(center c: CGPoint, side s: CGFloat) -> CGPath {
    let body = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
    let r = 0.12 * s, reach = 0.12 * s, neck = 0.11 * s
    let path = CGMutablePath()
    path.addRoundedRect(in: body, cornerWidth: 0.05 * s, cornerHeight: 0.05 * s)
    path.addEllipse(in: CGRect(x: c.x - r, y: body.maxY + reach - r, width: 2 * r, height: 2 * r))
    path.addRect(CGRect(x: c.x - neck / 2, y: body.maxY - 2, width: neck, height: reach + 2))
    path.addEllipse(in: CGRect(x: body.maxX + reach - r, y: c.y - r, width: 2 * r, height: 2 * r))
    path.addRect(CGRect(x: body.maxX - 2, y: c.y - neck / 2, width: reach + 2, height: neck))
    let blanks = CGMutablePath()
    blanks.addEllipse(in: CGRect(x: c.x - r, y: body.minY + reach - r, width: 2 * r, height: 2 * r))
    blanks.addRect(CGRect(x: c.x - neck / 2, y: body.minY - 2, width: neck, height: reach + 2))
    blanks.addEllipse(in: CGRect(x: body.minX + reach - r, y: c.y - r, width: 2 * r, height: 2 * r))
    blanks.addRect(CGRect(x: body.minX - 2, y: c.y - neck / 2, width: reach + 2, height: neck))
    return path.subtracting(blanks)
}

func render(_ name: String, photo: String, hole: CGPoint) {
    let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let url = root.appending(path: "Sources/Resources/Pictures/\(photo).jpg")
    let image = NSImage(contentsOf: url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let scale = max(width / CGFloat(image.width), height / CGFloat(image.height))
    let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
    let frame = CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: frame)

    // The lower third darkens a little, where the Games app sets the title.
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: .zero, end: CGPoint(x: 0, y: height * 0.45), options: [])

    let side: CGFloat = 520
    let socket = piecePath(center: hole, side: side)
    // The empty socket: the wooden table under the puzzle.
    ctx.addPath(socket)
    ctx.setFillColor(CGColor(red: 0.36, green: 0.22, blue: 0.13, alpha: 1))
    ctx.fillPath()

    // The missing piece, lifted up and to the right with a soft shadow.
    let lift = CGPoint(x: hole.x + 0.42 * side, y: hole.y + 0.32 * side)
    let piece = piecePath(center: lift, side: side)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -36), blur: 70, color: CGColor(gray: 0, alpha: 0.55))
    ctx.addPath(piece)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(piece)
    ctx.clip()
    ctx.draw(image, in: frame.offsetBy(dx: lift.x - hole.x, dy: lift.y - hole.y))
    ctx.restoreGState()
    ctx.addPath(piece)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
    ctx.setLineWidth(6)
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: "\(name).png"))
}

// Activities.
render("daily_puzzle", photo: "city_Riomaggiore Harbour", hole: CGPoint(x: 2700, y: 1250))
render("quick_puzzle", photo: "animals_Red Fox", hole: CGPoint(x: 2750, y: 1300))
// Challenges.
render("daily_race", photo: "mountains_Forest Lake at Sunrise", hole: CGPoint(x: 2650, y: 1250))
render("weekly_points", photo: "abstract_Morning Balloons", hole: CGPoint(x: 2700, y: 1300))
