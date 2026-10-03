import CoreGraphics
import Foundation
import Testing
@testable import JigsawPuzzle

@Suite("Images and rendering")
struct ImageTests {

    private func makeImage(width: Int, height: Int) -> RenderedImage {
        let context = CGContext.bitmap(size: CGSize(width: width, height: height))!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return RenderedImage(cgImage: context.makeImage()!)
    }

    @Test("Cropping keeps the aspect and never stretches")
    func cropProducesRequestedAspect() {
        let wide = makeImage(width: 400, height: 200)     // 2:1
        let square = ImagePipeline.crop(wide, toAspect: 1)
        #expect(square.width == 200 && square.height == 200)

        let tall = makeImage(width: 200, height: 600)     // 1:3
        let landscape = ImagePipeline.crop(tall, toAspect: 3.0 / 2.0)
        #expect(abs(landscape.aspect - 1.5) < 0.02)
        #expect(landscape.width <= tall.width && landscape.height <= tall.height)
    }

    @Test("A nil aspect leaves the picture untouched")
    func cropWithoutAspectIsIdentity() {
        let image = makeImage(width: 333, height: 211)
        let result = ImagePipeline.crop(image, toAspect: nil)
        #expect(result.width == 333 && result.height == 211)
    }

    @Test("Encoding and decoding a photo round trips through disk")
    func writeAndDecode() throws {
        let directory = URL.temporaryDirectory.appending(path: "JigsawImg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "photo.jpg")

        try ImagePipeline.write(makeImage(width: 800, height: 500), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(ImagePipeline.dimensions(url: url) == CGSize(width: 800, height: 500))

        let decoded = try ImagePipeline.decode(url: url, maxPixelSize: 200)
        #expect(max(decoded.width, decoded.height) <= 200, "decoding must downsample")
        #expect(abs(decoded.aspect - 1.6) < 0.05)
    }

    @Test("A bundled picture takes its category and title from the file name")
    func bundledPictureName() throws {
        let directory = URL.temporaryDirectory.appending(path: "JigsawBundled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = directory.appending(path: "sea_Sunset Beach.jpg")
        try ImagePipeline.write(makeImage(width: 900, height: 600), to: good)

        let item = try #require(LibraryCatalog.bundledItem(at: good))
        #expect(item.category == .sea)
        #expect(item.title == String(localized: "Sunset Beach"), "title goes through the string catalog")
        #expect(item.source == .bundled(fileName: "sea_Sunset Beach.jpg"))
        #expect(abs(item.aspect - 1.5) < 0.001)

        let unknownCategory = directory.appending(path: "food_Pasta.jpg")
        try ImagePipeline.write(makeImage(width: 90, height: 60), to: unknownCategory)
        #expect(LibraryCatalog.bundledItem(at: unknownCategory) == nil)
        #expect(LibraryCatalog.bundledItem(at: directory.appending(path: "sea_Missing.jpg")) == nil)
    }

    @Test("An unreadable file reports an error instead of crashing")
    func decodeFailsGracefully() {
        #expect(throws: (any Error).self) {
            try ImagePipeline.decode(data: Data("definitely not an image".utf8), maxPixelSize: 100)
        }
    }

    @Test("Piece textures cover the whole outline at the right scale")
    func textureRendering() {
        let geometry = PuzzleGeometry(columns: 6, rows: 4, aspect: 1.5, seed: 4242)
        let source = makeImage(width: 900, height: 600)
        let scale = PieceTextureStore.affordableScale(for: geometry, desired: 2)
        let textures = PieceTextureStore.render(pieces: Array(0..<geometry.pieceCount),
                                                geometry: geometry,
                                                source: source,
                                                pixelScale: scale, outlines: true)
        #expect(textures.count == geometry.pieceCount)
        for piece in 0..<geometry.pieceCount {
            let bounds = geometry.localBounds(of: piece)
            let image = try! #require(textures[piece])
            #expect(abs(Double(image.width) - Double(bounds.width * scale)) <= 2)
            #expect(abs(Double(image.height) - Double(bounds.height * scale)) <= 2)
        }
    }

    @Test("Cardboard pieces carry a visible grain; plain ones stay flat")
    func cardboardGrain() throws {
        let geometry = PuzzleGeometry(columns: 6, rows: 4, aspect: 1.5, seed: 4242)
        let source = makeImage(width: 900, height: 600)
        func spread(cardboard: Bool) throws -> Double {
            let image = try #require(PieceTextureStore.renderPiece(8, geometry: geometry, source: source,
                                                                    pixelScale: 2, outlines: false,
                                                                    cardboard: cardboard))
            let read = try #require(CGContext.bitmap(size: CGSize(width: image.width, height: image.height)))
            read.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
            // The middle of the piece: inside the outline whatever its tabs.
            var values: [Double] = []
            for y in image.height * 2 / 5..<image.height * 3 / 5 {
                for x in image.width * 2 / 5..<image.width * 3 / 5 {
                    values.append(Double(bytes[y * read.bytesPerRow + x * 4 + 1]))
                }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        let plain = try spread(cardboard: false), card = try spread(cardboard: true)
        #expect(plain < 1)
        #expect(card > 6, "grain spread \(card)")
    }

    @Test("A zoom re-cut keeps the board drawn and skips zooming out")
    @MainActor
    func textureRecutIsSilent() async throws {
        let geometry = PuzzleGeometry(columns: 4, rows: 3, aspect: 1.5, seed: 7)
        let source = makeImage(width: 600, height: 400)
        let store = PieceTextureStore()
        store.rebuild(geometry: geometry, source: source, pixelScale: 1, outlines: false)
        #expect(!store.isReady)
        while !store.isReady { try await Task.sleep(for: .milliseconds(20)) }
        let first = try #require(store.texture(for: 0))

        // Zooming out reuses the sharper textures instead of re-cutting.
        store.rebuild(geometry: geometry, source: source, pixelScale: 0.6, outlines: false)
        #expect(store.isReady && store.pixelScale == 1)

        // Zooming in re-cuts without ever blanking the board.
        store.rebuild(geometry: geometry, source: source, pixelScale: 2, outlines: false)
        #expect(store.isReady && store.progress == 1 && store.texture(for: 0) === first)
        while store.pixelScale != 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.texture(for: 0)!.width > first.width)
    }

    @Test("The texture budget lowers the scale instead of exhausting memory")
    func textureBudgetIsRespected() {
        let small = PuzzleGeometry(columns: 4, rows: 3, aspect: 1.5, seed: 1)
        let huge = PuzzleGeometry(columns: 40, rows: 30, aspect: 1.5, seed: 1)
        #expect(PieceTextureStore.affordableScale(for: small, desired: 3) >= 2)

        let hugeScale = PieceTextureStore.affordableScale(for: huge, desired: 3)
        let cell = huge.cellSize
        let overhang = huge.maximumOverhang * 2
        let pixels = Double((cell.width + overhang) * (cell.height + overhang))
            * Double(huge.pieceCount) * Double(hugeScale * hugeScale)
        #expect(pixels <= PieceTextureStore.pixelBudget * 1.05)
    }
}

@Suite("Session, clock and undo")
@MainActor
struct SessionTests {

