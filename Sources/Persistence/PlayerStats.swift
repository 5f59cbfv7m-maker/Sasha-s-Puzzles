import Foundation
import Observation

/// One finished game. Everything the profile shows — totals, best times, the
/// daily streak, achievements, the weekly chart — is derived from this list,
/// so there is exactly one thing to persist and nothing to keep in sync.
nonisolated struct SolvedRecord: Codable, Sendable, Identifiable, Equatable {
    var id = UUID().uuidString
    var itemID: String
    var category: ArtCategory
    var pieces: Int
    var targetPieces: Int
    var elapsed: TimeInterval
    var date: Date
    var isUserPhoto: Bool
}

/// The history as it is stored, locally and in iCloud.
nonisolated struct StatsArchive: Codable, Sendable, Equatable {
    var records: [SolvedRecord] = []
    /// The latest "Reset statistics" on any device. Games finished before it
    /// are gone everywhere, so a device that was offline during the reset
    /// cannot bring them back.
    var resetAt: Date?

    /// Records are only ever added, so merging is a union by id — minus
    /// whatever the newest reset wiped.
    func merged(with other: StatsArchive) -> StatsArchive {
        let reset = [resetAt, other.resetAt].compactMap(\.self).max()
        var seen = Set<String>()
        let records = (records + other.records)
            .filter { record in reset.map { record.date > $0 } ?? true }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date < $1.date }
        return StatsArchive(records: records, resetAt: reset)
    }
}

/// Where the history is mirrored beyond this device: iCloud in the app, an
/// in-memory stand-in in tests, nothing in stage runs and ad-hoc builds.
@MainActor
protocol RecordMirror: AnyObject {
    func load() -> StatsArchive?
    func save(_ archive: StatsArchive)
    /// Set by `PlayerStats`; called when another device changed the mirror.
    var onExternalChange: (() -> Void)? { get set }
}

/// What the completion screen reports about the game just finished.
struct CompletionSummary: Equatable {
    var previousBest: TimeInterval?
    var newAchievements: [Achievement]
}

/// The player's history, kept in one JSON file in the app container and
/// merged with every other device on the same Apple Account through the mirror.
@Observable
@MainActor
final class PlayerStats {
    private(set) var records: [SolvedRecord] = []
    @ObservationIgnored private var resetAt: Date?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let mirror: RecordMirror?
    /// Fired whenever records arrive from another device.
    @ObservationIgnored var onExternalChange: (() -> Void)?

    init(directory: URL = PhotoLibraryStore.containerDirectory, mirror: RecordMirror? = nil) {
        url = directory.appending(path: "stats.json")
        self.mirror = mirror
        apply(Self.read(url))
        mirror?.onExternalChange = { [weak self] in self?.pull() }
        pull()
    }

    private var archive: StatsArchive { StatsArchive(records: records, resetAt: resetAt) }

    private func apply(_ archive: StatsArchive) {
        if records != archive.records { records = archive.records }
        resetAt = archive.resetAt
    }

    /// Reads both layouts: the archive, and the bare record list of 1.0.
    private static func read(_ url: URL) -> StatsArchive {
        guard let data = try? Data(contentsOf: url) else { return StatsArchive() }
        if let archive = try? JSONDecoder().decode(StatsArchive.self, from: data) { return archive }
        return StatsArchive(records: (try? JSONDecoder().decode([SolvedRecord].self, from: data)) ?? [])
    }

    /// Takes in what other devices added; hands back what this one has that they lack.
    private func pull() {
        guard let mirror else { return }
        guard let remote = mirror.load() else {
            if archive != StatsArchive() { mirror.save(archive) }
            return
        }
        let merged = archive.merged(with: remote)
        if merged != archive {
            apply(merged)
            write()
            onExternalChange?()
        }
        if merged != remote { mirror.save(merged) }
    }

    /// Writes locally, then publishes — merged with the mirror first, because
    /// saving to it replaces whatever another device put there meanwhile.
    private func persist() {
        if let remote = mirror?.load() { apply(archive.merged(with: remote)) }
        write()
        mirror?.save(archive)
    }

    private func write() {
        try? JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }

    @discardableResult
    func record(_ session: GameSession) -> CompletionSummary {
        record(SolvedRecord(itemID: session.item.id, category: session.item.category,
                            pieces: session.pieceCount, targetPieces: session.targetPieces,
                            elapsed: session.elapsed, date: .now,
                            isUserPhoto: session.item.isUserPhoto))
    }

    @discardableResult
    func record(_ solved: SolvedRecord) -> CompletionSummary {
        let before = Achievement.allCases.filter { $0.isUnlocked(in: self) }
        let previousBest = bestTime(for: solved.itemID)
        records.append(solved)
        persist()
        let new = Achievement.allCases.filter { $0.isUnlocked(in: self) && !before.contains($0) }
        return CompletionSummary(previousBest: previousBest, newAchievements: new)
    }

    /// Clears the history here and on every other device.
    func reset() {
        records = []
        resetAt = .now
        persist()
    }

    // MARK: - Derived

    var puzzlesSolved: Int { records.count }
    var piecesPlaced: Int { records.reduce(0) { $0 + $1.pieces } }
    var timePlayed: TimeInterval { records.reduce(0) { $0 + $1.elapsed } }
    var firstPlayed: Date? { records.map(\.date).min() }

