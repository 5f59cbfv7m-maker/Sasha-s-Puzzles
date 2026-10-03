import SwiftUI

/// The panel of pieces that have not been put on the table yet.
///
/// A lazy grid is essential here: a nightmare-mode puzzle puts 800 cells in this
/// view, and only the couple of dozen on screen are ever materialised.
struct TrayView: View {
    let session: GameSession
    let placement: TrayPlacement
    /// Width of a trailing tray, height of a bottom one.
    let thickness: CGFloat
    let onChanged: (Int32, CGPoint) -> Void
    let onEnded: (Int32, CGPoint) -> Void

    static let gridPadding: CGFloat = 10
    static let gridSpacing: CGFloat = 8
    private static var trailingColumns: Int {
        #if os(macOS)
        3
        #else
        2
        #endif
    }

    /// A side tray exactly as wide as its columns, so no spare margin eats
    /// into the board. The iPad gets two large columns rather than three small ones.
    static func trailingWidth(viewWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        let cell: CGFloat = 72
        #else
        let cell: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? clamp(viewWidth * 0.08, 96, 112) : 72
        #endif
        let columns = CGFloat(trailingColumns)
        return columns * cell + (columns - 1) * gridSpacing + 2 * gridPadding
    }

    private var cellSize: CGFloat {
        guard placement == .trailing else { return 63 }
        let columns = CGFloat(Self.trailingColumns)
        return floor((thickness - 2 * Self.gridPadding - (columns - 1) * Self.gridSpacing) / columns)
    }

    /// Wide side trays carry labelled buttons at the foot; a bottom strip or a
    /// narrow phone tray puts icons in the header instead.
    private var footerButtons: Bool { placement == .trailing && thickness >= 220 }

    /// Side of the square, in board units around a piece's cell centre, that
    /// every tray piece is fitted into: wide enough for the farthest tab of
    /// any piece. Fitting each texture on its own put the body wherever its
    /// tabs left room — high, low or filling the card.
    private var pieceFrame: CGFloat {
        let cell = session.geometry.cellSize
        let reach = session.textures.localBounds.reduce(0) { reach, bounds in
            max(reach, -bounds.minX, bounds.maxX - cell.width, -bounds.minY, bounds.maxY - cell.height)
        }
        return max(cell.width, cell.height) + 2 * reach
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.state.trayOrder.isEmpty {
                emptyState
            } else {
                pieceGrid
            }
            if footerButtons {
                Theme.hairline.frame(height: 1)
                VStack(spacing: 10) {
                    PillButton(title: "Scatter Pieces", symbol: "shuffle",
                               style: .secondary, size: 15, expand: true) { session.scatterTray() }
                        .disabled(!session.canScatter)
                    PillButton(title: "Gather Pieces", symbol: "tray.and.arrow.down",
                               style: .secondary, size: 15, expand: true) { session.gatherLoosePieces() }
                        .disabled(!session.canGather)
                }
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 16, trailing: 12))
            }
        }
        .background(Theme.surface)
    }

    private var header: some View {
        HStack {
            Text("Pieces")
                .font(Theme.display(placement == .trailing ? 19 : 17))
            Spacer()
            if !footerButtons {
                // No room for a footer under a horizontal strip or a narrow tray.
                RoundIconButton(symbol: "shuffle", style: .card, size: 30) { session.scatterTray() }
                    .disabled(!session.canScatter)
                    .accessibilityLabel(Text("Scatter Pieces"))
                RoundIconButton(symbol: "tray.and.arrow.down", style: .card, size: 30) { session.gatherLoosePieces() }
                    .disabled(!session.canGather)
                    .accessibilityLabel(Text("Gather Pieces"))
            }
            Text("\(session.state.trayOrder.count)")
                .font(Theme.body(14, .bold).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Theme.card, in: Capsule())
        }
        .padding(.horizontal, placement == .trailing ? 14 : 16)
        .padding(.top, placement == .trailing ? 18 : 8)
        .padding(.bottom, placement == .trailing ? 12 : 6)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.onSageTint)
                .frame(width: 64, height: 64)
                .background(Theme.sageTint, in: Circle())
            Text("All pieces are on the table")
                .font(Theme.body(15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var pieceGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: Self.gridSpacing), count: Self.trailingColumns)
        let rows = [GridItem(.adaptive(minimum: cellSize, maximum: cellSize), spacing: 10)]

        if placement == .trailing {
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: Self.gridSpacing) { cells }
                    .padding(EdgeInsets(top: 0, leading: Self.gridPadding, bottom: Self.gridPadding,
                                        trailing: Self.gridPadding))
            }
        } else {
            ScrollView(.horizontal) {
                LazyHGrid(rows: rows, spacing: 10) { cells }
                    .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        let frame = pieceFrame
        ForEach(session.state.trayOrder, id: \.self) { piece in
            TrayCell(image: session.textures.images[safe: Int(piece)] ?? nil,
                     bounds: session.textures.localBounds[safe: Int(piece)],
                     pieceCell: session.geometry.cellSize, frame: frame, size: cellSize)
                .trayDragGesture(piece: piece, placement: placement, onChanged: onChanged, onEnded: onEnded)
                .accessibilityLabel(Text("Puzzle piece"))
                .accessibilityHint(Text("Drag onto the board"))
        }
    }
}