    /// Sessions under test write to a throwaway directory so running the suite
    /// never disturbs the player's real saved games.
    private func makeSession(pieces: Int = 24) -> GameSession {
        let directory = URL.temporaryDirectory.appending(path: "JigsawSession-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = LibraryCatalog.builtIn()[0]
        return GameSession(item: item, aspect: .landscape32, targetPieces: pieces, seed: 4242,
                           saveStore: SaveStore(directory: directory))
    }

    @Test("From the third snap in a row the streak rings until a miss, then builds up again")
    func snapStreak() {
        let session = makeSession()
        session.startForTesting()
        func drop(_ piece: Int32, away: CGFloat = 0) {
            let cell = session.geometry.cellSize
            let centre = session.state.solvedOrigin(of: piece)
                + CGPoint(x: cell.width / 2 - away, y: cell.height / 2)
            _ = session.placePieceFromTray(piece, at: centre, viewScale: 1, assist: .precise)
        }
        drop(0); drop(1)
        #expect(!session.isOnStreak)
        drop(2)
        #expect(session.isOnStreak)
        drop(3)
        #expect(session.isOnStreak, "every snap after the third keeps the streak")
        drop(4, away: 5000)
        #expect(session.snapStreak == 0 && !session.isOnStreak)
        drop(5); drop(6)
        #expect(!session.isOnStreak)
        drop(7)
        #expect(session.isOnStreak)
    }

    @Test("Scatter and gather are two buttons, each live when it has pieces to move")
    func scatterAndGather() {
        let session = makeSession()
        session.startForTesting()
        #expect(session.canScatter && !session.canGather)
        session.scatterTray()
        #expect(!session.canScatter && session.canGather)
        session.gatherLoosePieces()
        #expect(session.canScatter && !session.canGather)
    }

    @Test("A saved board's preview shows assembled pieces, and only faintly the rest")
    func boardPreview() throws {
        let session = makeSession()
        session.startForTesting()
        let cell = session.geometry.cellSize
        for piece: Int32 in [0, 1] {
            _ = session.placePieceFromTray(piece, at: session.state.solvedOrigin(of: piece)
                + CGPoint(x: cell.width / 2, y: cell.height / 2), viewScale: 1, assist: .precise)
        }
        let board = session.geometry.boardSize
        let width = 300, height = Int((300 * board.height / board.width).rounded())
        let red = try #require(CGContext.bitmap(size: CGSize(width: width, height: height)))
        red.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        red.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let source = try #require(red.makeImage())
        let preview = try #require(BoardPreview.render(session.snapshot(), image: source))
        #expect(preview.width == width && preview.height == height)

        let read = try #require(CGContext.bitmap(size: CGSize(width: width, height: height)))
        read.draw(preview, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
        // Memory rows run top-down; BGRA, alpha last.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * read.bytesPerRow + x * 4 + 3] }
        let scale = Double(width) / board.width
        #expect(alpha(Int(cell.width * 0.5 * scale), Int(cell.height * 0.5 * scale)) == 255)
        #expect(alpha(width - Int(cell.width * 0.5 * scale), height - Int(cell.height * 0.5 * scale)) < 80)
    }

    @Test("A new session is consistent before anything is loaded")
    func initialSessionState() {
        let session = makeSession()
        #expect(session.phase == .preparing)
        #expect(session.elapsed == 0)
        #expect(session.pieceCount == session.geometry.pieceCount)
        #expect(session.placedCount == 0)
        #expect(!session.canUndo && !session.canRedo)
        #expect(session.tableRect.contains(session.boardRect))
    }

    @Test("The clock measures real elapsed time and stops when paused")
    func clockTracksRealTime() async throws {
        let session = makeSession()
        session.startForTesting()
        #expect(session.phase == .playing)

        // Compare against the wall clock rather than a fixed window: the test
        // machine may be loaded, and the point is that the timer follows real
        // time rather than frames or ticks.
        let started = Date.now
        try await Task.sleep(for: .milliseconds(600))
        // Pausing recomputes the exact interval, independent of the 250 ms ticker.
        session.pause()
        let wallClock = Date.now.timeIntervalSince(started)
        #expect(session.phase == .paused)
        let atPause = session.elapsed
        #expect(abs(atPause - wallClock) < 0.2, "measured \(atPause) against \(wallClock)")
        #expect(atPause >= 0.55)
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(session.elapsed - atPause) < 0.05, "the clock must not run while paused")

        session.resume()
        try await Task.sleep(for: .milliseconds(400))
        session.pause()
        #expect(session.elapsed > atPause + 0.3, "the clock must resume")
    }

    @Test("Leaving the foreground pauses the game")
    func backgroundPauses() {
        let session = makeSession()
        session.startForTesting()
        session.handleBackground()
        #expect(session.phase == .paused)
    }

    @Test("Undo restores the previous placement, redo puts it back")
    func undoRedoRoundTrip() {
        let session = makeSession()
        session.startForTesting()

        _ = session.placePieceFromTray(0, at: CGPoint(x: 40, y: 40),
                                       viewScale: 1, assist: .precise)
        let afterFirst = session.state
        #expect(session.canUndo)

        _ = session.placePieceFromTray(1, at: CGPoint(x: 900, y: 900),
                                       viewScale: 1, assist: .precise)
        #expect(session.state.placedCount == 2)

        session.undo()
        #expect(session.state.placedCount == 1)
        #expect(session.state == afterFirst)
        #expect(session.canRedo)

        session.redo()
        #expect(session.state.placedCount == 2)
    }

    @Test("Undo also reverses a merge")
    func undoReversesMerge() {
        let session = makeSession()
        session.startForTesting()
        let cell = session.geometry.cellSize

        _ = session.placePieceFromTray(0, at: CGPoint(x: cell.width / 2, y: cell.height / 2),
                                       viewScale: 1, assist: .generous)
        _ = session.placePieceFromTray(1, at: CGPoint(x: cell.width * 1.5, y: cell.height / 2),
                                       viewScale: 1, assist: .generous)
        #expect(session.state.groups.count == 1, "the two pieces should have joined")

        session.undo()
        #expect(session.state.placedCount == 1)
        #expect(session.state.groups.count == 1)
    }

    @Test("A correctly placed piece cannot be sent back to the tray")
    func lockedPieceStaysOnBoard() {
        let session = makeSession()
        session.startForTesting()
        let cell = session.geometry.cellSize
        _ = session.placePieceFromTray(0, at: CGPoint(x: cell.width / 2 + 3, y: cell.height / 2 - 2),
                                       viewScale: 1, assist: .standard)
        #expect(session.state.isLocked(0))
        let undoDepth = session.canUndo

        session.returnPieceToTray(0)
        #expect(session.state.isLocked(0))
        #expect(session.placedCount == 1)
        #expect(session.canUndo == undoDepth, "a refused request must not push an undo step")
    }

    @Test("A loose piece is caught next to its outline, a locked one is not")
    func looseHitTestIsForgiving() {
        let session = makeSession()
        session.startForTesting()
        let cell = session.geometry.cellSize
        // Piece 0 lies loose far from home; piece 1 is locked in place.
        _ = session.placePieceFromTray(0, at: CGPoint(x: 900, y: 900), viewScale: 1, assist: .precise)
        _ = session.placePieceFromTray(1, at: CGPoint(x: cell.width * 1.5, y: cell.height / 2),
                                       viewScale: 1, assist: .standard)
        #expect(!session.state.isLocked(0) && session.state.isLocked(1))

        // Just above piece 0's flat top edge: outside the outline, inside the slack.
        let origin = session.state.solvedOrigin(of: 0) + session.state.group(of: 0)!.translation
        let nearTop = origin + CGPoint(x: cell.width / 2, y: -cell.height * 0.05)
        #expect(session.piece(at: nearTop) == 0)
        #expect(session.beginDrag(at: nearTop))
        session.endDrag(viewScale: 1, assist: .precise)

        // The same spot beside the locked piece stays empty table.
        let lockedTop = session.state.solvedOrigin(of: 1) + CGPoint(x: cell.width / 2, y: -cell.height * 0.05)
        #expect(session.piece(at: lockedTop) == nil)
    }

    @Test("A hint points at a piece without solving anything")
    func hintDoesNotSolve() {
        let session = makeSession()
        session.startForTesting()
        let before = session.state
        session.requestHint()
        #expect(session.hint != nil)
        #expect(session.state == before, "a hint must never move a piece")
    }

    @Test("A snap flash expires, so the board stops redrawing")
    func flashesExpire() async throws {
        let session = makeSession()
        session.startForTesting()
        let cell = session.geometry.cellSize
        _ = session.placePieceFromTray(0, at: CGPoint(x: cell.width / 2, y: cell.height / 2),
                                       viewScale: 1, assist: .standard)
        #expect(!session.flashes.isEmpty)
        #expect(session.needsAnimationTicks)

        try await Task.sleep(for: .seconds(GameSession.flashDuration + 0.4))
        #expect(session.flashes.isEmpty)
        #expect(!session.needsAnimationTicks, "an idle board must let its timeline pause")
    }

    @Test("Solving marks the session complete and stops the clock")
    func solvingCompletes() async throws {
        let session = makeSession(pieces: 12)
        session.startForTesting()
        session.solveImmediately()

        #expect(session.phase == .completed)
        #expect(session.state.isComplete)
        let atFinish = session.elapsed
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(session.elapsed - atFinish) < 0.05)
    }

    @Test("A snapshot captures everything needed to resume")
    func snapshotRestoresSession() {
        let session = makeSession(pieces: 48)
        session.startForTesting()
        _ = session.placePieceFromTray(3, at: CGPoint(x: 120, y: 90), viewScale: 1, assist: .standard)

        let snapshot = session.snapshot()
        let directory = URL.temporaryDirectory.appending(path: "JigsawRestore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let restored = GameSession(snapshot: snapshot, saveStore: SaveStore(directory: directory))

        #expect(restored.id == session.id)
        #expect(restored.geometry.columns == session.geometry.columns)
        #expect(restored.geometry.rows == session.geometry.rows)
        #expect(restored.state == session.state)
        #expect(restored.geometry.outline(of: 5)[1].sampled()
                == session.geometry.outline(of: 5)[1].sampled())
    }

    @Test("Scatter empties the tray onto the table")
    func scatterFromSession() {
        let session = makeSession(pieces: 48)
        session.startForTesting()
        session.scatterTray()
        #expect(session.state.trayOrder.isEmpty)
        #expect(session.placedCount == session.pieceCount)
    }
}
