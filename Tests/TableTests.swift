import CoreGraphics
import Foundation
import Testing
@testable import JigsawPuzzle

/// Two ends of an in-memory connection. Nothing is delivered until `pump`,
/// so a test decides exactly which messages cross before which moves.
@MainActor
private final class Loopback: TableLink {
    let id: String
    weak var other: Loopback?
    var inbox: [Data] = []
    var onReceive: ((Data, String) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: ((String) -> Void)?
    var connectedPeers: [String] { other.map { [$0.id] } ?? [] }

    init(id: String) { self.id = id }

    static func pair() -> (Loopback, Loopback) {
        let a = Loopback(id: "a"), b = Loopback(id: "b")
        a.other = b
        b.other = a
        return (a, b)
    }

    func send(_ data: Data, to peers: [String], reliable: Bool) { other?.inbox.append(data) }
    func close() {}

    /// Delivers what has arrived; returns whether anything did.
    func deliver() -> Bool {
        guard !inbox.isEmpty, let from = other?.id else { return false }
        let batch = inbox
        inbox = []
        for data in batch { onReceive?(data, from) }
        return true
    }
}

@Suite("Playing together")
@MainActor
struct TableTests {
    private let saves: SaveStore = {
        let directory = URL.temporaryDirectory.appending(path: "JigsawTable-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SaveStore(directory: directory)
    }()

    /// A host and one guest at the table, the guest's game loaded.
    private func table(pieces: Int = 12) -> (host: SharedTable, guest: SharedTable, links: [Loopback]) {
        let game = GameSession(item: LibraryCatalog.builtIn()[0], aspect: .square, targetPieces: pieces,
                               seed: 77, saveStore: saves)
        game.startForTesting()
        let host = SharedTable(hosting: game, name: "Sasha", settings: nil, me: "host")
        let (hostEnd, guestEnd) = Loopback.pair()
        host.add(hostEnd)
        let guest = SharedTable(joining: guestEnd, name: "Dad", settings: nil, saveStore: saves, me: "guest")
        guest.onGame = { $0.startForTesting() }
        let links = [hostEnd, guestEnd]
        pump(links)
        return (host, guest, links)
    }

    private func pump(_ links: [Loopback]) {
        while links.map({ $0.deliver() }).contains(true) {}
    }

    /// Drops a tray piece exactly home.
    @discardableResult
    private func placeHome(_ piece: Int32, in game: GameSession) -> SettleOutcome? {
        let cell = game.geometry.cellSize
        let centre = game.state.solvedOrigin(of: piece) + CGPoint(x: cell.width / 2, y: cell.height / 2)
        return game.placePieceFromTray(piece, at: centre, viewScale: 1, assist: .standard)
    }

    @Test("A guest sits down with the host's board, and both seats are taken")
    func joining() throws {
        let (host, guest, _) = table()
        let game = try #require(guest.session)
        #expect(game.id == host.session?.id)
        #expect(game.state == host.session?.state)
        #expect(guest.players.map(\.slot) == [0, 1])
        #expect(host.session?.isShared == true && game.isShared)
    }

    @Test("Moves made on both devices at once end in one board, each piece credited to its player")
    func simultaneousMoves() throws {
        let (host, guest, links) = table()
        let hostGame = try #require(host.session), guestGame = try #require(guest.session)
        // Neither has seen the other's move when making their own.
        placeHome(0, in: hostGame)
        placeHome(5, in: guestGame)
        placeHome(1, in: guestGame)
        pump(links)
        #expect(hostGame.state == guestGame.state)
        #expect(hostGame.state.isLocked(0) && hostGame.state.isLocked(5) && hostGame.state.isLocked(1))
        let sasha = try #require(host.players.first { $0.id == "host" })
        let dad = try #require(host.players.first { $0.id == "guest" })
        #expect(host.pieces(of: sasha) == 1)
        #expect(host.pieces(of: dad) == 2)
        #expect(guest.credit == host.credit)
    }

    @Test("A piece both players took out of the tray goes where the later drop put it")
    func samePieceTwice() throws {
        let (host, guest, links) = table()
        let hostGame = try #require(host.session), guestGame = try #require(guest.session)
        hostGame.placePieceFromTray(3, at: CGPoint(x: -300, y: -300), viewScale: 1, assist: .standard)
        placeHome(3, in: guestGame)
        pump(links)
        #expect(hostGame.state == guestGame.state)
        #expect(hostGame.state.isLocked(3))
        #expect(hostGame.state.trayOrder.count == 11)
    }

    @Test("The last piece finishes the puzzle on every device, and the pieces add up")
    func finishingTogether() throws {
        let (host, guest, links) = table()
        let hostGame = try #require(host.session), guestGame = try #require(guest.session)
        var hostDone = false, guestDone = false
        hostGame.onComplete = { _ in hostDone = true }
        guestGame.onComplete = { _ in guestDone = true }
        for piece in Int32(0)..<Int32(hostGame.pieceCount) {
            placeHome(piece, in: piece % 2 == 0 ? hostGame : guestGame)
            pump(links)
        }
        #expect(hostDone && guestDone)
        let own = [host.ownPieces(in: hostGame), guest.ownPieces(in: guestGame)]
        #expect(own == [6, 6])
    }

    @Test("A partner's held piece follows their finger, and nothing snaps to it")
    func holding() throws {
        let (host, guest, links) = table()
        let hostGame = try #require(host.session), guestGame = try #require(guest.session)
        hostGame.placePieceFromTray(0, at: CGPoint(x: -400, y: -400), viewScale: 1, assist: .standard)
        pump(links)
        // The guest picks piece 0 up through the tray-drag path and holds it home.
        guestGame.trayDragMoved(0, to: .zero)
        let held = CGPoint(x: -hostGame.geometry.cellSize.width / 2, y: -hostGame.geometry.cellSize.height / 2)
        guestGame.onHold?(0, held)
        pump(links)
        #expect(hostGame.remoteHolds["guest"]?.piece == 0)
        #expect(hostGame.heldElsewhere == [try #require(hostGame.state.group(of: 0)?.id)])
        guestGame.onHold?(0, nil)
        pump(links)
        #expect(hostGame.remoteHolds.isEmpty)
    }

    @Test("A drag that ends exactly home still joins the neighbours, and a held piece never locks")
    func exactlyHome() throws {
        var state = PuzzleState(columns: 3, rows: 2, cellSize: CGSize(width: 100, height: 100))
        let area = CGRect(x: -300, y: -300, width: 900, height: 800), board = CGRect(x: 0, y: 0, width: 300, height: 200)
        state.apply(.place(piece: 0, translation: .zero, tolerance: 10), table: area, board: board)
        state.apply(.place(piece: 1, translation: CGPoint(x: 400, y: 0), tolerance: 10), table: area, board: board)
        // The drag carried piece 1 to exactly home before letting go.
        state.setTranslation(.zero, forGroup: try #require(state.group(of: 1)?.id))
        let outcome = state.apply(.drop(piece: 1, translation: .zero, tolerance: 10), table: area, board: board)
        #expect(outcome?.didMerge == true)
        #expect(state.group(of: 0)?.id == state.group(of: 1)?.id)

        let (host, guest, links) = table()
        let hostGame = try #require(host.session), guestGame = try #require(guest.session)
        hostGame.placePieceFromTray(4, at: CGPoint(x: -300, y: -300), viewScale: 1, assist: .standard)
        pump(links)
        guestGame.onHold?(4, .zero)
        pump(links)
        #expect(hostGame.state.isLocked(4) == false)
    }

    @Test("The host's next game takes everyone at the table along")
    func playAgain() throws {
        let (host, guest, links) = table()
        let next = GameSession(item: LibraryCatalog.builtIn()[1], aspect: .square, targetPieces: 24,
                               seed: 5, saveStore: saves)
        host.attach(next)
        pump(links)
        #expect(guest.session?.id == next.id)
        #expect(guest.session?.pieceCount == next.pieceCount)
        #expect(guest.credit.count == next.pieceCount)
    }

    @Test("A guest whose host leaves keeps the board as a game of their own")
    func hostLeaves() throws {
        let (host, guest, links) = table()
        let guestGame = try #require(guest.session)
        host.close()
        pump(links)
        #expect(guest.endReason == .hostLeft)
        #expect(!guestGame.isShared && !guestGame.waitsForHost)
        #expect(guestGame.canUndo == false)
        placeHome(2, in: guestGame)
        #expect(guestGame.canUndo)
    }

    @Test("An 800-piece board fits in one Game Center message")
    func updateSize() throws {
        let game = GameSession(item: LibraryCatalog.builtIn()[0], aspect: .square, targetPieces: 800,
                               seed: 9, saveStore: saves)
        game.startForTesting()
        game.scatterTray()
        let update = TableUpdate(gameID: game.id, state: game.state, elapsed: 0,
                                 credit: Array(repeating: -1, count: game.pieceCount),
                                 players: [], acked: [:], mover: nil)
        let data = try #require(TableMessage.update(update).encoded())
        // Game Center's reliable messages stop at 87 KB.
        #expect(data.count < 80_000)
    }

    @Test("A shared puzzle earns points for the player's own pieces and never counts as the daily")
    func sharedPoints() {
        let directory = URL.temporaryDirectory.appending(path: "JigsawTableStats-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stats = PlayerStats(directory: directory)
        let daily = LibraryCatalog.dailyItem()
        let summary = stats.record(SolvedRecord(itemID: daily.id, category: daily.category, pieces: 200,
                                                targetPieces: LibraryCatalog.dailyPieces, elapsed: 60,
                                                date: .now, isUserPhoto: false, sharedPieces: 80))
        #expect(summary.pointsEarned == 100)
        #expect(!stats.dailySolvedToday)
        #expect(stats.bestTime(for: daily.id) == nil)
        #expect(stats.piecesPlaced == 80)
    }
}
