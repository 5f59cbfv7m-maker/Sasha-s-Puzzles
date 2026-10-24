import Foundation
import Observation

/// A player at a shared table. `slot` is their colour; it stays theirs while
/// the table is open, even if they drop out and come back.
nonisolated struct TablePlayer: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var slot: Int
    var isHere = true
}

/// What the host sends after every change: the whole board. Compressed it is
/// a few kilobytes, and unlike a stream of edits it can never drift.
nonisolated struct TableUpdate: Codable, Sendable {
    var gameID: String
    var state: PuzzleState
    var elapsed: TimeInterval
    /// Colour slot of the player who first joined each piece; -1 for none yet.
    var credit: [Int8]
    var players: [TablePlayer]
    /// The last move the host applied from each guest, by player id.
    var acked: [String: Int]
    var mover: String?
    /// The mover's drag that made the move: their held piece is down now.
    var moverDrag = 0
    var flashed: [Int32] = []
}

nonisolated enum TableMessage: Codable, Sendable {
    case hello(player: String, name: String, version: Int)
    case welcome(game: GameSnapshot, version: Int)
    case update(TableUpdate)
    case move(seq: Int, move: BoardMove, drag: Int)
    /// Where a player's held piece is; `nil` when they let go. `drag` counts
    /// the player's drags, so a position arriving after the let-go is stale.
    case hold(player: String, drag: Int, piece: Int32, translation: CGPoint?)
    /// The host left.
    case closed

    /// Bumped whenever a message changes shape; a guest on another version leaves.
    static let version = 1

    func encoded() -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) -> TableMessage? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(TableMessage.self, from: json)
    }
}

/// A connection to the other devices at a table: nearby (`NearbyLink`) or a
/// Game Center match (`MatchLink`). Peers are the link's own ids.
@MainActor
protocol TableLink: AnyObject {
    var connectedPeers: [String] { get }
    var onReceive: ((Data, String) -> Void)? { get set }
    var onConnect: ((String) -> Void)? { get set }
    var onDisconnect: ((String) -> Void)? { get set }
    func send(_ data: Data, to peers: [String], reliable: Bool)
    func close()
}

/// One puzzle on several devices, up to four players.
///
/// The device that opened the table keeps the board. Guests show their own
/// moves at once and send them to the host; the host applies every move in
/// the order it arrives and sends everyone the board as it now is. A guest
/// takes that board and lays the moves the host has not seen yet on top
/// again, so two players dropping pieces in the same instant both land.
@Observable
@MainActor
final class SharedTable {
    /// One per launch: a player who drops out and reconnects gets their seat back.
    static let deviceID = UUID().uuidString
    nonisolated static let maxPlayers = 4

    enum EndReason { case hostLeft, outdated }

    let isHost: Bool
    let me: String
    private(set) var players: [TablePlayer] = []
    private(set) var credit: [Int8] = []
    private(set) var session: GameSession?
    /// Why a guest's table closed. Their game carries on as their own.
    private(set) var endReason: EndReason?
    /// A guest's game arrived from the host: the first one, or the next after "Play again".
    @ObservationIgnored var onGame: ((GameSession) -> Void)?

    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private let saveStore: SaveStore
    @ObservationIgnored private let name: String
    @ObservationIgnored private var links: [TableLink] = []
    /// The host's map from player to their device.
    @ObservationIgnored private var routes: [String: (link: TableLink, peer: String)] = [:]
    /// A guest's way to the host.
    @ObservationIgnored private var host: (link: TableLink, peer: String)?
    @ObservationIgnored private var acked: [String: Int] = [:]
    @ObservationIgnored private var pending: [(seq: Int, move: BoardMove)] = []
    /// Never reset, not even for the next game: the host's `acked` remembers it.
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var drags = 0
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var lastHoldSent = Date.distantPast
    @ObservationIgnored private var endedDrags: [String: Int] = [:]
    @ObservationIgnored private var helloRetry: Task<Void, Never>?

