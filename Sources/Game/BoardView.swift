import CoreGraphics
import ImageIO
import SwiftUI

/// Bridges native pointer events to the session, and owns viewport policy.
@MainActor
@Observable
final class BoardInputController: BoardEventHandling {
    var session: GameSession? {
        didSet { session?.fitForFinale = { [weak self] in self?.glideToBoard() ?? 0 } }
    }
    var settings: AppSettings?
    var viewSize: CGSize = .zero
    var displayScale: CGFloat = 2
    private(set) var hoverPoint: CGPoint?

    @ObservationIgnored private var textureRefresh: Task<Void, Never>?
    @ObservationIgnored private var refit: Task<Void, Never>?
    /// The view size the board was last fitted to; a flip of its aspect is a rotation.
    @ObservationIgnored private var fittedSize: CGSize = .zero

    func boardPointerDown(at point: CGPoint, isSecondary: Bool) -> Bool {
        guard let session, session.phase == .playing else { return false }
        let boardPoint = session.viewport.board(point)
        if isSecondary {
            if let piece = session.piece(at: boardPoint) { session.returnPieceToTray(piece) }
            return false
        }
        return session.beginDrag(at: boardPoint)
    }

    func boardPointerMoved(to point: CGPoint) {
        guard let session else { return }
        session.updateDrag(to: session.viewport.board(point))
    }

    func boardPointerUp(at point: CGPoint) {
        guard let session, let settings else { return }
        session.updateDrag(to: session.viewport.board(point))
        let outcome = session.endDrag(viewScale: session.viewport.scale, assist: settings.snapAssist)
        Feedback.shared.report(outcome, streak: session.isOnStreak, at: point, settings: settings)
    }

    func boardPointerCancelled() {
        session?.cancelDrag()
    }

    func boardPan(by delta: CGSize) {
        guard let session else { return }
        session.viewport = session.viewport.panned(by: delta)
            .clamped(content: session.tableRect, viewSize: viewSize)
    }

    func boardZoom(by factor: CGFloat, at point: CGPoint) {
        guard let session, factor.isFinite, factor > 0 else { return }
        session.viewport = session.viewport.zoomed(by: factor, around: point)
            .clamped(content: session.tableRect, viewSize: viewSize)
        scheduleTextureRefresh()
    }

    func boardHover(at point: CGPoint?) { hoverPoint = point }

