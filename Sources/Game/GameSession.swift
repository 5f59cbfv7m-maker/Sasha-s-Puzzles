import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// One game in progress: geometry, placement, textures, clock and autosave.
///
/// The session owns the *logical* game. Views observe it and draw; they never
/// hold placement state of their own, which is what makes a window resize or a
/// device rotation a pure re-layout with nothing to lose.
@Observable
@MainActor
final class GameSession {

    enum Phase: Equatable { case preparing, playing, paused, completed }

    struct DragState: Equatable {
        var group: Int32
        var grab: CGPoint
        var startTranslation: CGPoint
        var moved = false
    }

    struct Hint: Equatable {
        var piece: Int32
        var expires: Date
    }

    // MARK: Identity & configuration

    let id: String
    let item: LibraryItem
    let puzzleAspect: PuzzleAspect
    let targetPieces: Int
    let geometry: PuzzleGeometry
    /// Area pieces may be scattered across, in board units.
    let tableRect: CGRect

    // MARK: Observable state

    private(set) var state: PuzzleState
    private(set) var phase: Phase = .preparing
    private(set) var source: RenderedImage?
    /// Faint reference copy drawn under the board when the guide is enabled.
    private(set) var ghostImage: Image?
    private(set) var loadFailure: String?
    let textures = PieceTextureStore()

    var viewport = Viewport()
    private(set) var drag: DragState?
    /// Pieces flashing green after a successful connection.
    private(set) var flashes: [Int32: Date] = [:]
    private(set) var hint: Hint?
    /// Pieces just put down: they sink from the lifted size with a small bounce.
    struct Landing: Equatable {
        var pieces: Set<Int32>
        var at: Date
    }
    private(set) var landing: Landing?
    static let landingDuration: TimeInterval = 0.26
    /// How much a piece grows while it is held.
    static let liftScale: CGFloat = 1.035
    private(set) var lastOutcome: SettleOutcome? {
        didSet { if let lastOutcome { snapStreak = lastOutcome.didSnap ? snapStreak + 1 : 0 } }
    }
    /// Drops in a row that snapped; any drop that misses starts it over.
    @ObservationIgnored private(set) var snapStreak = 0
    static let streakLength = 3
    /// From the third snap in a row until the next miss, snaps ring the streak sound.
    var isOnStreak: Bool { snapStreak >= Self.streakLength }
    var selectedPiece: Int32?

    private(set) var elapsed: TimeInterval = 0
    /// When the last piece went in; the board plays its finale from here.
    private(set) var completedAt: Date?
    /// Set by the board: brings the whole picture into view and returns how
    /// long that takes, so the finale starts once the zoom has settled.
    @ObservationIgnored var fitForFinale: (() -> TimeInterval)?
    /// False while the finale plays, so the completion card waits for it.
    private(set) var finaleDone = true
    /// The finished picture breaks apart and puts itself back together
    /// (`reassembly` seconds); then the seams glow ~2.3 s, the light band
    /// crosses, and the photo stays on its own a moment before the card.
    static let reassembly: TimeInterval = 3.4
    static let finaleDuration: TimeInterval = reassembly + 5.3
    /// When a piece with this rank leaves its scatter spot and lands home again,
    /// in seconds after completion.
    static func reassemblyFlight(rank: Double) -> (start: Double, end: Double) {
        (1.4 + rank * 1.5, 1.9 + rank * 1.5)
    }
    /// Order in which each piece flies home during the reassembly, 0..<1.
    @ObservationIgnored private(set) var finaleRank: [Double] = []
    /// The finale's seams (board units) and where their light converges: the last piece placed.
    @ObservationIgnored private(set) var seams: [(path: CGPath, mid: CGPoint)] = []
    @ObservationIgnored private(set) var finaleFocus: CGPoint = .zero
    /// Fired once when the last group locks into place; the app records stats here.
    @ObservationIgnored var onComplete: ((GameSession) -> Void)?
    private(set) var canUndo = false
    private(set) var canRedo = false

    // MARK: Private

