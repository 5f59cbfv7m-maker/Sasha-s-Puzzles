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
