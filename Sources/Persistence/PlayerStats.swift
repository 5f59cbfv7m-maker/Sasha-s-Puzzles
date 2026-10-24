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
    /// The pieces this player joined in a puzzle solved together; `nil` alone.
    /// Points go by these, and a shared game never counts for times or the daily.
    var sharedPieces: Int?

    var isShared: Bool { sharedPieces != nil }
    /// The pieces this player put in.
    var ownPieces: Int { sharedPieces ?? pieces }
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
    var pointsEarned = 0
    /// Reward pictures this game's points opened, in unlock order.
    var unlockedPictures: [String] = []
    /// The game itself, for Game Center.
    var solved: SolvedRecord?
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
    func record(_ session: GameSession, sharedPieces: Int? = nil) -> CompletionSummary {
        record(SolvedRecord(itemID: session.item.id, category: session.item.category,
                            pieces: session.pieceCount, targetPieces: session.targetPieces,
                            elapsed: session.elapsed, date: .now,
                            isUserPhoto: session.item.isUserPhoto, sharedPieces: sharedPieces))
    }

    @discardableResult
    func record(_ solved: SolvedRecord) -> CompletionSummary {
        let before = Achievement.allCases.filter { $0.isUnlocked(in: self) }
        let previousBest = bestTime(for: solved.itemID)
        let pointsBefore = points, giftsBefore = giftsEarned
        records.append(solved)
        persist()
        let new = Achievement.allCases.filter { $0.isUnlocked(in: self) && !before.contains($0) }
        let pointsAfter = points
        let secrets = LibraryCatalog.secretOrder
        let opened = Array(secrets[min(giftsBefore, secrets.count)..<min(giftsEarned, secrets.count)])
            + LibraryCatalog.rewardOrder.filter { id in
                let need = LibraryCatalog.requiredPoints(for: id) ?? 0
                return need > pointsBefore && need <= pointsAfter
            }
        return CompletionSummary(previousBest: previousBest, newAchievements: new,
                                 pointsEarned: pointsAfter - pointsBefore, unlockedPictures: opened,
                                 solved: solved)
    }

    /// Clears the history here and on every other device.
    func reset() {
        records = []
        resetAt = .now
        persist()
    }

    // MARK: - Derived

    var puzzlesSolved: Int { records.count }
    var piecesPlaced: Int { records.reduce(0) { $0 + $1.ownPieces } }
    var timePlayed: TimeInterval { records.reduce(0) { $0 + $1.elapsed } }
    var firstPlayed: Date? { records.map(\.date).min() }

    func bestTime(for itemID: String) -> TimeInterval? {
        records.filter { $0.itemID == itemID && !$0.isShared }.map(\.elapsed).min()
    }

    func isSolved(_ itemID: String) -> Bool { records.contains { $0.itemID == itemID } }

    // MARK: Daily puzzle

    /// A game counts as that day's daily puzzle when it is the day's picture at
    /// the daily piece count — no flag to persist, nothing to migrate.
    func isDaily(_ record: SolvedRecord) -> Bool {
        !record.isShared && record.targetPieces == LibraryCatalog.dailyPieces
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

    // MARK: Points

    /// A point a piece, and more a piece for big puzzles: they take far longer
    /// per piece, and small ones would otherwise be the way to farm points.
    /// `own` is the pieces this player put into a shared puzzle; the bonus
    /// still goes by the size of the whole puzzle.
    nonisolated static func points(pieces: Int, own: Int? = nil) -> Int {
        let multiplier = pieces < 150 ? 1.0 : pieces < 500 ? 1.25 : 1.5
        return Int((Double(own ?? pieces) * multiplier).rounded())
    }

    /// Every solved puzzle's points. The first daily puzzle of each day counts
    /// double plus 50 a day of the streak it extended (at most 350); replays
    /// of the daily are ordinary games, so it cannot be farmed. Nothing is
    /// ever deducted — not for hints, not for time. Derived from the records
    /// like everything else here, so it syncs and backfills by itself.
    var points: Int { pointsByRecord.reduce(0) { $0 + $1.points } }

    /// Points from the games finished since `start` — the weekly leaderboard.
    func points(since start: Date) -> Int {
        pointsByRecord.reduce(0) { $0 + ($1.date >= start ? $1.points : 0) }
    }

    /// What each record added to `points`, so the total and the week agree.
    private var pointsByRecord: [(date: Date, points: Int)] {
        let calendar = Calendar.current
        var run: [Date: Int] = [:]
        var previous: Date?
        for day in dailyDays.sorted() {
            let follows = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day
            run[day] = follows ? (run[previous!] ?? 0) + 1 : 1
            previous = day
        }
        var rewarded = Set<Date>()
        return records.map { record in
            let base = Self.points(pieces: record.pieces, own: record.sharedPieces)
            guard isDaily(record) else { return (record.date, base) }
            let day = calendar.startOfDay(for: record.date)
            guard rewarded.insert(day).inserted else { return (record.date, base) }
            return (record.date, base * 2 + min(run[day] ?? 1, 7) * 50)
        }
    }

    /// Monday 00:00 UTC of the current week: when the `points_week`
    /// leaderboard restarts in App Store Connect.
    nonisolated static func leaderboardWeekStart(for date: Date = .now) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateInterval(of: .weekOfYear, for: date)!.start
    }

    /// One gift for every seven daily puzzles in a row: a run of 15 days is
    /// two, and a broken streak keeps what it earned.
    var giftsEarned: Int {
        let calendar = Calendar.current
        var gifts = 0, run = 0
        var previous: Date?
        for day in dailyDays.sorted() {
            let follows = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day
            run = follows ? run + 1 : 1
            if run % 7 == 0 { gifts += 1 }
            previous = day
        }
        return gifts
    }

    /// Pieces solved per week over the last twelve weeks, oldest first.
    var weeklyPieces: [Int] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return (0..<12).reversed().map { back in
            let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek)!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return records.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.ownPieces }
        }
    }
}