    @ObservationIgnored private var accumulated: TimeInterval = 0
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var effectsTask: Task<Void, Never>?
    @ObservationIgnored private var undoStack: [PuzzleState] = []
    @ObservationIgnored private var redoStack: [PuzzleState] = []
    @ObservationIgnored private var paths: [CGPath?] = []
    @ObservationIgnored private var drawOrderCache: (revision: Int, order: [Int32])?
    @ObservationIgnored private let saveStore: SaveStore
    @ObservationIgnored private var shuffleSeed: UInt64

    private static let undoLimit = 40

    // MARK: - Life cycle

    init(item: LibraryItem, aspect: PuzzleAspect, targetPieces: Int,
         seed: UInt64 = UInt64.random(in: 1...UInt64.max), id: String = UUID().uuidString,
         saveStore: SaveStore = SaveStore()) {
        self.id = id
        self.saveStore = saveStore
        self.item = item
        self.puzzleAspect = aspect
        self.targetPieces = targetPieces
        self.shuffleSeed = seed

        let boardAspect = aspect.ratio ?? item.aspect
        let grid = PuzzleGeometry.grid(targetPieces: targetPieces, aspect: boardAspect)
        self.geometry = PuzzleGeometry(columns: grid.columns, rows: grid.rows,
                                       aspect: boardAspect, seed: seed)
        self.state = PuzzleState(columns: grid.columns, rows: grid.rows,
                                 cellSize: geometry.cellSize)
        let board = CGRect(origin: .zero, size: geometry.boardSize)
        self.tableRect = board.insetBy(dx: -board.width * 0.62, dy: -board.height * 0.62)
        self.paths = Array(repeating: nil, count: geometry.pieceCount)
    }

    /// Rebuilds a session from a save. Geometry is regenerated from the seed, so
    /// the restored puzzle is bit-for-bit the one that was put down.
    convenience init(snapshot: GameSnapshot, saveStore: SaveStore = SaveStore()) {
        self.init(item: snapshot.libraryItem, aspect: snapshot.puzzleAspect,
                  targetPieces: snapshot.targetPieces, seed: snapshot.seed, id: snapshot.id,
                  saveStore: saveStore)
        state = snapshot.state
        accumulated = snapshot.elapsed
        elapsed = snapshot.elapsed
        if snapshot.isComplete { phase = .completed }
    }

    deinit {
        ticker?.cancel()
        autosaveTask?.cancel()
        effectsTask?.cancel()
    }

    var boardRect: CGRect { CGRect(origin: .zero, size: geometry.boardSize) }
    var isLoaded: Bool { source != nil }
    var progress: Double { textures.progress }
    var placedCount: Int { state.placedCount }
    var pieceCount: Int { geometry.pieceCount }

    /// Fraction of pieces that are joined to at least one neighbour.
    var completion: Double {
        pieceCount > 0 ? Double(state.connectedCount) / Double(pieceCount) : 0
    }

    // MARK: - Loading

    /// Fetches the picture, cuts the textures and shuffles a fresh board.
    func load(displayScale: CGFloat, settings: AppSettings, isNewGame: Bool) async {
        let longSide = Self.sourceLongSide(for: geometry)
        let request = ImageStore.Request(item: item, aspect: puzzleAspect, longSide: longSide)
        guard let image = await ImageStore.shared.image(request) else {
            loadFailure = String(localized: "This picture could not be loaded.")
            phase = .paused
            return
        }
        source = image
        ghostImage = Image(decorative: image.cgImage, scale: 1)

        if isNewGame {
            var rng = SplitMix64(seed: shuffleSeed)
            state.shuffleTray(using: &rng)
        }

        textures.rebuild(geometry: geometry, source: image,
                         pixelScale: max(1, viewport.scale * displayScale),
                         outlines: settings.showPieceOutlines, cardboard: settings.cardboardPieces)

        if phase != .completed {
            phase = .playing
            startClock()
        }
    }

    /// Source resolution: about 1.6 texels per board unit at the largest usable
    /// texture scale, capped so a 800-piece puzzle stays well under memory limits.
    private static func sourceLongSide(for geometry: PuzzleGeometry) -> Int {
        let longSide = max(geometry.boardSize.width, geometry.boardSize.height)
        // Slightly above the largest texture scale we will ever ask for, so the
        // pieces are sharp without paying for pixels nothing samples.
        let target = longSide * 2.2
        return Int(clamp(target, 1400, 2800))
    }