    /// Opens the table over the game in progress.
    init(hosting session: GameSession, name: String, settings: AppSettings?, me: String = deviceID) {
        isHost = true
        self.me = me
        self.name = name
        self.settings = settings
        saveStore = SaveStore()
        players = [TablePlayer(id: me, name: name, slot: 0)]
        attach(session)
    }

    /// Sits down at someone else's table; the game arrives with the host's welcome.
    init(joining link: TableLink, name: String, settings: AppSettings?,
         saveStore: SaveStore = SaveStore(), me: String = deviceID) {
        isHost = false
        self.me = me
        self.name = name
        self.settings = settings
        self.saveStore = saveStore
        add(link)
    }

    /// Anyone besides this player sat down, so the game counts as played together.
    var isTogether: Bool { players.count > 1 }

    var mySlot: Int { players.first { $0.id == me }?.slot ?? 0 }

    func pieces(of player: TablePlayer) -> Int { credit.reduce(0) { $0 + ($1 == player.slot ? 1 : 0) } }

    /// This player's pieces in a game played together; `nil` for a game played alone.
    func ownPieces(in game: GameSession) -> Int? {
        guard game === session, isTogether else { return nil }
        return credit.reduce(0) { $0 + ($1 == mySlot ? 1 : 0) }
    }

    // MARK: - Connections

    func add(_ link: TableLink) {
        links.append(link)
        link.onReceive = { [weak self, weak link] data, peer in
            guard let self, let link else { return }
            receive(data, from: peer, on: link)
        }
        link.onConnect = { [weak self, weak link] peer in
            guard let self, let link else { return }
            connected(peer, on: link)
        }
        link.onDisconnect = { [weak self, weak link] peer in
            guard let self, let link else { return }
            disconnected(peer, on: link)
        }
        // A Game Center match arrives with its players already connected.
        for peer in link.connectedPeers { connected(peer, on: link) }
    }

    /// Leaves the table. The host's guests keep the game as their own.
    func close() {
        helloRetry?.cancel()
        if isHost { sendToGuests(.closed) }
        for link in links { link.close() }
        links = []
        routes = [:]
        host = nil
        release(session)
    }

