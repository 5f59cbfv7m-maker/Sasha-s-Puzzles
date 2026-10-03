import SwiftUI

/// Lazily produced preview of a library picture.
///
/// Photos are decoded on demand at thumbnail resolution, off the main actor, and
/// cached, so scrolling the library never blocks the main thread.
struct LibraryThumbnail: View {
    let item: LibraryItem
    var longSide: Int = 420
    /// An unfinished game with this picture: show its board as it was left.
    var snapshot: GameSnapshot?

    @State private var image: Image?

    var body: some View {
        // `Color.clear` is the only element that takes part in layout: the
        // picture lives in an overlay so a square artwork can never stretch a
        // 3:2 card and break the surrounding grid.
        Color.clear
            .overlay {
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .background(.quaternary)
            .clipped()
            .contentShape(Rectangle())
            .task(id: "\(item.id)|\(snapshot?.updatedAt.timeIntervalSince1970 ?? 0)") { await load() }
    }

    private func load() async {
        let request = ImageStore.Request(item: item, aspect: snapshot?.puzzleAspect ?? .original, longSide: longSide)
        guard let rendered = await ImageStore.shared.image(request) else { return }
        var picture = rendered.cgImage
        if let snapshot {
            let source = UncheckedSendable(picture)
            let board = await Task.detached(priority: .utility) {
                BoardPreview.render(snapshot, image: source.value).map(UncheckedSendable.init)
            }.value
            if let board { picture = board.value }
        }
        withAnimation(.easeOut(duration: 0.2)) {
            image = Image(decorative: picture, scale: 1)
        }
    }
}

/// A saved board as it stands: the pieces already in their place, over a
/// faint copy of the picture. Everything still loose on the table is left out.
nonisolated enum BoardPreview {
    /// `image` is the picture already cropped to the puzzle's framing.
    static func render(_ snapshot: GameSnapshot, image: CGImage) -> CGImage? {
        let geometry = PuzzleGeometry(columns: snapshot.columns, rows: snapshot.rows,
                                      aspect: snapshot.puzzleAspect.ratio ?? snapshot.imageAspect,
                                      seed: snapshot.seed)
        let board = CGRect(origin: .zero, size: geometry.boardSize)
        guard board.width > 0,
              let context = CGContext.bitmap(size: CGSize(width: image.width, height: image.height))
        else { return nil }
        // Board units, y running down.
        let scale = CGFloat(image.width) / board.width
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: scale, y: -scale)

        context.setAlpha(0.22)
        context.drawFlipped(image, in: board)
        context.setAlpha(1)

        let state = snapshot.state
        for group in state.groups.values where group.isHome {
            context.saveGState()
            for piece in group.members {
                let origin = state.solvedOrigin(of: piece)
                context.translateBy(x: origin.x, y: origin.y)
                context.addPath(geometry.localPath(of: Int(piece)))
                context.translateBy(x: -origin.x, y: -origin.y)
            }
            context.clip()
            context.drawFlipped(image, in: board)
            context.restoreGState()
        }
        return context.makeImage()
    }
}