    func refreshTextures(displayScale: CGFloat, settings: AppSettings) {
        guard let source else { return }
        textures.rebuild(geometry: geometry, source: source,
                         pixelScale: max(0.6, viewport.scale * displayScale),
                         outlines: settings.showPieceOutlines, cardboard: settings.cardboardPieces)
    }

    // MARK: - Clock

    private func startClock() {
        guard runningSince == nil else { return }
        runningSince = .now
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let runningSince else { return }
        elapsed = accumulated + Date.now.timeIntervalSince(runningSince)
    }

    private func stopClock() {
        if let runningSince {
            accumulated += Date.now.timeIntervalSince(runningSince)
            elapsed = accumulated
        }
        runningSince = nil
        ticker?.cancel()
        ticker = nil
    }

    func pause() {
        guard phase == .playing else { return }
        phase = .paused
        drag = nil
        stopClock()
        saveNow()
    }

    func resume() {
        guard phase == .paused, loadFailure == nil else { return }
        phase = .playing
        startClock()
    }

    /// Called when the app leaves the foreground — the clock must not keep
    /// running while the user is elsewhere.
    func handleBackground() {
        if phase == .playing { pause() }
        saveNow()
    }

    // MARK: - Draw order

    /// Groups from back to front. Solved-position clusters sink to the bottom so
    /// loose pieces are never hidden underneath the assembled area.
    var drawOrder: [Int32] {
        if let cache = drawOrderCache, cache.revision == state.structureRevision { return cache.order }
        let order = state.groups.values
            .sorted { lhs, rhs in
                if lhs.isHome != rhs.isHome { return lhs.isHome }
                return lhs.z < rhs.z
            }
            .map(\.id)
        drawOrderCache = (state.structureRevision, order)
        return order
    }

    func path(for piece: Int) -> CGPath {
        if let cached = paths[piece] { return cached }
        let path = geometry.localPath(of: piece)
        paths[piece] = path
        return path
    }

    // MARK: - Hit testing

    /// Piece under a board-space point, or `nil`.
    ///
    /// The exact outline wins when it belongs to a loose piece. Otherwise a
    /// loose piece is also caught by its square cell plus a finger's slack: a
    /// piece with four blanks is mostly holes, and a tap into one of them used
    /// to miss it (or grab the locked picture underneath, which cannot move).
    func piece(at point: CGPoint) -> Int32? {
        let order = drawOrder.reversed()
        var exact: Int32?
        outline: for groupID in order {
            guard let group = state.groups[groupID] else { continue }
            for piece in group.members {
                let local = point - (state.solvedOrigin(of: piece) + group.translation)
                guard textures.localBounds.indices.contains(Int(piece)),
                      textures.localBounds[Int(piece)].contains(local),
                      path(for: Int(piece)).contains(local) else { continue }
                exact = piece
                break outline
            }
        }
        if let exact, state.group(of: exact)?.isLocked == false { return exact }

        let slack = state.cellSize.minimumSide * 0.12
        let cell = CGRect(origin: .zero, size: state.cellSize).insetBy(dx: -slack, dy: -slack)
        for groupID in order {
            guard let group = state.groups[groupID], !group.isLocked else { continue }
            for piece in group.members
            where cell.contains(point - (state.solvedOrigin(of: piece) + group.translation)) {
                return piece
            }
        }
        return exact
    }

    // MARK: - Dragging

    /// Starts dragging the cluster under `point`. Returns `false` when there is
    /// nothing movable there — empty table or a cluster already locked in its
    /// solved position — so the gesture falls through to panning the board.
    @discardableResult
    func beginDrag(at point: CGPoint) -> Bool {
        guard phase == .playing, let piece = piece(at: point),
              let group = state.group(of: piece), !group.isLocked else { return false }
        pushUndo()
        state.bringToFront(group: group.id)
        selectedPiece = piece
        drag = DragState(group: group.id, grab: point, startTranslation: group.translation)
        return true
    }

    func updateDrag(to point: CGPoint) {
        guard var drag, phase == .playing else { return }
        let delta = point - drag.grab
        if abs(delta.x) + abs(delta.y) > 0.5 { drag.moved = true }
        self.drag = drag
        state.setTranslation(drag.startTranslation + delta, forGroup: drag.group)
    }

