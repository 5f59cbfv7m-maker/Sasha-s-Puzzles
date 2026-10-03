import SwiftUI

/// Where the unplaced pieces live for the current window shape.
enum TrayPlacement { case trailing, bottom }

/// The playing screen: board, tray, HUD and overlays.
struct GameView: View {
    let session: GameSession

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isCompact) private var isCompact

    private var controller: BoardInputController { model.boardController }
    @State private var trayDrag = TrayDragState()
    @State private var showOriginal = false
    @State private var didLoad = false

    /// The piece on its way out of the tray. Its own observable so each move
    /// re-renders the ghost alone rather than the whole screen — an 800-cell
    /// tray grid re-diffed per touch sample is what made drags stutter.
    @Observable @MainActor
    final class TrayDragState {
        var piece: Int32?
        var location: CGPoint = .zero
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.hairline.frame(height: 1)
            content
        }
        .background(Theme.bg.ignoresSafeArea())
        .task(id: session.id) {
            guard !didLoad else { return }
            didLoad = true
            await session.load(displayScale: displayScale, settings: settings,
                               isNewGame: session.placedCount == 0 && session.elapsed == 0)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.handleBackground() }
        }
        .onDisappear { session.saveNow() }
        .task(id: session.completedAt) { await reassemblyClicks() }
        .sheet(isPresented: $showOriginal) { OriginalImageSheet(session: session) }
    }

    private var content: some View {
        GeometryReader { proxy in
            let placement: TrayPlacement = trayPlacement(for: proxy.size)

            ZStack {
                Group {
                    if placement == .trailing {
                        HStack(spacing: 0) {
                            board
                            Theme.hairline.frame(width: 1)
                            tray(placement: placement, in: proxy.size)
                                .frame(width: trayThickness(for: proxy.size))
                        }
                    } else {
                        VStack(spacing: 0) {
                            board
                            Theme.hairline.frame(height: 1)
                            tray(placement: placement, in: proxy.size)
                                .frame(height: trayThickness(for: proxy.size))
                        }
                    }
                }

                overlays
                TrayGhost(session: session, drag: trayDrag)
            }
            .coordinateSpace(.named("game"))
        }
    }

    // MARK: - Pieces

    /// Zoom buttons only on the Mac: on a touch screen everyone pinches, and
    /// the panel covered the board's corner on a phone.
    private var board: some View {
        BoardView(session: session, settings: settings, controller: controller)
        #if os(macOS)
            .overlay(alignment: .bottomTrailing) { zoomControls.padding(18) }
        #endif
    }

    /// The board fills the game space up to the tray, so its frame is derived
    /// from the layout numbers rather than measured: a measured frame goes
    /// stale during the rotation animation and rejects drops on half the board.
    private func tray(placement: TrayPlacement, in size: CGSize) -> some View {
        let thickness = trayThickness(for: size)
        let boardFrame = CGRect(origin: .zero, size: placement == .trailing
                                ? CGSize(width: size.width - thickness, height: size.height)
                                : CGSize(width: size.width, height: size.height - thickness))
        let drag = trayDrag
        return TrayView(session: session, placement: placement, thickness: thickness) { piece, location in
            drag.piece = piece
            drag.location = location
        } onEnded: { piece, location in
            drag.piece = nil
            guard boardFrame.contains(location) else { return }
            let boardPoint = session.viewport.board(location)
            let outcome = session.placePieceFromTray(piece, at: boardPoint,
                                                     viewScale: session.viewport.scale,
                                                     assist: settings.snapAssist)
            Feedback.shared.report(outcome, streak: session.isOnStreak, settings: settings)
        }
    }

    /// Progress and clock, in the header so the board keeps its whole area.
    /// A phone-wide header stacks them small; a tight wide one drops the bar
    /// before it would squeeze the title.
    private var statusChip: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 1) {
                    clockLabel
                    progressLabel
                }
                .font(Theme.body(12, .bold).monospacedDigit())
                .padding(.horizontal, 10).padding(.vertical, 4)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        progressLabel
                        solveProgress
                        Theme.track.frame(width: 1, height: 16)
                        clockLabel
                    }
                    HStack(spacing: 10) {
                        progressLabel
                        Theme.track.frame(width: 1, height: 16)
                        clockLabel
                    }
                }
                .font(Theme.body(15, .bold).monospacedDigit())
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
        .foregroundStyle(Theme.muted)
        .background(Theme.chip, in: Capsule())
        .fixedSize(horizontal: isCompact, vertical: false)
        .layoutPriority(1)
    }

    private var clockLabel: some View {
        HStack(spacing: isCompact ? 4 : 7) {
            Image(systemName: "clock").font(.system(size: isCompact ? 10 : 13, weight: .bold)).foregroundStyle(Theme.accent)
            Text(TimeFormatting.clock(session.elapsed)).foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Elapsed time"))
        .accessibilityValue(Text(TimeFormatting.spoken(session.elapsed)))
    }

    /// Fraction of pieces that are joined to at least one neighbour — a truer
    /// measure of progress than "taken out of the tray".
    private var solveProgress: some View {
        ProgressBar(value: session.completion)
            .frame(width: 80)
            .accessibilityLabel(Text("Pieces placed"))
    }

    private var progressLabel: some View {
        HStack(spacing: isCompact ? 4 : 7) {
            Image(systemName: "puzzlepiece").font(.system(size: isCompact ? 10 : 13, weight: .bold)).foregroundStyle(Theme.sage)
            Text("\(session.placedCount)/\(session.pieceCount)").foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pieces placed"))
        .accessibilityValue(Text("\(session.placedCount) of \(session.pieceCount)"))
    }

    #if os(macOS)
    private var zoomControls: some View {
        VStack(spacing: 6) {
            zoomButton("plus", "Zoom in") { controller.zoomStep(1.25) }
            zoomButton("minus", "Zoom out") { controller.zoomStep(0.8) }
            Theme.track.frame(width: 24, height: 1).padding(.vertical, 2)
            zoomButton("rectangle.center.inset.filled", "Fit board") { controller.fitBoard() }
            zoomButton("arrow.up.left.and.arrow.down.right", "Fit table") { controller.fitTable() }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
    }

    private func zoomButton(_ symbol: String, _ label: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(label))
    }
    #endif

    // MARK: - Header

    /// Back, title, progress and clock, and the action chips. A phone-wide header keeps hint
    /// and pause on the surface and folds the rest into one menu.
    private var header: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            RoundIconButton(symbol: "chevron.left", size: 42) { model.showLibrary() }
                .accessibilityLabel(Text("Back to Library"))
            Text(session.item.title)
                .font(Theme.display(20))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            statusChip
            HStack(spacing: 6) {
                RoundIconButton(symbol: "lightbulb", style: .sage, size: 42) { session.requestHint() }
                    .disabled(session.phase != .playing)
                    .accessibilityLabel(Text("Hint"))
                if isCompact {
                    Menu {
                        Button { showOriginal = true } label: { Label("Show Original", systemImage: "photo") }
                        Divider()
                        undoRedoButtons
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 42, height: 42)
                            .background(Theme.chip, in: Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Text("Actions"))
                } else {
                    RoundIconButton(symbol: "photo", size: 42) { showOriginal = true }
                        .accessibilityLabel(Text("Show Original"))
                    RoundIconButton(symbol: "arrow.uturn.backward", size: 42) { session.undo() }
                        .disabled(!session.canUndo)
                        .accessibilityLabel(Text("Undo"))
                    RoundIconButton(symbol: "arrow.uturn.forward", size: 42) { session.redo() }
                        .disabled(!session.canRedo)
                        .accessibilityLabel(Text("Redo"))
                }
                pauseButton
            }
        }
        .padding(.horizontal, isCompact ? 12 : 22)
        .frame(height: isCompact ? 56 : 70)
        .background(Theme.card.ignoresSafeArea())
    }

    @ViewBuilder
    private var undoRedoButtons: some View {
        Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .disabled(!session.canUndo)
        Button { session.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .disabled(!session.canRedo)
    }

    private var pauseButton: some View {
        let paused = session.phase == .paused
        return Button {
            paused ? session.resume() : session.pause()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                if !isCompact { Text(paused ? "Resume" : "Pause").lineLimit(1) }
            }
            .fixedSize()
            .font(Theme.body(15, .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(minWidth: 42, minHeight: 42)
            .padding(.horizontal, isCompact ? 0 : 16)
            .background(Theme.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(session.phase == .completed)
        .accessibilityLabel(Text(paused ? "Resume" : "Pause"))
    }

    /// A quiet tap as each piece lands home in the finale's reassembly,
    /// thinned out so a big puzzle ticks rather than buzzes.
    private func reassemblyClicks() async {
        guard let start = session.completedAt else { return }
        let landings = session.finaleRank.map { GameSession.reassemblyFlight(rank: $0).end }.sorted()
        var last = -1.0
        for time in landings where time - last >= 0.07 {
            last = time
            let wait = start.addingTimeInterval(time).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if Task.isCancelled { return }
            Feedback.shared.play(.snap, volume: 0.3, settings: settings)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlays: some View {
        if !session.isLoaded || session.textures.progress < 1 {
            LoadingOverlay(session: session)
        }
        if let failure = session.loadFailure {
            ErrorOverlay(message: failure) { model.showLibrary() }
        }
        if session.phase == .paused, session.loadFailure == nil {
            PauseOverlay(session: session)
        }
        if session.phase == .completed, session.finaleDone {
            CompletionOverlay(session: session)
                .transition(.opacity)
        }
    }

    // MARK: - Layout policy

    private func trayPlacement(for size: CGSize) -> TrayPlacement {
        #if DEBUG
        // Lets the stage driver photograph the landscape layout on a portrait simulator.
        if CommandLine.arguments.contains("--tray-trailing") { return .trailing }
        #endif
        #if os(macOS)
        return size.width >= 720 ? .trailing : .bottom
        #else
        return size.width > size.height && size.width >= 700 ? .trailing : .bottom
        #endif
    }

    private func trayThickness(for size: CGSize) -> CGFloat {
        trayPlacement(for: size) == .trailing
            ? TrayView.trailingWidth(viewWidth: size.width) : clamp(size.height * 0.2, 130, 220)
    }

}

private struct TrayGhost: View {
    let session: GameSession
    let drag: GameView.TrayDragState

    var body: some View {
        if let piece = drag.piece, let image = session.textures.images[safe: Int(piece)] ?? nil,
           let bounds = session.textures.localBounds[safe: Int(piece)] {
            // The size it will have on the board, barely lifted, so it can be
            // lined up exactly; only a very zoomed-out board gets a floor of
            // 44 pt so the piece is not lost under the finger.
            let cell = session.geometry.cellSize
            let scale = max(session.viewport.scale, 44 / cell.minimumSide) * GameSession.liftScale
            image
                .resizable()
                .frame(width: bounds.width * scale, height: bounds.height * scale)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 11)
                // The drop puts the cell's centre under the finger; so does the ghost.
                .position(x: drag.location.x + (bounds.midX - cell.width / 2) * scale,
                          y: drag.location.y + (bounds.midY - cell.height / 2) * scale)
                .allowsHitTesting(false)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum TimeFormatting {
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// `m:ss`, for differences that are never hours long.
    static func short(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func spoken(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: max(0, interval)) ?? clock(interval)
    }
}
