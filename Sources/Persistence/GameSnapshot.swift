import CoreGraphics
import Foundation

/// Everything needed to resume a game, and nothing more.
///
/// Geometry is *not* stored: `seed`, `columns` and `rows` regenerate the exact
/// same Bézier edges on any device. A 800-piece save is therefore a few tens of
/// kilobytes rather than megabytes of control points.
nonisolated struct GameSnapshot: Codable, Sendable, Identifiable {
    static let currentVersion = 1

    var version: Int = GameSnapshot.currentVersion
    var id: String
    var itemID: String
    var itemTitle: String
    var source: ImageSource
    var imageAspect: CGFloat
    var puzzleAspect: PuzzleAspect
    var targetPieces: Int
    var columns: Int
    var rows: Int
    var seed: UInt64
    var elapsed: TimeInterval
    var state: PuzzleState
    var updatedAt: Date
    var isComplete: Bool

    var pieceCount: Int { columns * rows }

    var libraryItem: LibraryItem {
        LibraryItem(id: itemID, title: itemTitle,
                    category: source.isUserPhoto ? .mine : .abstract,
                    source: source, addedAt: .distantPast, aspect: imageAspect)
    }
}

/// Reads and writes saved games as one small JSON file.
///
/// Deliberately not a database: a puzzle save is a single document that is
/// rewritten wholesale, and an atomic file write is both faster and far harder
/// to corrupt than a partially-migrated store.
nonisolated struct SaveStore: Sendable {
    private let url: URL

    init(directory: URL = PhotoLibraryStore.containerDirectory) {
        self.url = directory.appending(path: "savedGames.json")
    }

    private struct Archive: Codable {
        var version = 1
        var games: [GameSnapshot]

        init(games: [GameSnapshot]) { self.games = games }

        /// Game by game: one entry this build cannot read — a picture source
        /// that no longer exists, such as the retired generated artwork —
        /// drops only that game, never every save on the device.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            var list = try container.nestedUnkeyedContainer(forKey: .games)
            var games: [GameSnapshot] = []
            while !list.isAtEnd {
                if let game = try? list.decode(GameSnapshot.self) {
                    games.append(game)
                } else {
                    _ = try list.decode(Skipped.self)
                }
            }
            self.games = games
        }

        /// Consumes one element of any shape, so the list can move past it.
        private nonisolated struct Skipped: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }

    func load() -> [GameSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return [] }
        return archive.games
            .filter { $0.version <= GameSnapshot.currentVersion }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Inserts or replaces one game, keeping the most recent `limit` entries.
    func save(_ snapshot: GameSnapshot, limit: Int = 12) throws {
        var games = load().filter { $0.id != snapshot.id }
        games.insert(snapshot, at: 0)
        try write(Array(games.prefix(limit)))
    }

    func delete(id: String) throws {
        try write(load().filter { $0.id != id })
    }

    func deleteAll() throws { try write([]) }

    private func write(_ games: [GameSnapshot]) throws {
        let data = try JSONEncoder().encode(Archive(games: games))
        try data.write(to: url, options: .atomic)
    }
}

/// Unfinished games as shared between devices. The newest copy of a game
/// wins; a game finished or deleted anywhere leaves a dated tombstone, so
/// other devices drop their copy instead of putting it back.
nonisolated struct SharedGames: Codable, Sendable {
    var games: [GameSnapshot] = []
    var gone: [String: Date] = [:]

    /// What this device contributes: unfinished games on bundled pictures
    /// (an imported photo exists only here), and finished ones as tombstones.
    init(local: [GameSnapshot], gone: [String: Date] = [:]) {
        games = local.filter { !$0.isComplete && !$0.source.isUserPhoto }
        self.gone = gone
        for game in local where game.isComplete { self.gone[game.id] = max(self.gone[game.id] ?? .distantPast, game.updatedAt) }
    }

    init(games: [GameSnapshot] = [], gone: [String: Date] = [:]) {
        self.games = games
        self.gone = gone
    }

    // ponytail: tombstones expire after 60 days; a device offline longer may bring a deleted game back.
    func merged(with other: SharedGames, limit: Int = 12, now: Date = .now) -> SharedGames {
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        let gone = self.gone.merging(other.gone, uniquingKeysWith: max).filter { $0.value > cutoff }
        var newest: [String: GameSnapshot] = [:]
        for game in games + other.games where (newest[game.id]?.updatedAt ?? .distantPast) < game.updatedAt {
            newest[game.id] = game
        }
        let kept = newest.values
            .filter { game in gone[game.id].map { $0 < game.updatedAt } ?? true }
            .sorted { $0.updatedAt > $1.updatedAt }
        return SharedGames(games: Array(kept.prefix(limit)), gone: gone)
    }
}