    /// Releases the dragged group and runs the snap/merge pass.
    @discardableResult
    func endDrag(viewScale: CGFloat, assist: SnapAssist) -> SettleOutcome? {
        guard let drag else { return nil }
        self.drag = nil
        guard drag.moved else {
            undoStack.removeLast()
            refreshUndoFlags()
            return nil
        }
        landing = Landing(pieces: Set(state.groups[drag.group]?.members ?? []), at: .now)
        let tolerance = state.snapTolerance(viewScale: viewScale, assist: assist.multiplier)
        let outcome = state.settle(group: drag.group, tolerance: tolerance)
        lastOutcome = outcome
        scheduleEffectsExpiry()
        if outcome.didSnap {
            let now = Date.now
            let pieces = outcome.connectedPieces.isEmpty
                ? (state.groups[outcome.group]?.members ?? [])
                : outcome.connectedPieces
            for piece in pieces { flashes[piece] = now }
            scheduleEffectsExpiry()
        }
        if outcome.didComplete { finish() }
        scheduleAutosave()
        return outcome
    }

    func cancelDrag() {
        guard let drag else { return }
        state.setTranslation(drag.startTranslation, forGroup: drag.group)
        self.drag = nil
        if !undoStack.isEmpty { undoStack.removeLast() }
        refreshUndoFlags()
    }

    /// Drops a tray piece onto the table at a board point.
    @discardableResult
    func placePieceFromTray(_ piece: Int32, at point: CGPoint,
                            viewScale: CGFloat, assist: SnapAssist) -> SettleOutcome? {
        guard phase == .playing else { return nil }
        pushUndo()
        let centre = state.solvedOrigin(of: piece) + CGPoint(x: geometry.cellSize.width / 2,
                                                             y: geometry.cellSize.height / 2)
        let translation = point - centre
        let group = state.placeFromTray(piece, translation: translation)
        selectedPiece = piece
        landing = Landing(pieces: [piece], at: .now)
        scheduleEffectsExpiry()
        let tolerance = state.snapTolerance(viewScale: viewScale, assist: assist.multiplier)
        let outcome = state.settle(group: group, tolerance: tolerance)
        lastOutcome = outcome
        if outcome.didSnap {
            let now = Date.now
            for connected in outcome.connectedPieces { flashes[connected] = now }
            flashes[piece] = now
            scheduleEffectsExpiry()
        }
        if outcome.didComplete { finish() }
        scheduleAutosave()
        return outcome
    }

    /// Sends a placed piece back to the tray (secondary click / long press).
    /// Locked pieces ignore the request.
    func returnPieceToTray(_ piece: Int32) {
        guard phase == .playing, let group = state.group(of: piece), !group.isLocked else { return }
        pushUndo()
        state.returnToTray(piece)
        if selectedPiece == piece { selectedPiece = nil }
        scheduleAutosave()
    }

    /// Empties the tray onto the table — the practical way to play 500+ pieces.
    func scatterTray() {
        guard phase == .playing, !state.trayOrder.isEmpty else { return }
        pushUndo()
        var rng = SplitMix64(seed: shuffleSeed &+ UInt64(state.trayOrder.count))
        state.scatterTray(in: tableRect, avoiding: boardRect, using: &rng)
        scheduleAutosave()
    }

    /// Sends every loose single piece on the table back to the tray.
    func gatherLoosePieces() {
        guard phase == .playing, state.hasLooseSingles else { return }
        pushUndo()
        state.gatherLooseSingles()
        if let selectedPiece, state.group(of: selectedPiece) == nil { self.selectedPiece = nil }
        scheduleAutosave()
    }

    /// The tray's two buttons: empty the tray onto the table, and send the
    /// loose pieces back. Each works whenever there is something to move.
    var canScatter: Bool { phase == .playing && !state.trayOrder.isEmpty }
    var canGather: Bool { phase == .playing && state.hasLooseSingles }

    // MARK: - Assistance

