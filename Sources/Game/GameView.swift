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
    #if os(iOS)
    @Environment(\.preferredPencilSqueezeAction) private var squeezeAction
    @Environment(\.preferredPencilDoubleTapAction) private var doubleTapAction
    #endif

    @State private var headerWidth: CGFloat = .infinity
    /// A Duo standing as a laptop is 669 pt across: the full row would
    /// squeeze the title down to an ellipsis, so the bar and the side actions go.
    private var isTightHeader: Bool { isCompact || headerWidth < 780 }

    private var controller: BoardInputController { model.boardController }
    @State private var trayDrag = TrayDragState()
    @State private var showOriginal = false
    @State private var didLoad = false
    /// iPhone Duo standing half open, like a book or a laptop.
    @State private var isHalfOpen = Self.forcedHalfOpen

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
            // The photo frame has the screen to itself.
            if !isFramed {
                header
                Theme.hairline.frame(height: 1)
            }
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
        #if os(iOS)
        .modifier(HingeReader(isHalfOpen: $isHalfOpen, isForced: Self.forcedHalfOpen))
        #endif
        .sheet(isPresented: $showOriginal) { OriginalImageSheet(session: session) }
        #if os(iOS)
        // Apple Pencil Pro: squeeze for a hint, double tap to undo — unless
        // the player turned the gesture off in Settings → Apple Pencil.
        .onPencilSqueeze { phase in
            if case .ended = phase, squeezeAction != .ignore { session.requestHint() }
        }
        .onPencilDoubleTap { _ in
            if doubleTapAction != .ignore, session.phase == .playing { session.undo() }
        }
        #endif
    }

    private var content: some View {
        GeometryReader { proxy in
            let page = foldPage(for: proxy.size, at: proxy.frame(in: .global).origin)
            let placement: TrayPlacement = page == nil ? trayPlacement(for: proxy.size)
                : proxy.size.width > proxy.size.height ? .trailing : .bottom
            let thickness = page ?? trayThickness(for: proxy.size)
            let framed = isFramed && page != nil

            ZStack {
                if framed {
                    framedLayout(placement: placement, page: thickness, in: proxy.size)
                } else if placement == .trailing {
                    HStack(spacing: 0) {
                        board
                        Theme.hairline.frame(width: 1)
                        tray(placement: placement, thickness: thickness, in: proxy.size)
                            .frame(width: thickness)
                    }
                } else {
                    VStack(spacing: 0) {
                        board
                        Theme.hairline.frame(height: 1)
                        tray(placement: placement, thickness: thickness, in: proxy.size)
                            .frame(height: thickness)
                    }
                }

                overlays(framed: framed)
                TrayGhost(session: session, drag: trayDrag)
            }
            .coordinateSpace(.named("game"))
        }
    }

    // MARK: - Pieces

    private var board: some View {
        BoardView(session: session, settings: settings, controller: controller)
            .overlay(alignment: .top) {
                if let table = model.table, table.session === session { TableRoster(table: table).padding(.top, 10) }
            }
    }

    /// The board fills the game space up to the tray, so its frame is derived
    /// from the layout numbers rather than measured: a measured frame goes
    /// stale during the rotation animation and rejects drops on half the board.
    private func tray(placement: TrayPlacement, thickness: CGFloat, in size: CGSize) -> some View {
        let boardFrame = CGRect(origin: .zero, size: placement == .trailing
                                ? CGSize(width: size.width - thickness, height: size.height)
                                : CGSize(width: size.width, height: size.height - thickness))
        let drag = trayDrag
        return TrayView(session: session, placement: placement, thickness: thickness) { piece, location in
            drag.piece = piece
            drag.location = location
            // Partners see it once it is over the board.
            if boardFrame.contains(location) { session.trayDragMoved(piece, to: session.viewport.board(location)) }
        } onEnded: { piece, location in
            drag.piece = nil
            guard boardFrame.contains(location) else { return session.trayDragCancelled(piece) }
            let boardPoint = session.viewport.board(location)
            let outcome = session.placePieceFromTray(piece, at: boardPoint,
                                                     viewScale: session.viewport.scale,
                                                     assist: settings.snapAssist)
            Feedback.shared.report(outcome, streak: session.isOnStreak, at: location, settings: settings)
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
                        if !isTightHeader { solveProgress }
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
    /// Zoom only on the Mac, in the header out of the way of the pieces: on a
    /// touch screen everyone pinches.
    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton("minus", "Zoom out") { controller.zoomStep(0.8) }
            zoomButton("plus", "Zoom in") { controller.zoomStep(1.25) }
            Theme.track.frame(width: 1, height: 16).padding(.horizontal, 4)
            zoomButton("rectangle.center.inset.filled", "Fit board") { controller.fitBoard() }
            zoomButton("arrow.up.left.and.arrow.down.right", "Fit table") { controller.fitTable() }
        }
        .padding(.horizontal, 4)
        .background(Theme.chip, in: Capsule())
    }

    private func zoomButton(_ symbol: String, _ label: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 36, height: 34)
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
            #if os(macOS)
            // A narrow window keeps the clock and actions; zoom is in the View menu.
            if headerWidth >= 900 { zoomControls }
            #endif
            statusChip
            HStack(spacing: 6) {
                RoundIconButton(symbol: "lightbulb", style: .sage, size: 42) { session.requestHint() }
                    .disabled(session.phase != .playing)
                    .accessibilityLabel(Text("Hint"))
                if isTightHeader {
                    Menu {
                        Button { showOriginal = true } label: { Label("Show Original", systemImage: "photo") }
                        Button { model.sheet = .together } label: { Label("Play Together", systemImage: "person.2") }
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
                    RoundIconButton(symbol: "person.2.fill", size: 42) { model.sheet = .together }
                        .accessibilityLabel(Text("Play Together"))
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
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
    private func overlays(framed: Bool) -> some View {
        if !session.isLoaded || session.textures.progress < 1 {
            LoadingOverlay(session: session)
        }
        if let failure = session.loadFailure {
            ErrorOverlay(message: failure) { model.showLibrary() }
        }
        if session.phase == .paused, session.loadFailure == nil {
            PauseOverlay(session: session)
        }
        if session.phase == .completed, session.finaleDone, !framed {
            CompletionOverlay(session: session)
                .transition(.opacity)
        }
    }

    /// The puzzle is done and iPhone Duo stands half folded: the picture
    /// hangs in a frame on the board's page, the card waits on the other.
    private var isFramed: Bool { isHalfOpen && session.phase == .completed && session.finaleDone }

    @ViewBuilder
    private func framedLayout(placement: TrayPlacement, page: CGFloat, in size: CGSize) -> some View {
        #if os(iOS)
        let card = CompletionOverlay(session: session)
            // A page is short: the card takes its landscape-phone layout.
            .environment(\.verticalSizeClass, .compact)
        if placement == .trailing {
            HStack(spacing: 0) {
                PhotoFrame(session: session).frame(width: size.width - page)
                card.frame(width: page)
            }
        } else {
            VStack(spacing: 0) {
                PhotoFrame(session: session).frame(height: size.height - page)
                card.frame(height: page)
            }
        }
        #endif
    }

    // MARK: - Layout policy

    private static var forcedHalfOpen: Bool {
        #if DEBUG
        // Lets the stage driver photograph the half-open layout without DeviceHub.
        CommandLine.arguments.contains("--half-open")
        #else
        false
        #endif
    }

    /// iPhone Duo standing half open: the fold runs across the middle of the
    /// screen's long side, so the board gets one page and the tray the other,
    /// and nothing lies in the crease. `nil` keeps the usual layout.
    private func foldPage(for size: CGSize, at origin: CGPoint) -> CGFloat? {
        #if os(iOS)
        guard isHalfOpen, let fold = Self.foldCentre() else { return nil }
        let wide = size.width > size.height
        let page = wide ? origin.x + size.width - fold.x : origin.y + size.height - fold.y
        let span = wide ? size.width : size.height
        return page > span * 0.3 && page < span * 0.7 ? page : nil
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// The screen's centre in window coordinates: the window may not start
    /// at the screen's edge, since the status bar takes a column of it.
    private static func foldCentre() -> CGPoint? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              let screen = window.windowScene?.screen else { return nil }
        return window.convert(CGPoint(x: screen.bounds.midX, y: screen.bounds.midY), from: screen.coordinateSpace)
    }
    #endif

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
            ? TrayView.trailingWidth(viewSize: size) : clamp(size.height * 0.2, 130, 220)
    }

}

#if os(iOS)
/// The finished picture in a frame on the wall, for iPhone Duo standing half
/// folded on the table. On the charger the screen stays on, like StandBy.
private struct PhotoFrame: View {
    let session: GameSession

    var body: some View {
        GeometryReader { proxy in
            let mat = min(proxy.size.width, proxy.size.height) * 0.06
            ZStack {
                Theme.bg.ignoresSafeArea()
                if let picture = session.ghostImage {
                    picture.resizable().aspectRatio(contentMode: .fit)
                        .overlay(Rectangle().strokeBorder(.black.opacity(0.18), lineWidth: 1))
                        .padding(mat)
                        .background(Theme.card)
                        .padding(7)
                        .background(Color(red: 0.36, green: 0.25, blue: 0.17))
                        .shadow(color: .black.opacity(0.32), radius: 16, y: 10)
                        .padding(mat * 1.4)
                        .accessibilityLabel(Text(session.item.title))
                }
            }
        }
        // The frame stays clear of the status bar; on a laptop-standing Duo
        // it sits right above the top page.
        .onAppear(perform: keepAwakeOnCharger)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            keepAwakeOnCharger()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func keepAwakeOnCharger() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIApplication.shared.isIdleTimerDisabled = [.charging, .full].contains(UIDevice.current.batteryState)
    }
}

/// Follows iPhone Duo's hinge (iOS 27.1); every other device has none.
private struct HingeReader: ViewModifier {
    @Binding var isHalfOpen: Bool
    let isForced: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *), !isForced {
            content.onHingeChange { _, context in isHalfOpen = context.hinge?.status == .partiallyOpen }
        } else {
            content
        }
    }
}
#endif

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