/// Milestones derived from the history. Order here is display order; the
/// raw values are Game Center identifiers (`achievement.<rawValue>`), so
/// they can never change.
nonisolated enum Achievement: String, CaseIterable, Identifiable, Sendable {
    case firstPuzzle, tenPuzzles, fiftyPuzzles, hundredPuzzles, twoFiftyPuzzles,
         sprinter, nightmare, thousand,
         weekStreak, twoWeekStreak, monthStreak,
         points1k, points5k, allRewards,
         firstGift, allSecrets, ownPhoto,
         space, nature, mountains, sea, city, animals, abstract

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstPuzzle: String(localized: "First piece")
        case .tenPuzzles: String(localized: "Regular")
        case .fiftyPuzzles: String(localized: "Collector")
        case .hundredPuzzles: String(localized: "Puzzle master")
        case .twoFiftyPuzzles: String(localized: "Puzzle legend")
        case .sprinter: String(localized: "Sprinter")
        case .nightmare: String(localized: "Nightmare survived")
        case .thousand: String(localized: "A thousand pieces")
        case .weekStreak: String(localized: "A week in a row")
        case .twoWeekStreak: String(localized: "Two weeks strong")
        case .monthStreak: String(localized: "A month of mornings")
        case .points1k: String(localized: "First thousand")
        case .points5k: String(localized: "Point hoarder")
        case .allRewards: String(localized: "Full gallery")
        case .firstGift: String(localized: "A surprise")
        case .allSecrets: String(localized: "Keeper of secrets")
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
        case .hundredPuzzles: String(localized: "solve 100 puzzles")
        case .twoFiftyPuzzles: String(localized: "solve 250 puzzles")
        case .sprinter: String(localized: "48 pieces in 5 minutes")
        case .nightmare: String(localized: "solve 800 pieces")
        case .thousand: String(localized: "solve a puzzle of 1,000 pieces")
        case .weekStreak: String(localized: "7 daily puzzles in a row")
        case .twoWeekStreak: String(localized: "14 daily puzzles in a row")
        case .monthStreak: String(localized: "30 daily puzzles in a row")
        case .points1k: String(localized: "earn 1,000 points")
        case .points5k: String(localized: "earn 5,000 points")
        case .allRewards: String(localized: "open every reward picture")
        case .firstGift: String(localized: "open a secret picture")
        case .allSecrets: String(localized: "open all 22 secret pictures")
        case .ownPhoto: String(localized: "solve one of your own photos")
        case .space, .nature, .mountains, .sea, .city, .animals, .abstract:
            String(localized: "all “\(category!.title)” puzzles")
        }
    }

    /// Kept out of sight until earned, here and in Game Center.
    var isHidden: Bool { self == .firstGift || self == .allSecrets }

    var symbol: String {
        switch self {
        case .firstPuzzle: "puzzlepiece.fill"
        case .tenPuzzles: "star.fill"
        case .fiftyPuzzles, .hundredPuzzles, .twoFiftyPuzzles: "trophy.fill"
        case .sprinter: "clock.fill"
        case .nightmare, .thousand: "moon.stars.fill"
        case .weekStreak, .twoWeekStreak, .monthStreak: "flame.fill"
        case .points1k, .points5k, .allRewards: "star.circle.fill"
        case .firstGift, .allSecrets: "gift.fill"
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
        case .sprinter: return stats.records.contains { $0.pieces >= 48 && $0.elapsed <= 300 && !$0.isShared }
        case .ownPhoto: return stats.records.contains(where: \.isUserPhoto)
        default: return progress(in: stats).fraction >= 1
        }
    }

    /// How far along the player is, for the profile's bar and Game Center.
    /// The label is numbers only ("3 / 10"), so it needs no translation.
    func progress(in stats: PlayerStats) -> (fraction: Double, label: String) {
        func count(_ done: Int, _ goal: Int) -> (fraction: Double, label: String) {
            let done = min(done, goal)
            return (goal > 0 ? Double(done) / Double(goal) : 0, "\(done) / \(goal)")
        }
        switch self {
        case .firstPuzzle: return count(stats.puzzlesSolved, 1)
        case .tenPuzzles: return count(stats.puzzlesSolved, 10)
        case .fiftyPuzzles: return count(stats.puzzlesSolved, 50)
        case .hundredPuzzles: return count(stats.puzzlesSolved, 100)
        case .twoFiftyPuzzles: return count(stats.puzzlesSolved, 250)
        case .sprinter:
            // The best 48-piece-or-more time against the five minutes.
            guard let best = stats.records.filter({ $0.pieces >= 48 && !$0.isShared }).map(\.elapsed).min() else {
                return (0, "– / 5:00")
            }
            return (min(1, 300 / max(best, 1)), "\(TimeFormatting.short(best)) / 5:00")
        case .nightmare: return count(stats.records.map(\.pieces).max() ?? 0, 800)
        // The size the player asked for: a 1,000-piece cut can come out a few pieces short.
        case .thousand: return count(stats.records.map(\.targetPieces).max() ?? 0, 1000)
        // The longest run, so a medal stays earned after the streak breaks.
        case .weekStreak: return count(stats.longestStreak, 7)
        case .twoWeekStreak: return count(stats.longestStreak, 14)
        case .monthStreak: return count(stats.longestStreak, 30)
        case .points1k: return count(stats.points, 1000)
        case .points5k: return count(stats.points, 5000)
        case .allRewards: return count(stats.points, LibraryCatalog.rewardThresholds.last!)
        case .firstGift: return count(stats.giftsEarned, 1)
        case .allSecrets: return count(stats.giftsEarned, LibraryCatalog.secretOrder.count)
        case .ownPhoto: return count(stats.records.contains(where: \.isUserPhoto) ? 1 : 0, 1)
        default:
            let builtIn = LibraryCatalog.builtIn().filter { $0.category == category }
            return count(builtIn.filter { stats.isSolved($0.id) }.count, builtIn.count)
        }
    }
}