    func bestTime(for itemID: String) -> TimeInterval? {
        records.filter { $0.itemID == itemID }.map(\.elapsed).min()
    }

    func isSolved(_ itemID: String) -> Bool { records.contains { $0.itemID == itemID } }

    // MARK: Daily puzzle

    /// A game counts as that day's daily puzzle when it is the day's picture at
    /// the daily piece count — no flag to persist, nothing to migrate.
    func isDaily(_ record: SolvedRecord) -> Bool {
        record.targetPieces == LibraryCatalog.dailyPieces
            && record.itemID == LibraryCatalog.dailyItem(on: record.date).id
    }

    private var dailyDays: Set<Date> {
        let calendar = Calendar.current
        return Set(records.filter(isDaily).map { calendar.startOfDay(for: $0.date) })
    }

    var dailySolvedToday: Bool { dailyDays.contains(Calendar.current.startOfDay(for: .now)) }

    /// Today's best time on the daily puzzle, if it has been solved.
    var dailyBestToday: TimeInterval? {
        let calendar = Calendar.current
        return records.filter { isDaily($0) && calendar.isDateInToday($0.date) }.map(\.elapsed).min()
    }

    /// The longest run of consecutive daily puzzles ever, not just the current one.
    var longestStreak: Int {
        let calendar = Calendar.current
        var best = 0, run = 0
        var previous: Date?
        for day in dailyDays.sorted() {
            let follows = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day
            run = follows ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// Consecutive daily puzzles ending today or, if today's is still open, yesterday.
    var streak: Int {
        let calendar = Calendar.current
        let days = dailyDays
        var day = calendar.startOfDay(for: .now)
        if !days.contains(day) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
            guard days.contains(day) else { return 0 }
        }
        var count = 0
        while days.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    /// Pieces solved per week over the last twelve weeks, oldest first.
    var weeklyPieces: [Int] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return (0..<12).reversed().map { back in
            let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek)!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return records.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.pieces }
        }
    }
}

/// Milestones derived from the history. Order here is display order.
nonisolated enum Achievement: String, CaseIterable, Identifiable, Sendable {
    case firstPuzzle, tenPuzzles, fiftyPuzzles, sprinter, nightmare, weekStreak, ownPhoto,
         space, nature, mountains, sea, city, animals, abstract

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstPuzzle: String(localized: "First piece")
        case .tenPuzzles: String(localized: "Regular")
        case .fiftyPuzzles: String(localized: "Collector")
        case .sprinter: String(localized: "Sprinter")
        case .nightmare: String(localized: "Nightmare survived")
        case .weekStreak: String(localized: "A week in a row")
        case .ownPhoto: String(localized: "Family album")
        case .space: String(localized: "Stargazer")
        case .nature: String(localized: "Naturalist")
        case .mountains: String(localized: "Mountaineer")
        case .sea: String(localized: "Master of water")
        case .city: String(localized: "City lights")
        case .animals: String(localized: "Zookeeper")
        case .abstract: String(localized: "Abstract mind")
        }
    }

    var detail: String {
        switch self {
        case .firstPuzzle: String(localized: "solve your first puzzle")
        case .tenPuzzles: String(localized: "solve 10 puzzles")
        case .fiftyPuzzles: String(localized: "solve 50 puzzles")
        case .sprinter: String(localized: "48 pieces in 5 minutes")
        case .nightmare: String(localized: "solve 800 pieces")
        case .weekStreak: String(localized: "7 daily puzzles in a row")
        case .ownPhoto: String(localized: "solve one of your own photos")
        case .space, .nature, .mountains, .sea, .city, .animals, .abstract:
            String(localized: "all “\(category!.title)” puzzles")
        }
    }

    var symbol: String {
        switch self {
        case .firstPuzzle: "puzzlepiece.fill"
        case .tenPuzzles: "star.fill"
        case .fiftyPuzzles: "trophy.fill"
        case .sprinter: "clock.fill"
        case .nightmare: "moon.stars.fill"
        case .weekStreak: "flame.fill"
        case .ownPhoto: "heart.fill"
        default: category!.symbol
        }
    }

    var category: ArtCategory? {
        switch self {
        case .space: .space
        case .nature: .nature
        case .mountains: .mountains
        case .sea: .sea
        case .city: .city
        case .animals: .animals
        case .abstract: .abstract
        default: nil
        }
    }
}

@MainActor
extension Achievement {
    func isUnlocked(in stats: PlayerStats) -> Bool {
        switch self {
        case .firstPuzzle: return stats.puzzlesSolved >= 1
        case .tenPuzzles: return stats.puzzlesSolved >= 10
        case .fiftyPuzzles: return stats.puzzlesSolved >= 50
        case .sprinter: return stats.records.contains { $0.pieces >= 48 && $0.elapsed <= 300 }
        case .nightmare: return stats.records.contains { $0.pieces >= 800 }
        case .weekStreak: return stats.streak >= 7
        case .ownPhoto: return stats.records.contains(where: \.isUserPhoto)
        default:
            let builtIn = LibraryCatalog.builtIn().filter { $0.category == category }
            return !builtIn.isEmpty && builtIn.allSatisfy { stats.isSolved($0.id) }
        }
    }
}
