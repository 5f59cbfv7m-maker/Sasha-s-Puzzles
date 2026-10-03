import CoreGraphics
import Foundation

/// Immutable description of how a board is cut into pieces.
///
/// The engine works in **board units**, a resolution-independent space whose
/// area is always ``PuzzleGeometry/referenceArea``. Screen size, zoom level and
/// device orientation never touch these numbers, which is what lets a game
/// survive a window resize or a rotation without losing a single piece.
///
/// Every interior cut is stored **once**:
/// * `horizontalCuts[row * columns + column]` — between piece `(row, column)`
///   and `(row + 1, column)`, canonically traversed left → right.
/// * `verticalCuts[row * (columns - 1) + column]` — between `(row, column)` and
///   `(row, column + 1)`, canonically traversed top → bottom.
///
/// A piece's outline reuses those exact curves (reversing two of them), so
/// `A.right` is *by construction* the inverse of `B.left`. No matching pass, no
/// tolerance, no drift.
nonisolated struct PuzzleGeometry: Sendable {
    /// Board area in board units². 1000×1000 for a square image.
    static let referenceArea: CGFloat = 1_000_000

    let columns: Int
    let rows: Int
    let seed: UInt64
    let boardSize: CGSize
    let cellSize: CGSize
    /// Length of one tab unit in board points.
    let tabAmplitude: CGFloat

    private let horizontalCuts: [EdgeCurve]
    private let verticalCuts: [EdgeCurve]

    var pieceCount: Int { rows * columns }

    /// Worst-case distance a tab reaches beyond its cell, used to size textures.
    var maximumOverhang: CGFloat { tabAmplitude * 1.25 }

    // MARK: - Construction

    init(columns: Int, rows: Int, aspect: CGFloat, seed: UInt64) {
        precondition(columns >= 2 && rows >= 2, "A puzzle needs at least a 2×2 grid")
        self.columns = columns
        self.rows = rows
        self.seed = seed

        let safeAspect = clamp(aspect, 0.2, 5.0)
        let width = (Self.referenceArea * safeAspect).squareRoot()
        let height = Self.referenceArea / width
        self.boardSize = CGSize(width: width, height: height)
        self.cellSize = CGSize(width: width / CGFloat(columns), height: height / CGFloat(rows))
        // Tabs scale with the *smaller* cell dimension so they stay in proportion
        // even when the grid is not perfectly square.
        self.tabAmplitude = cellSize.minimumSide * 0.215

        let cell = cellSize
        let amplitude = tabAmplitude

        // Horizontal cuts: normal points down (toward the row below).
        var horizontal: [EdgeCurve] = []
        horizontal.reserveCapacity(max(0, rows - 1) * columns)
        for row in 0..<max(0, rows - 1) {
            for column in 0..<columns {
                var rng = SplitMix64(seed: mixSeed(seed, 0xA1, UInt64(row), UInt64(column)))
                let profile = EdgeProfile.random(using: &rng)
                let y = CGFloat(row + 1) * cell.height
                horizontal.append(profile.curve(
                    from: CGPoint(x: CGFloat(column) * cell.width, y: y),
                    to: CGPoint(x: CGFloat(column + 1) * cell.width, y: y),
                    normal: CGPoint(x: 0, y: 1),
                    amplitude: amplitude))
            }
        }

        // Vertical cuts: normal points right (toward the next column).
        var vertical: [EdgeCurve] = []
        vertical.reserveCapacity(rows * max(0, columns - 1))
        for row in 0..<rows {
            for column in 0..<max(0, columns - 1) {
                var rng = SplitMix64(seed: mixSeed(seed, 0xB2, UInt64(row), UInt64(column)))
                let profile = EdgeProfile.random(using: &rng)
                let x = CGFloat(column + 1) * cell.width
                vertical.append(profile.curve(
                    from: CGPoint(x: x, y: CGFloat(row) * cell.height),
                    to: CGPoint(x: x, y: CGFloat(row + 1) * cell.height),
                    normal: CGPoint(x: 1, y: 0),
                    amplitude: amplitude))
            }
        }

        self.horizontalCuts = horizontal
        self.verticalCuts = vertical
    }

    /// Picks a grid whose piece count is close to `target` while keeping cells
    /// as square as possible for the given image aspect ratio.
    static func grid(targetPieces: Int, aspect: CGFloat) -> (columns: Int, rows: Int) {
        let target = max(4, targetPieces)
        let safeAspect = Double(clamp(aspect, 0.2, 5.0))
        let idealColumns = (Double(target) * safeAspect).squareRoot()

        var best = (columns: 2, rows: 2)
        var bestScore = Double.greatestFiniteMagnitude

        for columns in max(2, Int(idealColumns.rounded()) - 4)...(Int(idealColumns.rounded()) + 4) {
            guard columns >= 2 else { continue }
            let rows = max(2, Int((Double(target) / Double(columns)).rounded()))
            let count = columns * rows
            let cellAspect = (safeAspect / Double(columns)) * Double(rows)
            // Count accuracy dominates; squareness breaks ties.
            let score = Double(abs(count - target)) / Double(target) * 4
                + abs(log(cellAspect)) * 1.6
            if score < bestScore {
                bestScore = score
                best = (columns, rows)
            }
        }
        return best
    }

    // MARK: - Lookup

    /// Index of the piece at `(row, column)` in row-major order.
    func index(row: Int, column: Int) -> Int { row * columns + column }
    func row(of index: Int) -> Int { index / columns }
    func column(of index: Int) -> Int { index % columns }

    /// The cell rectangle a piece occupies when solved (tabs excluded).
    func cellFrame(of index: Int) -> CGRect {
        CGRect(x: CGFloat(column(of: index)) * cellSize.width,
               y: CGFloat(row(of: index)) * cellSize.height,
               width: cellSize.width, height: cellSize.height)
    }

    /// Top-left of the piece's cell — the anchor all placement maths uses.
    func solvedOrigin(of index: Int) -> CGPoint { cellFrame(of: index).origin }

    /// Indices of the up-to-four orthogonal neighbours of a piece.
    func neighbors(of index: Int) -> [Int] {
        let r = row(of: index), c = column(of: index)
        var result: [Int] = []
        result.reserveCapacity(4)
        if r > 0 { result.append(self.index(row: r - 1, column: c)) }
        if r < rows - 1 { result.append(self.index(row: r + 1, column: c)) }
        if c > 0 { result.append(self.index(row: r, column: c - 1)) }
        if c < columns - 1 { result.append(self.index(row: r, column: c + 1)) }
        return result
    }

    /// The shared cut below piece `(row, column)`, or `nil` on the bottom border.
    func horizontalCut(row: Int, column: Int) -> EdgeCurve? {
        guard row >= 0, row < rows - 1, column >= 0, column < columns else { return nil }
        return horizontalCuts[row * columns + column]
    }

    /// The shared cut to the right of piece `(row, column)`, or `nil` on the right border.
    func verticalCut(row: Int, column: Int) -> EdgeCurve? {
        guard row >= 0, row < rows, column >= 0, column < columns - 1 else { return nil }
        return verticalCuts[row * (columns - 1) + column]
    }

    /// Every interior cut once, in board coordinates, with its midpoint: the
    /// seams of the finished picture.
    var seams: [(path: CGPath, mid: CGPoint)] {
        (horizontalCuts + verticalCuts).map { cut in
            let path = CGMutablePath()
            path.move(to: cut.start)
            for segment in cut.segments {
                path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
            }
            return (path, CGPoint(x: (cut.start.x + cut.end.x) / 2, y: (cut.start.y + cut.end.y) / 2))
        }
    }

    // MARK: - Piece outline

    /// The four boundary curves of a piece, clockwise from the top-left corner.
    ///
    /// Border edges are straight lines; interior edges reuse the shared cut,
    /// reversed where the clockwise walk runs against the canonical direction.
    func outline(of index: Int) -> [EdgeCurve] {
        let r = row(of: index), c = column(of: index)
        let frame = cellFrame(of: index)
        let topLeft = CGPoint(x: frame.minX, y: frame.minY)
        let topRight = CGPoint(x: frame.maxX, y: frame.minY)
        let bottomRight = CGPoint(x: frame.maxX, y: frame.maxY)
        let bottomLeft = CGPoint(x: frame.minX, y: frame.maxY)

        func straight(_ from: CGPoint, _ to: CGPoint) -> EdgeCurve {
            // A cubic with evenly spaced controls is exactly the straight segment.
            let c1 = CGPoint(x: from.x + (to.x - from.x) / 3, y: from.y + (to.y - from.y) / 3)
            let c2 = CGPoint(x: from.x + (to.x - from.x) * 2 / 3, y: from.y + (to.y - from.y) * 2 / 3)
            return EdgeCurve(start: from, segments: [CubicSegment(c1, c2, to)])
        }

        let top = horizontalCut(row: r - 1, column: c) ?? straight(topLeft, topRight)
        let right = verticalCut(row: r, column: c) ?? straight(topRight, bottomRight)
        let bottom = (horizontalCut(row: r, column: c)?.reversed) ?? straight(bottomRight, bottomLeft)
        let left = (verticalCut(row: r, column: c - 1)?.reversed) ?? straight(bottomLeft, topLeft)
        return [top, right, bottom, left]
    }

    /// Closed outline of a piece in board coordinates.
    func path(of index: Int) -> CGPath {
        let path = CGMutablePath()
        let edges = outline(of: index)
        path.move(to: edges[0].start)
        for edge in edges {
            for segment in edge.segments {
                path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
            }
        }
        path.closeSubpath()
        return path
    }

    /// Same outline translated so the piece's cell origin lands at `(0, 0)`,
    /// which is the frame the texture cache renders in.
    func localPath(of index: Int) -> CGPath {
        let origin = solvedOrigin(of: index)
        var transform = CGAffineTransform(translationX: -origin.x, y: -origin.y)
        return path(of: index).copy(using: &transform) ?? path(of: index)
    }

    /// Bounding box of a piece's outline (tabs included), relative to its cell origin.
    func localBounds(of index: Int) -> CGRect {
        localPath(of: index).boundingBoxOfPath.integralOutset()
    }
}

nonisolated extension CGRect {
    /// Rounds outward by a hair so anti-aliased strokes are never clipped.
    func integralOutset(_ margin: CGFloat = 1) -> CGRect {
        CGRect(x: (minX - margin).rounded(.down), y: (minY - margin).rounded(.down),
               width: (width + margin * 2).rounded(.up), height: (height + margin * 2).rounded(.up))
    }
}