    /// Highlights where the selected (or a random unplaced) piece belongs.
    /// It never moves a piece — solving stays the player's job.
    func requestHint() {
        guard phase == .playing else { return }
        let candidate: Int32?
        if let selected = selectedPiece, state.group(of: selected)?.isHome != true {
            candidate = selected
        } else if let first = state.trayOrder.first {
            candidate = first
        } else {
            candidate = state.groups.values
                .filter { !$0.isHome }
                .min { $0.members.count < $1.members.count }?
                .members.first
        }
        guard let piece = candidate else { return }
        selectedPiece = piece
        hint = Hint(piece: piece, expires: .now.addingTimeInterval(3))
        scheduleEffectsExpiry()
    }

    func clearExpiredEffects(now: Date = .now) {
        if let hint, hint.expires < now { self.hint = nil }
        if let landing, now.timeIntervalSince(landing.at) >= Self.landingDuration { self.landing = nil }
        flashes = flashes.filter { now.timeIntervalSince($0.value) < Self.flashDuration }
        scheduleEffectsExpiry()
    }

    /// Flashes and the hint only carry an expiry date; something has to drop
    /// them once it passes. Without this `needsAnimationTicks` stayed true
    /// after the first snap and the board redrew at 120 Hz for the rest of
    /// the game.
    private func scheduleEffectsExpiry() {
        effectsTask?.cancel()
        let deadlines = flashes.values.map { $0.addingTimeInterval(Self.flashDuration) }
            + [hint?.expires, landing?.at.addingTimeInterval(Self.landingDuration)].compactMap { $0 }
        guard let next = deadlines.min() else {
            effectsTask = nil
            return
        }
        effectsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.clearExpiredEffects()
        }
    }

    static let flashDuration: TimeInterval = 0.85

    var needsAnimationTicks: Bool {
        !flashes.isEmpty || hint != nil || landing != nil || phase == .completed
    }

    // MARK: - Undo / redo

    private func pushUndo() {
        undoStack.append(state)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        drag = nil
        refreshUndoFlags()
        scheduleAutosave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        drag = nil
        refreshUndoFlags()
        scheduleAutosave()
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Completion

    private func finish() {
        stopClock()
        phase = .completed
        let lead = fitForFinale?() ?? 0
        completedAt = .now.addingTimeInterval(lead)
        finaleDone = false
        seams = geometry.seams
        var rng = SplitMix64(seed: geometry.seed &+ 0xF1AE)
        finaleRank = Array(repeating: 0, count: pieceCount)
        for (rank, piece) in rng.shuffled(Array(0..<pieceCount)).enumerated() {
            finaleRank[piece] = Double(rank) / Double(max(1, pieceCount))
        }
        let focusPiece = Int(selectedPiece ?? Int32(pieceCount / 2))
        finaleFocus = geometry.cellFrame(of: focusPiece).center
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finaleDuration + lead))
            self?.finaleDone = true
        }
        drag = nil
        hint = nil
        withAnimation(.spring(duration: 0.8)) {
            for id in state.groups.keys { state.setTranslation(.zero, forGroup: id) }
        }
        saveNow()
        onComplete?(self)
    }

    /// Starts the clock without loading pixels. Used by tests, which exercise
    /// placement logic without touching the rendering pipeline.
    func startForTesting() {
        phase = .playing
        startClock()
    }

    #if DEBUG
    /// Store screenshots: a staged solve takes seconds, which would read as
    /// "solved in 00:00:02" on the completion card.
    func debugAddPlayTime(_ seconds: TimeInterval) {
        accumulated += seconds
        tick()
    }
    #endif

    /// Debug/test helper used by the "solve" menu command.
    func solveImmediately() {
        pushUndo()
        state.solveAll()
        finish()
    }

    // MARK: - Persistence

    func snapshot() -> GameSnapshot {
        GameSnapshot(id: id, itemID: item.id, itemTitle: item.title, source: item.source,
                     imageAspect: item.aspect, puzzleAspect: puzzleAspect,
                     targetPieces: targetPieces, columns: geometry.columns, rows: geometry.rows,
                     seed: geometry.seed, elapsed: elapsed, state: state,
                     updatedAt: .now, isComplete: phase == .completed)
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        autosaveTask?.cancel()
        autosaveTask = nil
        try? saveStore.save(snapshot())
    }
}