    /// Pulls the table back into view after the board changes size.
    ///
    /// Panning and zooming clamp themselves, but a resize used to leave the
    /// viewport untouched: shrink the window while the board sits near an edge
    /// and every piece ends up outside the visible rect, with only "Fit" to get
    /// them back. iPadOS 27 resizes windows continuously, so this now runs for
    /// every frame of a resize drag — it may only nudge the offset. Re-fitting
    /// here would rescale the board under the player's hands.
    func handleResize() {
        guard let session, viewSize.width > 1, viewSize.height > 1 else { return }
        let adjusted = session.viewport.clamped(content: session.tableRect, viewSize: viewSize)
        // `Viewport` is `Equatable`; skipping the no-op write keeps a resize
        // drag from invalidating the board on every frame.
        if adjusted != session.viewport { session.viewport = adjusted }
        // Turning the device swaps the axes, which leaves the picture mostly
        // off screen. Rotation arrives as several sizes, so fit once it settles.
        if (fittedSize.width > fittedSize.height) != (viewSize.width > viewSize.height) {
            refit?.cancel()
            refit = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                fitBoard()
            }
        }
    }

    func fitBoard(padding: CGFloat = 40) {
        guard let session, viewSize.width > 1 else { return }
        session.viewport = .fitting(content: session.boardRect, in: viewSize, padding: padding)
        fittedSize = viewSize
        scheduleTextureRefresh()
    }

    /// Glides back to the whole picture for the finale, in log scale around
    /// the view centre so a deep zoom pulls out evenly. Returns how long it takes.
    func glideToBoard() -> TimeInterval {
        guard let session, viewSize.width > 1 else { return 0 }
        let from = session.viewport
        let to = Viewport.fitting(content: session.boardRect, in: viewSize, padding: 40)
        fittedSize = viewSize
        let ratio = abs(log(to.scale / from.scale))
        let shift = hypot(to.offset.width - from.offset.width, to.offset.height - from.offset.height)
        guard ratio > 0.02 || shift > 4 else { return 0 }
        let duration = clamp(0.5 + ratio * 0.25, 0.6, 1.1)
        let centre = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let a = from.board(centre), b = to.board(centre)
        refit?.cancel()
        refit = Task { [weak self] in
            let start = Date.now
            while !Task.isCancelled, let session = self?.session {
                let u = min(1, Date.now.timeIntervalSince(start) / duration)
                let e = CGFloat(u * u * (3 - 2 * u))
                let scale = from.scale * exp(log(to.scale / from.scale) * e)
                let c = a + (b - a) * e
                session.viewport = Viewport(scale: scale, offset: CGSize(width: centre.x - c.x * scale,
                                                                         height: centre.y - c.y * scale))
                if u >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            self?.scheduleTextureRefresh()
        }
        return duration
    }

    func fitTable() {
        guard let session, viewSize.width > 1 else { return }
        session.viewport = .fitting(content: session.tableRect, in: viewSize, padding: 16)
        fittedSize = viewSize
        scheduleTextureRefresh()
    }

    func zoomStep(_ factor: CGFloat) {
        boardZoom(by: factor, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    /// Re-cuts the piece bitmaps once the user stops zooming, so a magnified
    /// board stays crisp without re-rendering on every wheel tick.
    private func scheduleTextureRefresh() {
        textureRefresh?.cancel()
        textureRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let session, let settings else { return }
            session.refreshTextures(displayScale: displayScale, settings: settings)
        }
    }
}

/// The puzzle surface: one `Canvas` for the pieces, one native view for input.
struct BoardView: View {
    let session: GameSession
    let settings: AppSettings
    let controller: BoardInputController

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                boardCanvas
                BoardEventView(handler: controller)
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                let wasEmpty = controller.viewSize.width < 1
                controller.viewSize = size
                controller.displayScale = displayScale
                if wasEmpty { controller.fitBoard() } else { controller.handleResize() }
            }
            .onAppear {
                controller.session = session
                controller.settings = settings
                controller.viewSize = proxy.size
                controller.displayScale = displayScale
                if session.viewport.scale == 1 { controller.fitBoard() }
            }
        }
        .background(BoardBackdrop(table: settings.table))
        .accessibilityElement()
        .accessibilityLabel(Text("Puzzle board"))
        .accessibilityValue(Text("\(session.placedCount) of \(session.pieceCount) pieces placed"))
    }

    private var boardCanvas: some View {
        // Runs at the display's own rate: 120 Hz on ProMotion (the phone also
        // needs CADisableMinimumFrameDurationOnPhone in the Info.plist).
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !session.needsAnimationTicks)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let viewport = session.viewport
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -60, dy: -60)
        let textures = session.textures

        // Board plate: where the finished picture belongs.
        let plateRect = viewport.screen(session.boardRect)
        let corner = min(14, max(2, 10 * viewport.scale))
        let plate = Path(roundedRect: plateRect, cornerRadius: corner)
        context.fill(plate, with: .color(Theme.text.opacity(0.06)))

        if settings.showGhostImage, let ghost = session.ghostImage {
            // Strong enough to guide, faint enough that a placed piece still
            // reads as clearly "on top of" the empty board.
            var ghostLayer = context
            ghostLayer.opacity = 0.2
            ghostLayer.clip(to: plate)
            ghostLayer.draw(ghost, in: plateRect)
        }
        context.stroke(plate, with: .color(Theme.text.opacity(0.12)), lineWidth: 2)

        guard !textures.images.isEmpty else { return }

        let landing = session.landing.flatMap { landing -> (GameSession.Landing, Double)? in
            let u = now.timeIntervalSince(landing.at) / GameSession.landingDuration
            return u < 1 ? (landing, u) : nil
        }
        // A loose piece under a hovering Pencil (or pointer) rises a hair.
        let hover = controller.hoverPoint
        let hovered = hover.flatMap { point -> Int32? in
            guard session.phase == .playing, session.drag == nil,
                  let piece = session.piece(at: viewport.board(point)),
                  let group = session.state.group(of: piece), !group.isLocked else { return nil }
            return group.id
        }
        for groupID in session.drawOrder {
            guard let group = session.state.groups[groupID] else { continue }

            if groupID == hovered, let hover {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3))
                    layer.translateBy(x: hover.x, y: hover.y)
                    layer.scaleBy(x: GameSession.liftScale, y: GameSession.liftScale)
                    layer.translateBy(x: -hover.x, y: -hover.y)
                    drawPieces(of: group, in: &layer, viewport: viewport, size: size, now: now,
                               visible: visible, textures: textures, skipping: landing?.0.pieces ?? [])
                }
            } else if let drag = session.drag, drag.group == groupID {
                // Held: a touch larger around the finger, over one soft, wide
                // shadow for the whole cluster, so it reads as a lifted object.
                let finger = viewport.screen(drag.grab + group.translation - drag.startTranslation)
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 11))
                    layer.translateBy(x: finger.x, y: finger.y)
                    layer.scaleBy(x: GameSession.liftScale, y: GameSession.liftScale)
                    layer.translateBy(x: -finger.x, y: -finger.y)
                    drawPieces(of: group, in: &layer, viewport: viewport, size: size, now: now,
                               visible: visible, textures: textures)
                }
            } else {
                drawPieces(of: group, in: &context, viewport: viewport, size: size, now: now,
                           visible: visible, textures: textures, skipping: landing?.0.pieces ?? [])
            }
        }
        if let (landing, u) = landing {
            drawLanding(landing.pieces, progress: u, in: &context, viewport: viewport, textures: textures)
        }

        drawFlashes(in: &context, viewport: viewport, visible: visible, textures: textures, now: now)
        drawHint(in: &context, viewport: viewport, now: now)
        drawFinale(in: &context, plate: plate, plateRect: plateRect, viewport: viewport, now: now)
    }

    /// The finished picture: light runs along the seams from the edges in to
    /// the last piece placed and flashes there, the seams melt into one
    /// photograph, then a soft band of light crosses it corner to corner.
    private func drawFinale(in context: inout GraphicsContext, plate: Path, plateRect: CGRect,
                            viewport: Viewport, now: Date) {
        guard let start = session.completedAt, let photo = session.ghostImage else { return }
        let t = now.timeIntervalSince(start) - GameSession.reassembly
        func ease(_ from: Double, _ to: Double) -> Double {
            let u = clamp((t - from) / (to - from), 0, 1)
            return u * u * (3 - 2 * u)
        }
        let focus = session.finaleFocus
        let glowColor = Color(red: 1, green: 0.93, blue: 0.75)
        if t < 2.6 {
            let toScreen = CGAffineTransform(scaleX: viewport.scale, y: viewport.scale)
                .concatenating(CGAffineTransform(translationX: viewport.offset.width, y: viewport.offset.height))
            let reach = session.seams.map { $0.mid.distance(to: focus) }.max() ?? 1
            let width = max(2, session.geometry.cellSize.minimumSide * viewport.scale * 0.07)
            var glow = context
            glow.clip(to: plate)
            glow.blendMode = .plusLighter
            for seam in session.seams {
                // The farthest seams light first; the wave closes in on the focus.
                let arrival = 0.3 + 1.8 * (1 - seam.mid.distance(to: focus) / max(reach, 1))
                let lit = exp(-pow((t - arrival) / 0.2, 2))
                guard lit > 0.03 else { continue }
                let line = Path(seam.path).applying(toScreen)
                glow.stroke(line, with: .color(glowColor.opacity(0.35 * lit)), lineWidth: width * 3)
                glow.stroke(line, with: .color(glowColor.opacity(0.95 * lit)), lineWidth: width)
            }
        }

        var layer = context
        layer.clip(to: plate)
        layer.opacity = ease(2.1, 2.6)
        layer.draw(photo, in: plateRect)

        // Where the light meets: a soft flash that blooms and fades.
        let bloom = ease(2.05, 2.3) * (1 - ease(2.4, 2.9))
        if bloom > 0 {
            let centre = viewport.screen(focus)
            let radius = max(plateRect.width, plateRect.height) * (0.15 + 0.45 * ease(2.05, 2.9))
            var flash = context
            flash.clip(to: plate)
            flash.blendMode = .plusLighter
            flash.fill(plate, with: .radialGradient(
                Gradient(colors: [glowColor.opacity(0.85 * bloom), glowColor.opacity(0)]),
                center: centre, startRadius: 0, endRadius: radius))
        }

        let sweep = ease(2.6, 3.8)
        guard sweep > 0, sweep < 1 else { return }
        let along = { (u: Double) in
            CGPoint(x: plateRect.minX + plateRect.width * u, y: plateRect.minY + plateRect.height * u)
        }
        let centre = -0.25 + 1.5 * sweep
        var light = context
        light.clip(to: plate)
        light.blendMode = .plusLighter
        light.fill(plate, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                             .init(color: .white.opacity(0.45), location: 0.5),
                             .init(color: .white.opacity(0), location: 1)]),
            startPoint: along(centre - 0.18), endPoint: along(centre + 0.18)))
    }

    private func drawPieces(of group: PieceGroup, in context: inout GraphicsContext,
                            viewport: Viewport, size: CGSize, now: Date,
                            visible: CGRect, textures: PieceTextureStore, skipping: Set<Int32> = []) {
        // The finale's break-up: pieces scatter over what is on screen.
        let breakUp = session.completedAt.map { now.timeIntervalSince($0) }
            .flatMap { $0 < GameSession.reassembly ? $0 : nil }
        let cell = session.geometry.cellSize
        let scatter = CGRect(origin: viewport.board(.zero), size: size * (1 / viewport.scale))
            .insetBy(dx: cell.width * 0.7, dy: cell.height * 0.7)
        for piece in group.members where !skipping.contains(piece) {
            let index = Int(piece)
            guard index < textures.images.count, let image = textures.images[index] else { continue }
            var origin = session.state.solvedOrigin(of: piece) + group.translation
            if let breakUp {
                origin += finaleOffset(piece, at: breakUp, scatter: scatter, home: origin)
            }
            let rect = viewport.screen(textures.localBounds[index].offsetBy(origin))
            guard rect.intersects(visible) else { continue }
            context.draw(image, in: rect)
        }
    }

    /// Pieces just put down, drawn on top: they shrink from the lifted size,
    /// dip a hair below it and come to rest while the shadow fades out.
    private func drawLanding(_ pieces: Set<Int32>, progress u: Double, in context: inout GraphicsContext,
                             viewport: Viewport, textures: PieceTextureStore) {
        let rects = pieces.compactMap { piece -> (Image, CGRect)? in
            let index = Int(piece)
            guard index < textures.images.count, let image = textures.images[index],
                  let group = session.state.group(of: piece) else { return nil }
            return (image, viewport.screen(textures.localBounds[index]
                .offsetBy(session.state.solvedOrigin(of: piece) + group.translation)))
        }
        guard let first = rects.first?.1 else { return }
        let centre = rects.reduce(first) { $0.union($1.1) }.center
        let scale = 1 + (GameSession.liftScale - 1) * cos(u * .pi * 1.5) * (1 - u)
        context.drawLayer { layer in
            let fade = 1 - u
            layer.addFilter(.shadow(color: .black.opacity(0.3 * fade), radius: 2 + 14 * fade, x: 0, y: 1 + 10 * fade))
            layer.translateBy(x: centre.x, y: centre.y)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -centre.x, y: -centre.y)
            for (image, rect) in rects { layer.draw(image, in: rect) }
        }
    }

    /// Where a piece is during the reassembly, relative to its home: a beat
    /// in place, a burst out to a random spot on screen, then home again one
    /// piece after another in shuffled order.
    private func finaleOffset(_ piece: Int32, at t: Double, scatter: CGRect, home: CGPoint) -> CGPoint {
        func ease(_ from: Double, _ to: Double) -> Double {
            let u = clamp((t - from) / (to - from), 0, 1)
            return u * u * (3 - 2 * u)
        }
        var rng = SplitMix64(seed: mixSeed(session.geometry.seed, UInt64(piece), 0xB10))
        let spot = rng.point(in: scatter) - CGPoint(x: session.geometry.cellSize.width / 2,
                                                    y: session.geometry.cellSize.height / 2)
        let away = spot - home
        let out = 1 - pow(1 - clamp((t - 0.5) / 0.6, 0, 1), 3)
        let flight = GameSession.reassemblyFlight(rank: session.finaleRank[safe: Int(piece)] ?? 0)
        let back = ease(flight.start, flight.end)
        return away * CGFloat(out * (1 - back))
    }

    private func drawFlashes(in context: inout GraphicsContext, viewport: Viewport,
                             visible: CGRect, textures: PieceTextureStore, now: Date) {
        guard !session.flashes.isEmpty else { return }
        for (piece, start) in session.flashes {
            let progress = now.timeIntervalSince(start) / GameSession.flashDuration
            guard progress >= 0, progress < 1 else { continue }
            let index = Int(piece)
            guard index < textures.images.count, let image = textures.images[index],
                  let group = session.state.group(of: piece) else { continue }
            let rect = viewport.screen(
                textures.localBounds[index].offsetBy(session.state.solvedOrigin(of: piece) + group.translation))
            guard rect.intersects(visible) else { continue }
            var glow = context
            glow.blendMode = .plusLighter
            glow.opacity = (1 - progress) * 0.7
            glow.addFilter(.colorMultiply(Theme.sage))
            glow.draw(image, in: rect)
            // The snap ring: a sage stroke that swells and fades.
            let ring = Path(roundedRect: rect.insetBy(dx: -4 - 10 * progress, dy: -4 - 10 * progress),
                            cornerRadius: 16)
            context.stroke(ring, with: .color(Theme.sage.opacity((1 - progress) * 0.9)), lineWidth: 5)
        }
    }

    private func drawHint(in context: inout GraphicsContext, viewport: Viewport, now: Date) {
        guard let hint = session.hint, now < hint.expires else { return }
        let piece = hint.piece
        let origin = session.state.solvedOrigin(of: piece)
        let transform = CGAffineTransform(translationX: origin.x, y: origin.y)
            .concatenating(CGAffineTransform(scaleX: viewport.scale, y: viewport.scale))
            .concatenating(CGAffineTransform(translationX: viewport.offset.width,
                                             y: viewport.offset.height))
        let outline = Path(session.path(for: Int(piece))).applying(transform)
        let pulse = 0.55 + 0.45 * sin(now.timeIntervalSinceReferenceDate * 6)

        context.fill(outline, with: .color(Theme.accent.opacity(0.18 * pulse)))
        context.stroke(outline, with: .color(Theme.accent.opacity(0.18 * pulse)), lineWidth: 12)
        context.stroke(outline, with: .color(Theme.accent.opacity(0.55 + 0.45 * pulse)), lineWidth: 4)

        // Trace from the piece's current spot to where it belongs.
        if let group = session.state.group(of: piece) {
            let from = viewport.screen(origin + group.translation
                + CGPoint(x: session.geometry.cellSize.width / 2,
                          y: session.geometry.cellSize.height / 2))
            let to = viewport.screen(origin + CGPoint(x: session.geometry.cellSize.width / 2,
                                                      y: session.geometry.cellSize.height / 2))
            var line = Path()
            line.move(to: from)
            line.addLine(to: to)
            context.stroke(line, with: .color(Theme.accent.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
        }
    }
}

/// The warm table behind the puzzle, with two soft circles for air.
/// Or the chosen table surface, tiled; dimmed in dark mode.
private struct BoardBackdrop: View {
    let table: AppSettings.TableSurface
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.bg
            if let tile = Self.tile(table) {
                Image(decorative: tile, scale: 2).resizable(resizingMode: .tile)
                if colorScheme == .dark { Color.black.opacity(0.55) }
            } else {
                GeometryReader { proxy in
                    Blob(size: 340).opacity(0.8)
                        .position(x: 80, y: proxy.size.height + 50)
                    Blob(color: Theme.blob2, size: 200).opacity(0.7)
                        .position(x: proxy.size.width - 160, y: 20)
                }
            }
        }
        .clipped()
        .ignoresSafeArea()
    }
}

extension BoardBackdrop {
    /// `table-<surface>.jpg` from `Scripts/make-table-textures.swift`, decoded once.
    private static var tiles: [AppSettings.TableSurface: CGImage] = [:]

    static func tile(_ table: AppSettings.TableSurface) -> CGImage? {
        guard table != .plain else { return nil }
        if let cached = tiles[table] { return cached }
        guard let url = Bundle.main.url(forResource: "table-\(table.rawValue)", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        tiles[table] = image
        return image
    }
}
