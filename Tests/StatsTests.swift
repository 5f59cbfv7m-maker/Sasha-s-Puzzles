import Foundation
import Testing
@testable import JigsawPuzzle

@Suite("Player statistics")
@MainActor
struct StatsTests {

    private func temporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "JigsawTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func daily(daysAgo: Int, elapsed: TimeInterval = 600) -> SolvedRecord {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let item = LibraryCatalog.dailyItem(on: date)
        return SolvedRecord(itemID: item.id, category: item.category, pieces: 150,
                            targetPieces: LibraryCatalog.dailyPieces, elapsed: elapsed,
                            date: date, isUserPhoto: false)
    }

    @Test("The streak counts consecutive daily puzzles and survives a reload")
    func streak() throws {
        let directory = try temporaryDirectory()
        let stats = PlayerStats(directory: directory)
        #expect(stats.streak == 0)

        // Yesterday and the day before, today still open: the streak stands at 2.
        stats.record(daily(daysAgo: 1))
        stats.record(daily(daysAgo: 2))
        #expect(stats.streak == 2)
        #expect(!stats.dailySolvedToday)

        // A gap three days back breaks the chain.
        stats.record(daily(daysAgo: 4))
        #expect(stats.streak == 2)

        stats.record(daily(daysAgo: 0))
        #expect(stats.streak == 3)
        #expect(stats.dailySolvedToday)

        let reloaded = PlayerStats(directory: directory)
        #expect(reloaded.streak == 3)
        #expect(reloaded.puzzlesSolved == 4)
    }

    @Test("Finishing a game reports new achievements and the previous best time")
    func completionSummary() throws {
        let stats = PlayerStats(directory: try temporaryDirectory())
        let first = stats.record(daily(daysAgo: 0, elapsed: 900))
        #expect(first.newAchievements == [.firstPuzzle])
        #expect(first.previousBest == nil)

        let second = stats.record(daily(daysAgo: 0, elapsed: 240))
        #expect(second.previousBest == 900)
        // 150 pieces in four minutes is a sprint.
        #expect(second.newAchievements == [.sprinter])
        #expect(stats.bestTime(for: LibraryCatalog.dailyItem().id) == 240)
    }

    @Test("Points: a point a piece, more for big puzzles, the daily doubled once a day with a streak bonus")
    func points() throws {
        #expect(PlayerStats.points(pieces: 48) == 48)
        #expect(PlayerStats.points(pieces: 150) == 188)
        #expect(PlayerStats.points(pieces: 800) == 1200)

        let stats = PlayerStats(directory: try temporaryDirectory())
        stats.record(SolvedRecord(itemID: "bundled.sea_Clownfish", category: .sea, pieces: 48, targetPieces: 48,
                                  elapsed: 300, date: .now, isUserPhoto: false))
        #expect(stats.points == 48)
        // Two days in a row: 2 × 188 + 50, then 2 × 188 + 100.
        stats.record(daily(daysAgo: 1))
        stats.record(daily(daysAgo: 0))
        #expect(stats.points == 48 + 426 + 476)
        // Replaying today's daily is an ordinary game.
        let replay = stats.record(daily(daysAgo: 0))
        #expect(replay.pointsEarned == 188)
    }

    @Test("Points open the reward pictures four at a time, one per category")
    func rewardPictures() throws {
        let order = LibraryCatalog.rewardOrder
        #expect(order.count == LibraryCatalog.rewardThresholds.count * 4)
        #expect(Set(order) == LibraryCatalog.addedIn1_2)
        for tier in stride(from: 0, to: order.count, by: 4) {
            let categories = order[tier..<tier + 4].map { $0.split(separator: "_")[0] }
            #expect(Set(categories).count == 4)
        }
        let stats = PlayerStats(directory: try temporaryDirectory())
        let first = stats.record(SolvedRecord(itemID: "bundled.sea_Clownfish", category: .sea, pieces: 300,
                                              targetPieces: 300, elapsed: 3000, date: .now, isUserPhoto: false))
        #expect(first.pointsEarned == 375)
        #expect(first.unlockedPictures == Array(order.prefix(4)))
        #expect(LibraryCatalog.nextThreshold(after: stats.points) == 1_000)
    }

    @Test("Every seven daily puzzles in a row open one secret picture, and a broken streak keeps it")
    func secretGifts() throws {
        let stats = PlayerStats(directory: try temporaryDirectory())
        for day in (9...14).reversed() { stats.record(daily(daysAgo: day)) }
        #expect(stats.giftsEarned == 0)
        let seventh = stats.record(daily(daysAgo: 8))
        #expect(stats.giftsEarned == 1)
        #expect(seventh.unlockedPictures.first == LibraryCatalog.secretOrder[0])
        // A gap, then a fresh run of seven earns the second.
        for day in (0...6).reversed() { stats.record(daily(daysAgo: day)) }
        #expect(stats.giftsEarned == 2)
    }

    @Test("A category achievement needs every built-in picture of that category")
    func categoryAchievement() throws {
        let stats = PlayerStats(directory: try temporaryDirectory())
        let sea = LibraryCatalog.builtIn().filter { $0.category == .sea }
        for item in sea.dropLast() {
            stats.record(SolvedRecord(itemID: item.id, category: .sea, pieces: 24, targetPieces: 24,
                                      elapsed: 100, date: .now, isUserPhoto: false))
        }
        #expect(!Achievement.sea.isUnlocked(in: stats))
        let summary = stats.record(SolvedRecord(itemID: sea.last!.id, category: .sea, pieces: 24,
                                                targetPieces: 24, elapsed: 100, date: .now,
                                                isUserPhoto: false))
        #expect(summary.newAchievements.contains(.sea))
        #expect(stats.weeklyPieces.count == 12)
        #expect(stats.weeklyPieces.last == 24 * sea.count)
    }

    @Test("Achievement bars count towards each goal")
    func achievementProgress() throws {
        let stats = PlayerStats(directory: try temporaryDirectory())
        #expect(Achievement.tenPuzzles.progress(in: stats).fraction == 0)
        #expect(Achievement.sprinter.progress(in: stats).label == "– / 5:00")
        for day in 0..<3 { stats.record(daily(daysAgo: day, elapsed: 600)) }
        #expect(Achievement.tenPuzzles.progress(in: stats).label == "3 / 10")
        #expect(Achievement.firstPuzzle.progress(in: stats).fraction == 1)
        #expect(Achievement.weekStreak.progress(in: stats).label == "3 / 7")
        // Ten minutes against five: halfway.
        #expect(Achievement.sprinter.progress(in: stats).fraction == 0.5)
    }

    @Test("The longest streak remembers a run that has since broken")
    func longestStreak() throws {
        let stats = PlayerStats(directory: try temporaryDirectory())
        for days in [9, 8, 7, 6, 2, 1] { stats.record(daily(daysAgo: days)) }
        #expect(stats.streak == 2)
        #expect(stats.longestStreak == 4)
        #expect(stats.dailyBestToday == nil)
        stats.record(daily(daysAgo: 0, elapsed: 420))
        stats.record(daily(daysAgo: 0, elapsed: 380))
        #expect(stats.dailyBestToday == 380)
    }

    @Test("Streak medals and the first gift stay earned after the streak breaks")
    func streakMedalsLast() throws {
        let stats = PlayerStats(directory: try temporaryDirectory())
        for day in (8...14).reversed() { stats.record(daily(daysAgo: day)) }
        #expect(stats.streak == 0)
        #expect(Achievement.weekStreak.isUnlocked(in: stats))
        #expect(Achievement.firstGift.isUnlocked(in: stats))
        #expect(Achievement.twoWeekStreak.progress(in: stats).label == "7 / 14")
        #expect(!Achievement.allSecrets.isUnlocked(in: stats))
    }

    @Test("The weekly board counts the games since Monday 00:00 UTC")
    func weeklyPoints() throws {
        // Friday 23 October 2026 → Monday 19 October, midnight UTC.
        let friday = Date(timeIntervalSince1970: 1_792_746_000)
        #expect(PlayerStats.leaderboardWeekStart(for: friday) == Date(timeIntervalSince1970: 1_792_368_000))

        let start = PlayerStats.leaderboardWeekStart()
        let stats = PlayerStats(directory: try temporaryDirectory())
        for date in [start.addingTimeInterval(-3600), .now] {
            stats.record(SolvedRecord(itemID: "bundled.sea_Clownfish", category: .sea, pieces: 48, targetPieces: 48,
                                      elapsed: 300, date: date, isUserPhoto: false))
        }
        #expect(stats.points == 96)
        #expect(stats.points(since: start) == 48)
    }

    @Test("Tiered achievements: a thousand pieces as asked, points, and the record in the summary")
    func tiers() throws {
        let stats = PlayerStats(directory: try temporaryDirectory())
        // A 1,000-piece cut that came out a few pieces short still counts.
        let big = SolvedRecord(itemID: "bundled.sea_Clownfish", category: .sea, pieces: 990, targetPieces: 1000,
                               elapsed: 9000, date: .now, isUserPhoto: false)
        let summary = stats.record(big)
        #expect(summary.solved == big)
        #expect(summary.newAchievements.contains(.thousand))
        #expect(summary.newAchievements.contains(.points1k))
        #expect(Achievement.points5k.progress(in: stats).label == "1485 / 5000")
        #expect(Achievement.hundredPuzzles.progress(in: stats).label == "1 / 100")
        #expect(Achievement.allSecrets.isHidden && !Achievement.thousand.isHidden)
    }

    @Test("Two devices end up with the union of their games, and a reset reaches both")
    func cloudMerge() throws {
        let cloud = MemoryMirror()
        let phone = PlayerStats(directory: try temporaryDirectory(), mirror: cloud.attach())
        phone.record(daily(daysAgo: 2))

        let mac = PlayerStats(directory: try temporaryDirectory(), mirror: cloud.attach())
        #expect(mac.puzzlesSolved == 1)   // the phone's game arrived on first launch
        mac.record(daily(daysAgo: 1))
        #expect(phone.puzzlesSolved == 2) // and the Mac's game arrived on the phone
        #expect(phone.streak == 2)

        // A device that was offline keeps its games locally; they survive
        // until they reach iCloud.
        let directory = try temporaryDirectory()
        let offline = PlayerStats(directory: directory)
        offline.record(daily(daysAgo: 5))
        let reconnected = PlayerStats(directory: directory, mirror: cloud.attach())
        #expect(reconnected.puzzlesSolved == 3)
        #expect(phone.puzzlesSolved == 3)

        phone.reset()
        #expect(mac.puzzlesSolved == 0)
        #expect(reconnected.puzzlesSolved == 0)

        // Games finished after the reset still sync.
        mac.record(SolvedRecord(itemID: "x", category: .sea, pieces: 12, targetPieces: 12,
                                elapsed: 60, date: .now.addingTimeInterval(1), isUserPhoto: false))
        #expect(phone.puzzlesSolved == 1)
    }

    @Test("A 1.0 stats file — a bare list of records — still loads")
    func legacyFile() throws {
        let directory = try temporaryDirectory()
        let records = [daily(daysAgo: 1), daily(daysAgo: 0)]
        try JSONEncoder().encode(records).write(to: directory.appending(path: "stats.json"))
        let stats = PlayerStats(directory: directory)
        #expect(stats.puzzlesSolved == 2)
        #expect(stats.streak == 2)
    }
}

/// iCloud key-value storage in memory: every attached device sees every save,
/// and each one is told when another device changed it.
@MainActor
private final class MemoryMirror {
    private var archive: StatsArchive?
    private var devices: [Device] = []

    final class Device: RecordMirror {
        unowned let cloud: MemoryMirror
        var onExternalChange: (() -> Void)?
        init(cloud: MemoryMirror) { self.cloud = cloud }
        func load() -> StatsArchive? { cloud.archive }
        func save(_ archive: StatsArchive) {
            cloud.archive = archive
            for device in cloud.devices where device !== self { device.onExternalChange?() }
        }
    }

    func attach() -> Device {
        let device = Device(cloud: self)
        devices.append(device)
        return device
    }
}