    private func connected(_ peer: String, on link: TableLink) {
        guard !isHost else { return }
        // Everyone at a nearby table is connected to everyone; only the host answers.
        send(.hello(player: me, name: name, version: TableMessage.version), to: peer, on: link)
        // A Game Center host may still be setting its match up and miss the first hello.
        guard helloRetry == nil else { return }
        helloRetry = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled, host == nil, endReason == nil else { return }
                for link in links {
                    for peer in link.connectedPeers {
                        send(.hello(player: me, name: name, version: TableMessage.version), to: peer, on: link)
                    }
                }
            }
        }
    }

    private func disconnected(_ peer: String, on link: TableLink) {
        if isHost {
            guard let id = routes.first(where: { $0.value.link === link && $0.value.peer == peer })?.key else { return }
            routes[id] = nil
            if let index = players.firstIndex(where: { $0.id == id }) { players[index].isHere = false }
            session?.setRemoteHold(nil, for: id)
            broadcast()
        } else if host?.link === link, host?.peer == peer {
            end(.hostLeft)
        }
    }

    private func receive(_ data: Data, from peer: String, on link: TableLink) {
        guard let message = TableMessage.decode(data) else { return }
        switch message {
        case let .hello(player, name, _):
            if isHost { seat(player, name: name, at: peer, on: link) }
        case let .welcome(game, version):
            guard !isHost else { return }
            guard version == TableMessage.version else { return end(.outdated) }
            host = (link, peer)
            start(game)
        case let .update(update):
            if !isHost, host?.peer == peer { apply(update) }
        case let .move(seq, move, drag):
            guard isHost, let player = routes.first(where: { $0.value.link === link && $0.value.peer == peer })?.key
            else { return }
            play(move, seq: seq, drag: drag, by: player)
        case let .hold(player, drag, piece, translation):
            guard player != me, drag > endedDrags[player] ?? 0 else { return }
            if translation == nil { endedDrags[player] = drag }
            show(player, piece: piece, at: translation)
            if isHost {
                let others = routes.keys.filter { $0 != player }
                sendToGuests(message, only: others, reliable: translation == nil)
            }
        case .closed:
            if !isHost { end(.hostLeft) }
        }
    }

    // MARK: - Host

    /// The host's game, and the next one after "Play again": everyone at the table moves to it.
    func attach(_ session: GameSession) {
        guard isHost else { return }
        release(self.session)
        self.session = session
        credit = Array(repeating: -1, count: session.pieceCount)
        // What the host joined before the table opened is the host's.
        for piece in 0..<Int32(session.pieceCount) {
            if let group = session.state.group(of: piece), group.members.count > 1 || group.isLocked {
                credit[Int(piece)] = Int8(mySlot)
            }
        }
        hook(session)
        session.isShared = players.contains { $0.isHere && $0.id != me }
        for id in routes.keys { send(.welcome(game: session.snapshot(), version: TableMessage.version), to: id) }
        broadcast()
    }

    private func seat(_ id: String, name: String, at peer: String, on link: TableLink) {
        guard let session else { return }
        if let index = players.firstIndex(where: { $0.id == id }) {
            players[index].isHere = true
            players[index].name = name
        } else {
            // A seat nobody has had yet; with all four taken, one whose player left.
            let used = Set(players.map(\.slot)), here = Set(players.filter(\.isHere).map(\.slot))
            guard let slot = (0..<Self.maxPlayers).first(where: { !used.contains($0) })
                ?? (0..<Self.maxPlayers).first(where: { !here.contains($0) }) else { return }
            players.removeAll { $0.slot == slot }
            players.append(TablePlayer(id: id, name: name, slot: slot))
        }
        routes[id] = (link, peer)
        session.isShared = true
        send(.welcome(game: session.snapshot(), version: TableMessage.version), to: id)
        broadcast()
    }

    private func play(_ move: BoardMove, seq: Int, drag: Int, by id: String) {
        guard let session, let player = players.first(where: { $0.id == id }) else { return }
        endedDrags[id] = max(endedDrags[id] ?? 0, drag)
        session.setRemoteHold(nil, for: id)
        let outcome = session.performRemote(move, slot: player.slot)
        acked[id] = seq
        var flashed: [Int32] = []
        if let outcome, outcome.didSnap {
            give(outcome, to: player.slot)
            flashed = session.flashedPieces(outcome)
            if let settings { Feedback.shared.play(.snap, volume: 0.5, settings: settings) }
        }
        broadcast(mover: id, drag: drag, flashed: flashed)
        session.finishIfComplete()
    }

    /// A piece is credited to the player whose move first joined it.
    private func give(_ outcome: SettleOutcome, to slot: Int) {
        guard let members = session?.state.groups[outcome.group]?.members else { return }
        for piece in members where credit.indices.contains(Int(piece)) && credit[Int(piece)] < 0 {
            credit[Int(piece)] = Int8(slot)
        }
    }

    private func broadcast(mover: String? = nil, drag: Int = 0, flashed: [Int32] = []) {
        guard isHost, let session, !routes.isEmpty else { return }
        sendToGuests(.update(TableUpdate(gameID: session.id, state: session.state, elapsed: session.elapsed,
                                         credit: credit, players: players, acked: acked,
                                         mover: mover, moverDrag: drag, flashed: flashed)))
    }

    // MARK: - Guest

    private func start(_ game: GameSnapshot) {
        guard session?.id != game.id else { return }
        release(session)
        let item = LibraryCatalog.builtIn().first { $0.id == game.itemID } ?? game.libraryItem
        let session = GameSession(snapshot: game, item: item, saveStore: saveStore)
        session.waitsForHost = true
        session.isShared = true
        pending = []
        hook(session)
        self.session = session
        onGame?(session)
    }

    private func apply(_ update: TableUpdate) {
        guard let session, update.gameID == session.id else { return }
        players = update.players
        credit = update.credit
        if let mover = update.mover, mover != me {
            endedDrags[mover] = max(endedDrags[mover] ?? 0, update.moverDrag)
            session.setRemoteHold(nil, for: mover)
        }
        for player in players where !player.isHere { session.setRemoteHold(nil, for: player.id) }
        pending.removeAll { $0.seq <= update.acked[me] ?? 0 }
        session.adopt(update.state, replaying: pending.map(\.move), elapsed: update.elapsed)
        if let mover = update.mover, mover != me, !update.flashed.isEmpty,
           let slot = players.first(where: { $0.id == mover })?.slot {
            session.flash(update.flashed, tint: slot)
            if let settings { Feedback.shared.play(.snap, volume: 0.5, settings: settings) }
        }
        session.finishIfComplete()
    }

    private func end(_ reason: EndReason) {
        endReason = reason
        for link in links { link.close() }
        links = []
        host = nil
        release(session)
        session?.finishIfComplete()
    }

    // MARK: - Both

    private func hook(_ session: GameSession) {
        session.onMove = { [weak self] move, outcome in self?.moved(move, outcome) }
        session.onHold = { [weak self] piece, translation in self?.held(piece, at: translation) }
    }

    /// The game goes back to being one player's own.
    private func release(_ session: GameSession?) {
        guard let session else { return }
        session.onMove = nil
        session.onHold = nil
        session.waitsForHost = false
        session.isShared = false
        for player in players { session.setRemoteHold(nil, for: player.id) }
    }

    private func moved(_ move: BoardMove, _ outcome: SettleOutcome?) {
        guard let session else { return }
        if isHost {
            var flashed: [Int32] = []
            if let outcome, outcome.didSnap {
                give(outcome, to: mySlot)
                flashed = session.flashedPieces(outcome)
            }
            broadcast(mover: me, drag: drags, flashed: flashed)
        } else {
            seq += 1
            pending.append((seq, move))
            sendToHost(.move(seq: seq, move: move, drag: drags))
        }
    }

    /// This player's held piece, about twenty times a second.
    private func held(_ piece: Int32, at translation: CGPoint?) {
        if translation != nil {
            if !holding {
                holding = true
                drags += 1
            } else if Date.now.timeIntervalSince(lastHoldSent) < 0.05 {
                return
            }
        } else {
            guard holding else { return }
            holding = false
        }
        lastHoldSent = .now
        let message = TableMessage.hold(player: me, drag: drags, piece: piece, translation: translation)
        if isHost { sendToGuests(message, reliable: translation == nil) } else { sendToHost(message, reliable: translation == nil) }
    }

    private func show(_ id: String, piece: Int32, at translation: CGPoint?) {
        guard let session, let player = players.first(where: { $0.id == id }) else { return }
        session.setRemoteHold(translation.map {
            GameSession.RemoteHold(piece: piece, translation: $0, slot: player.slot, name: player.name)
        }, for: id)
    }

    // MARK: - Sending

    private func send(_ message: TableMessage, to peer: String, on link: TableLink, reliable: Bool = true) {
        guard let data = message.encoded() else { return }
        link.send(data, to: [peer], reliable: reliable)
    }

    private func send(_ message: TableMessage, to player: String) {
        guard let route = routes[player] else { return }
        send(message, to: route.peer, on: route.link)
    }

    private func sendToHost(_ message: TableMessage, reliable: Bool = true) {
        guard let host else { return }
        send(message, to: host.peer, on: host.link, reliable: reliable)
    }

    private func sendToGuests(_ message: TableMessage, only ids: [String]? = nil, reliable: Bool = true) {
        guard let data = message.encoded() else { return }
        for (id, route) in routes where ids?.contains(id) ?? true {
            route.link.send(data, to: [route.peer], reliable: reliable)
        }
    }
}
