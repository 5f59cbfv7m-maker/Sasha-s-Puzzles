import CoreGraphics
import Foundation

/// A rigid cluster of connected pieces.
///
/// Pieces inside a group are always in their exact solved relationship, so the
/// whole cluster is described by a single `translation` — the offset from the
/// solved layout. Moving a group is O(1); no per-piece bookkeeping, no drift.
nonisolated struct PieceGroup: Sendable, Codable, Identifiable, Equatable {
    var id: Int32
    var members: [Int32]
    /// Offset from the solved position, in board units. `.zero` means "at home".
    var translation: CGPoint
    var z: Int32

    var isHome: Bool { translation.isApproximatelyEqual(to: .zero, tolerance: 0.001) }
    /// A cluster sitting at home is part of the finished picture: it can no
    /// longer be dragged, split or sent back to the tray.
    var isLocked: Bool { isHome }
}

/// What happened when a dragged group was released.
nonisolated struct SettleOutcome: Sendable, Equatable {
    var didSnap = false
    var absorbedGroups: [Int32] = []
    var group: Int32 = -1
    /// Pieces that gained a new connection — used for the green flash.
    var connectedPieces: [Int32] = []
    var didComplete = false

    var didMerge: Bool { !absorbedGroups.isEmpty }
}

/// Placement state of every piece: the pure, testable core of the game.
///
/// Two pieces are correctly joined **iff their groups share the same
/// translation**. That single invariant replaces per-edge bookkeeping and makes
/// snapping, merging and completion checks trivial and impossible to corrupt.
nonisolated struct PuzzleState: Sendable, Codable, Equatable {
    let columns: Int
    let rows: Int
    let cellSize: CGSize

    /// Group id per piece; `-1` means the piece is still in the tray.
    private(set) var pieceGroup: [Int32]
    private(set) var groups: [Int32: PieceGroup]
    /// Pieces still waiting in the tray, in shuffled display order.
    private(set) var trayOrder: [Int32]
    private var nextGroupID: Int32 = 0
    private var zCounter: Int32 = 0
    /// Bumped whenever the *structure* changes (membership, z-order, tray).
    /// Pure movement does not touch it, which lets the renderer keep a sorted
    /// draw order across a drag instead of re-sorting every frame.
    private(set) var structureRevision: Int = 0

    var pieceCount: Int { rows * columns }
    var placedCount: Int { pieceCount - trayOrder.count }
    /// Number of pieces that sit in a cluster of two or more.
    var connectedCount: Int { groups.values.reduce(0) { $0 + ($1.members.count > 1 ? $1.members.count : 0) } }
    var isComplete: Bool { trayOrder.isEmpty && groups.count == 1 }

    init(columns: Int, rows: Int, cellSize: CGSize) {
        self.columns = columns
        self.rows = rows
        self.cellSize = cellSize
        self.pieceGroup = Array(repeating: -1, count: rows * columns)
        self.groups = [:]
        self.trayOrder = (0..<Int32(rows * columns)).map { $0 }
    }

    // MARK: - Geometry helpers

    func row(of piece: Int32) -> Int { Int(piece) / columns }
    func column(of piece: Int32) -> Int { Int(piece) % columns }

    func solvedOrigin(of piece: Int32) -> CGPoint {
        CGPoint(x: CGFloat(column(of: piece)) * cellSize.width,
                y: CGFloat(row(of: piece)) * cellSize.height)
    }

    /// Current top-left of a piece's cell, or `nil` while it is in the tray.
    func origin(of piece: Int32) -> CGPoint? {
        let id = pieceGroup[Int(piece)]
        guard id >= 0, let group = groups[id] else { return nil }
        return solvedOrigin(of: piece) + group.translation
    }

    func group(of piece: Int32) -> PieceGroup? {
        let id = pieceGroup[Int(piece)]
        return id >= 0 ? groups[id] : nil
    }

    /// `true` once the piece has been placed correctly on the board.
    func isLocked(_ piece: Int32) -> Bool { group(of: piece)?.isLocked ?? false }

    func neighbors(of piece: Int32) -> [Int32] {
        let r = row(of: piece), c = column(of: piece)
        var result: [Int32] = []
        result.reserveCapacity(4)
        if r > 0 { result.append(piece - Int32(columns)) }
        if r < rows - 1 { result.append(piece + Int32(columns)) }
        if c > 0 { result.append(piece - 1) }
        if c < columns - 1 { result.append(piece + 1) }
        return result
    }

    /// Snap radius in board units. Scales with piece size so it feels the same
    /// on a 12-piece and an 800-piece puzzle, and with zoom so it feels the same
    /// on screen at any magnification.
    func snapTolerance(viewScale: CGFloat, assist: CGFloat = 1) -> CGFloat {
        let side = cellSize.minimumSide
        let screenBased = viewScale > 0 ? 12 / viewScale : side * 0.2
        return clamp(max(side * 0.20, screenBased) * assist, side * 0.12, side * 0.55)
    }

    // MARK: - Tray

    mutating func shuffleTray(using rng: inout SplitMix64) {
        trayOrder = rng.shuffled(trayOrder)
        structureRevision += 1
    }

    /// Moves a piece out of the tray onto the table at the given group translation.
    @discardableResult
    mutating func placeFromTray(_ piece: Int32, translation: CGPoint) -> Int32 {
        guard pieceGroup[Int(piece)] < 0 else { return pieceGroup[Int(piece)] }
        trayOrder.removeAll { $0 == piece }
        zCounter += 1
        let id = nextGroupID
        nextGroupID += 1
        groups[id] = PieceGroup(id: id, members: [piece], translation: translation, z: zCounter)
        pieceGroup[Int(piece)] = id
        structureRevision += 1
        return id
    }

    /// Sends a single piece back to the tray, splitting it off its group if needed.
    /// Pieces already locked in place stay where they are.
    mutating func returnToTray(_ piece: Int32) {
        let id = pieceGroup[Int(piece)]
        guard id >= 0, var group = groups[id], !group.isLocked else { return }
        group.members.removeAll { $0 == piece }
        if group.members.isEmpty { groups.removeValue(forKey: id) } else { groups[id] = group }
        pieceGroup[Int(piece)] = -1
        if !trayOrder.contains(piece) { trayOrder.append(piece) }
        structureRevision += 1
    }

    /// Single pieces on the table that are neither joined to a neighbour nor
    /// locked in place, bottom first.
    var looseSingles: [Int32] {
        groups.values
            .filter { $0.members.count == 1 && !$0.isLocked }
            .sorted { $0.z < $1.z }
            .map { $0.members[0] }
    }

    var hasLooseSingles: Bool {
        groups.values.contains { $0.members.count == 1 && !$0.isLocked }
    }

    /// The undo of a scatter: every loose single goes back to the tray.
    /// Joined clusters stay on the table — a join is always correct, and
    /// breaking one up would throw the player's work away.
    mutating func gatherLooseSingles() {
        for piece in looseSingles { returnToTray(piece) }
    }

    /// Empties the tray onto the table, scattering pieces inside `area`
    /// (board units) while avoiding the board itself where possible.
    mutating func scatterTray(in area: CGRect, avoiding board: CGRect, using rng: inout SplitMix64) {
        let pieces = trayOrder
        for piece in pieces {
            var target = CGPoint.zero
            for _ in 0..<12 {
                let candidate = rng.point(in: area.insetBy(dx: cellSize.width, dy: cellSize.height))
                if !board.insetBy(dx: -cellSize.width * 0.2, dy: -cellSize.height * 0.2).contains(candidate) {
                    target = candidate
                    break
                }
                target = candidate
            }
            placeFromTray(piece, translation: target - solvedOrigin(of: piece))
        }
    }

    // MARK: - Movement

    mutating func bringToFront(group id: Int32) {
        guard var group = groups[id] else { return }
        zCounter += 1
        group.z = zCounter
        groups[id] = group
        structureRevision += 1
    }

    mutating func setTranslation(_ translation: CGPoint, forGroup id: Int32) {
        guard var group = groups[id] else { return }
        group.translation = translation
        groups[id] = group
    }

    mutating func move(group id: Int32, by delta: CGPoint) {
        guard let group = groups[id] else { return }
        setTranslation(group.translation + delta, forGroup: id)
    }

    // MARK: - Snapping & merging

    /// Candidate resting translations for a group: its home position plus the
    /// translation of every group it touches.
    func snapCandidates(for id: Int32) -> [CGPoint] {
        guard let group = groups[id] else { return [] }
        var candidates: [CGPoint] = [.zero]
        var seen = Set<Int32>([id])
        for piece in group.members {
            for neighbor in neighbors(of: piece) {
                let other = pieceGroup[Int(neighbor)]
                guard other >= 0, !seen.contains(other), let target = groups[other] else { continue }
                seen.insert(other)
                candidates.append(target.translation)
            }
        }
        return candidates
    }

    /// Releases a group: snaps it if it is close enough to a valid position, then
    /// absorbs every neighbouring group that now lines up — transitively, so a
    /// piece dropped into a gap can join four clusters at once.
    mutating func settle(group id: Int32, tolerance: CGFloat) -> SettleOutcome {
        var outcome = SettleOutcome()
        outcome.group = id
        guard let group = groups[id] else { return outcome }

        var best: CGPoint?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for candidate in snapCandidates(for: id) {
            let distance = candidate.distance(to: group.translation)
            if distance <= tolerance, distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        guard let target = best else { return outcome }

        outcome.didSnap = true
        setTranslation(target, forGroup: id)
        outcome.connectedPieces = mergeNeighbours(into: id, at: target, absorbed: &outcome.absorbedGroups)
        outcome.didComplete = isComplete
        return outcome
    }

    /// Breadth-first absorption of every touching group sharing our translation.
    private mutating func mergeNeighbours(into id: Int32, at translation: CGPoint,
                                          absorbed: inout [Int32]) -> [Int32] {
        var frontier = groups[id]?.members ?? []
        var connected: [Int32] = []
        var visited = Set(frontier)

        while let piece = frontier.popLast() {
            for neighbor in neighbors(of: piece) {
                let otherID = pieceGroup[Int(neighbor)]
                guard otherID >= 0, otherID != id, let other = groups[otherID],
                      other.translation.isApproximatelyEqual(to: translation, tolerance: 0.01)
                else { continue }

                connected.append(piece)
                connected.append(neighbor)
                absorbed.append(otherID)

                for member in other.members {
                    pieceGroup[Int(member)] = id
                    if visited.insert(member).inserted { frontier.append(member) }
                }
                groups[id]?.members.append(contentsOf: other.members)
                groups.removeValue(forKey: otherID)
                structureRevision += 1
            }
        }
        return Array(Set(connected))
    }

    /// Instantly solves the puzzle. Used by tests and the developer shortcut only.
    mutating func solveAll() {
        for piece in trayOrder { placeFromTray(piece, translation: .zero) }
        let ids = Array(groups.keys)
        for id in ids { setTranslation(.zero, forGroup: id) }
        guard let anchor = ids.first else { return }
        var absorbed: [Int32] = []
        _ = mergeNeighbours(into: anchor, at: .zero, absorbed: &absorbed)
    }
}