private struct TrayCell: View {
    let image: Image?
    /// Outline bounds relative to the piece's own cell, as the texture is cut.
    let bounds: CGRect?
    let pieceCell: CGSize
    let frame: CGFloat
    let size: CGFloat
    /// A hovering Apple Pencil (or pointer) lifts the piece a few points.
    @State private var isHovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            if let image, let bounds, frame > 0 {
                // One scale for every piece, and the cell body — not the
                // texture — centred, so tabs stick out evenly around it.
                let k = (size - 6) / frame
                image
                    .resizable()
                    .frame(width: bounds.width * k, height: bounds.height * k)
                    .offset(x: (bounds.midX - pieceCell.width / 2) * k,
                            y: (bounds.midY - pieceCell.height / 2) * k)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
                    .scaleEffect(isHovered ? 1 + 6 / size : 1)
                    .shadow(color: .black.opacity(isHovered ? 0.12 : 0), radius: 8, y: 5)
            } else {
                Image(systemName: "puzzlepiece")
                    .foregroundStyle(Theme.track)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering } }
    }
}

private extension View {
    /// Mouse drags start immediately. Touch goes through a UIKit pan that
    /// reads the first 10pt: across the scroll axis lifts the piece, along it
    /// the pan fails and the tray scrolls. The previous long-press prelude
    /// dropped every drag whose finger was already moving.
    func trayDragGesture(piece: Int32, placement: TrayPlacement,
                         onChanged: @escaping (Int32, CGPoint) -> Void,
                         onEnded: @escaping (Int32, CGPoint) -> Void) -> some View {
        #if os(macOS)
        highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("game"))
                .onChanged { onChanged(piece, $0.location) }
                .onEnded { onEnded(piece, $0.location) }
        )
        #else
        gesture(TrayPan(scrollsVertically: placement == .trailing,
                        onChanged: { onChanged(piece, $0) }, onEnded: { onEnded(piece, $0) }))
        #endif
    }
}

#if canImport(UIKit)
private struct TrayPan: UIGestureRecognizerRepresentable {
    let scrollsVertically: Bool
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> DirectionalPan {
        let pan = DirectionalPan()
        pan.scrollsVertically = scrollsVertically
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: DirectionalPan, context: Context) {
        pan.scrollsVertically = scrollsVertically
    }

    func handleUIGestureRecognizerAction(_ pan: DirectionalPan, context: Context) {
        let location = context.converter.convert(globalPoint: pan.location(in: nil), to: .named("game"))
        switch pan.state {
        case .began: Feedback.shared.dragBegan(in: pan.view)
        case .changed: onChanged(location)
        case .ended: onEnded(location)
        // A cancelled drag must not place the piece: a point outside the
        // board just clears the ghost.
        case .cancelled, .failed: onEnded(CGPoint(x: -1, y: -1))
        default: break
        }
    }

    /// A pan that fails on its own when the first 10pt run along the scroll
    /// axis. Scroll flicks are nearly straight and immediate; anything steeper
    /// than about 20° off the axis, or a finger that rested on the piece for a
    /// quarter second first, is a piece on its way to the board.
    final class DirectionalPan: UIPanGestureRecognizer {
        var scrollsVertically = true
        private var start: CGPoint?
        private var startTime: TimeInterval = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            start = touches.first?.location(in: nil)
            startTime = event.timestamp
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible, let start, let point = touches.first?.location(in: nil) {
                let dx = abs(point.x - start.x), dy = abs(point.y - start.y)
                guard hypot(dx, dy) >= 10 else { return }
                let (along, across) = scrollsVertically ? (dy, dx) : (dx, dy)
                let held = event.timestamp - startTime > 0.25
                if !held, across <= along * 0.4 { state = .failed; return }
            }
            super.touchesMoved(touches, with: event)
        }

        override func reset() {
            start = nil
            super.reset()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The scroll view's own pan waits for this one to decide.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}
#endif
