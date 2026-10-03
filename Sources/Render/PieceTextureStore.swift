import CoreGraphics
import Foundation
import Observation
import SwiftUI

nonisolated extension CGContext {
    /// Draws an image into a rect of a y-flipped (top-left origin) context.
    ///
    /// Board space runs downward like a screen; CoreGraphics contexts run upward.
    /// The local double flip keeps images upright without inverting the geometry.
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

/// Pre-rendered bitmap for every piece, including its bevel.
///
/// This is the single most important performance decision in the app. Clipping
/// 800 Bézier outlines against a photograph *every frame* is hopeless; doing it
/// **once** per piece and then blitting cached bitmaps turns the draw loop into
/// a few hundred textured rectangles, which Core Graphics handles comfortably at
/// display refresh rate.
///
/// Work is chunked so progress can be reported and cancelled, and each chunk is
/// spread across all cores.
@Observable
final class PieceTextureStore {

    private(set) var textures: [CGImage?] = []
    /// SwiftUI wrappers created once per texture. Building them inside the draw
    /// loop would allocate 800 times per frame.
    private(set) var images: [Image?] = []
    /// Outline bounds of each piece relative to its own cell origin, in board units.
    private(set) var localBounds: [CGRect] = []
    private(set) var pixelScale: CGFloat = 1
    private var outlines = false
    private var cardboard = false
    private(set) var progress: Double = 0
    private(set) var isReady = false

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Texture memory ceiling. Beyond this the pixel scale is reduced rather
    /// than risking a memory-pressure termination on a huge puzzle.
    static let pixelBudget: Double = 90_000_000

    deinit { task?.cancel() }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func texture(for piece: Int) -> CGImage? {
        piece >= 0 && piece < textures.count ? textures[piece] : nil
    }

    /// Largest pixel scale that fits the budget for this geometry.
    static func affordableScale(for geometry: PuzzleGeometry, desired: CGFloat) -> CGFloat {
        let cell = geometry.cellSize
        let overhang = geometry.maximumOverhang * 2
        let area = Double((cell.width + overhang) * (cell.height + overhang)) * Double(geometry.pieceCount)
        guard area > 0 else { return desired }
        let maximum = (pixelBudget / area).squareRoot()
        return clamp(min(desired, CGFloat(maximum)), 0.35, 3.5)
    }

    func rebuild(geometry: PuzzleGeometry, source: RenderedImage,
                 pixelScale desired: CGFloat, outlines: Bool, cardboard: Bool = false) {
        let scale = Self.affordableScale(for: geometry, desired: desired)
        let count = geometry.pieceCount
        // Zooming out draws the existing, sharper textures downsampled; only a
        // markedly larger scale (or one wasteful enough to slow every frame)
        // is worth re-cutting. Small changes are not worth the work either.
        if isReady, textures.count == count, outlines == self.outlines, cardboard == self.cardboard,
           scale < pixelScale * 1.25, scale > pixelScale * 0.5 { return }

        task?.cancel()
        // A re-cut of a live board must not blank it: the old textures keep
        // drawing (they are scale independent) until the new set lands in one
        // swap, so there is one redraw and no loading overlay.
        let silent = isReady && textures.count == count
        if !silent {
            textures = Array(repeating: nil, count: count)
            images = Array(repeating: nil, count: count)
            progress = 0
            isReady = false
        }
        localBounds = (0..<count).map { geometry.localBounds(of: $0) }
        // Recorded when the cut lands, so a cancelled re-cut keeps describing
        // the textures actually on screen.
        if !silent { pixelScale = scale; self.outlines = outlines; self.cardboard = cardboard }

        task = Task { [geometry, source] in
            let chunkSize = max(16, count / 24)
            var index = 0
            var staged: [CGImage?] = silent ? Array(repeating: nil, count: count) : []
            while index < count {
                if Task.isCancelled { return }
                let range = Array(index..<min(index + chunkSize, count))
                let rendered = await Task.detached(priority: .userInitiated) {
                    UncheckedSendable(Self.render(pieces: range, geometry: geometry, source: source,
                                                  pixelScale: scale, outlines: outlines, cardboard: cardboard))
                }.value
                if Task.isCancelled { return }
                for (piece, image) in rendered.value where piece < count {
                    if silent {
                        staged[piece] = image
                    } else {
                        self.textures[piece] = image
                        self.images[piece] = Image(decorative: image, scale: 1)
                    }
                }
                index += range.count
                if !silent { self.progress = Double(index) / Double(count) }
            }
            if silent {
                self.textures = staged
                self.images = staged.map { $0.map { Image(decorative: $0, scale: 1) } }
                self.pixelScale = scale
                self.outlines = outlines
                self.cardboard = cardboard
            }
            self.isReady = true
        }
    }

    // MARK: - Rendering

    nonisolated static func render(pieces: [Int], geometry: PuzzleGeometry,
                                           source: RenderedImage, pixelScale: CGFloat,
                                           outlines: Bool, cardboard: Bool = false) -> [Int: CGImage] {
        var results = [CGImage?](repeating: nil, count: pieces.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = UncheckedSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: pieces.count) { slot in
                out.value[slot] = renderPiece(pieces[slot], geometry: geometry, source: source,
                                              pixelScale: pixelScale, outlines: outlines, cardboard: cardboard)
            }
        }
        var map: [Int: CGImage] = [:]
        for (slot, piece) in pieces.enumerated() {
            if let image = results[slot] { map[piece] = image }
        }
        return map
    }

    nonisolated static func renderPiece(_ piece: Int, geometry: PuzzleGeometry,
                                                source: RenderedImage, pixelScale: CGFloat,
                                                outlines: Bool, cardboard: Bool = false) -> CGImage? {
        let bounds = geometry.localBounds(of: piece)
        let origin = geometry.solvedOrigin(of: piece)
        let pixelSize = CGSize(width: (bounds.width * pixelScale).rounded(.up),
                               height: (bounds.height * pixelScale).rounded(.up))
        guard pixelSize.width >= 2, pixelSize.height >= 2,
              let context = CGContext.bitmap(size: pixelSize) else { return nil }

        // Board units with y running downward, origin at the piece's cell corner.
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: pixelScale, y: -pixelScale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)

        let path = geometry.localPath(of: piece)
        let pixelsPerUnit = CGFloat(source.width) / geometry.boardSize.width

        context.saveGState()
        context.addPath(path)
        context.clip()

        // Photo fragment: crop the source instead of drawing the whole image
        // under a clip — cropping a CGImage is a cheap view, drawing is not.
        let boardRect = bounds.offsetBy(origin)
        let desired = CGRect(x: boardRect.minX * pixelsPerUnit, y: boardRect.minY * pixelsPerUnit,
                             width: boardRect.width * pixelsPerUnit,
                             height: boardRect.height * pixelsPerUnit)
        let full = CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height))
        let sourceRect = desired.intersection(full).integral
        if sourceRect.width >= 1, sourceRect.height >= 1,
           let fragment = source.cgImage.cropping(to: sourceRect) {
            let destination = CGRect(x: sourceRect.minX / pixelsPerUnit - origin.x,
                                     y: sourceRect.minY / pixelsPerUnit - origin.y,
                                     width: sourceRect.width / pixelsPerUnit,
                                     height: sourceRect.height / pixelsPerUnit)
            context.interpolationQuality = .high
            context.drawFlipped(fragment, in: destination)
        } else {
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(bounds)
        }

        if cardboard {
            // Printed card: a fibrous grain in overlay, continuous across
            // the board, and a thin warm wash that takes the gloss off.
            let tile = CGFloat(Self.grain.width) * 2.5 / pixelScale
            context.saveGState()
            context.setBlendMode(.overlay)
            context.setAlpha(0.75)
            context.draw(Self.grain, in: CGRect(x: -origin.x, y: -origin.y, width: tile, height: tile), byTiling: true)
            context.setBlendMode(.normal)
            context.setAlpha(0.06)
            context.setFillColor(CGColor(red: 0.96, green: 0.92, blue: 0.84, alpha: 1))
            context.fill(bounds)
            context.restoreGState()
        }

        // Bevel: light from the top-left, shadow to the bottom-right, both
        // clipped to the outline so the piece reads as a cut cardboard shape.
        let depth = max(0.45, geometry.cellSize.minimumSide * 0.034)
        context.setLineJoin(.round)
        context.setLineWidth(depth * 1.7)
        // Matte card catches less light on its edge than a glossy print.
        for (dx, dy, color) in [(-depth * 0.5, -depth * 0.5, CGColor(gray: 1, alpha: cardboard ? 0.2 : 0.36)),
                                (depth * 0.5, depth * 0.5, CGColor(gray: 0, alpha: 0.32))] {
            context.saveGState()
            context.translateBy(x: dx, y: dy)
            context.addPath(path)
            context.setStrokeColor(color)
            context.strokePath()
            context.restoreGState()
        }
        // Inner rim: keeps two adjacent solved pieces visually separated.
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.22))
        context.setLineWidth(depth * 0.7)
        context.strokePath()
        context.restoreGState()

        if outlines {
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0.08, alpha: 0.38))
            context.setLineWidth(max(0.35, depth * 0.32))
            context.strokePath()
        }
        return context.makeImage()
    }

    /// Paper-fibre grain around mid grey, tileable: speckle plus short
    /// horizontal fibres that wrap at the edges.
    nonisolated static let grain: CGImage = {
        let side = 192
        var rng = SplitMix64(seed: 0xCA4D)
        var pixels = (0..<side * side).map { _ in 128 + (rng.unit() - 0.5) * 44 }
        for _ in 0..<900 {
            let x = rng.int(in: 0...side - 1), y = rng.int(in: 0...side - 1)
            let length = rng.int(in: 4...14), tone = (rng.unit() - 0.5) * 64
            for i in 0..<length { pixels[y * side + (x + i) % side] += tone * (1 - Double(i) / Double(length)) }
        }
        let bytes = pixels.map { UInt8(clamp($0, 0, 255)) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }()
}
