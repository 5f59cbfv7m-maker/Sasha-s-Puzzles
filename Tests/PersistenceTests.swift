import CoreGraphics
import Foundation
import Testing
@testable import JigsawPuzzle

@Suite("Persistence and serialisation")
struct PersistenceTests {

    private func temporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "JigsawTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleSnapshot(id: String = "game-1") -> GameSnapshot {
        var state = PuzzleState(columns: 6, rows: 4, cellSize: CGSize(width: 50, height: 50))
        var rng = SplitMix64(seed: 3)
        state.shuffleTray(using: &rng)
        state.placeFromTray(0, translation: .zero)
        let group = state.placeFromTray(1, translation: CGPoint(x: 3, y: 3))
        _ = state.settle(group: group, tolerance: 20)

        return GameSnapshot(id: id, itemID: "bundled.space_Milky Way", itemTitle: "Milky Way",
                            source: .bundled(fileName: "space_Milky Way.jpg"), imageAspect: 1.5,
                            puzzleAspect: .landscape32, targetPieces: 24, columns: 6, rows: 4,
                            seed: 0xABCDEF, elapsed: 91.5, state: state,
                            updatedAt: .now, isComplete: false)
    }

    @Test("A snapshot survives a JSON round trip unchanged")
    func snapshotRoundTrip() throws {
        let original = sampleSnapshot()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(GameSnapshot.self, from: data)

        #expect(restored.id == original.id)
        #expect(restored.seed == original.seed)
        #expect(restored.columns == original.columns && restored.rows == original.rows)
        #expect(abs(restored.elapsed - original.elapsed) < 0.001)
        #expect(restored.state == original.state)
        #expect(restored.state.group(of: 1)?.members.sorted() == [0, 1])
        #expect(restored.source == original.source)
    }

    @Test("Saving, loading and deleting games")
    func saveStoreLifecycle() throws {
        let store = SaveStore(directory: try temporaryDirectory())
        #expect(store.load().isEmpty)

        try store.save(sampleSnapshot(id: "a"))
        try store.save(sampleSnapshot(id: "b"))
        #expect(store.load().count == 2)

        // Saving the same id replaces rather than duplicates.
        try store.save(sampleSnapshot(id: "a"))
        #expect(store.load().count == 2)
        #expect(store.load().first?.id == "a", "most recent first")

        try store.delete(id: "a")
        #expect(store.load().map(\.id) == ["b"])

        try store.deleteAll()
        #expect(store.load().isEmpty)
    }

    @Test("The archive is capped so it cannot grow without bound")
    func saveStoreRespectsLimit() throws {
        let store = SaveStore(directory: try temporaryDirectory())
        for index in 0..<10 {
            try store.save(sampleSnapshot(id: "game-\(index)"), limit: 4)
        }
        #expect(store.load().count == 4)
        #expect(store.load().first?.id == "game-9")
    }

    @Test("A corrupt file degrades to an empty list instead of crashing")
    func corruptArchiveIsIgnored() throws {
        let directory = try temporaryDirectory()
        try Data("not json at all".utf8).write(to: directory.appending(path: "savedGames.json"))
        let store = SaveStore(directory: directory)
        #expect(store.load().isEmpty)
    }

    @Test("A save this build cannot read drops only that game")
    func unreadableGameIsSkipped() throws {
        let directory = try temporaryDirectory()
        let store = SaveStore(directory: directory)
        try store.save(sampleSnapshot(id: "old"))
        try store.save(sampleSnapshot(id: "new"))

        // Rewrite one entry with the source the retired artwork generators used.
        let url = directory.appending(path: "savedGames.json")
        var archive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var games = try #require(archive["games"] as? [[String: Any]])
        let index = try #require(games.firstIndex { $0["id"] as? String == "old" })
        games[index]["source"] = ["generated": ["family": 0, "seed": 12]]
        archive["games"] = games
        try JSONSerialization.data(withJSONObject: archive).write(to: url)

        #expect(store.load().map(\.id) == ["new"])
    }

    @Test("Geometry regenerates identically from a restored seed")
    func geometryRebuildsFromSnapshot() throws {
        let snapshot = sampleSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(GameSnapshot.self, from: data)

        let original = PuzzleGeometry(columns: snapshot.columns, rows: snapshot.rows,
                                      aspect: 1.5, seed: snapshot.seed)
        let rebuilt = PuzzleGeometry(columns: restored.columns, rows: restored.rows,
                                     aspect: 1.5, seed: restored.seed)
        for piece in 0..<original.pieceCount {
            #expect(original.outline(of: piece)[1].sampled() == rebuilt.outline(of: piece)[1].sampled())
        }
    }

    @Test("Library items round trip, including their source")
    func libraryItemRoundTrip() throws {
        let items = [
            LibraryItem(id: "bundled.mountains_Canyon", title: "Canyon", category: .mountains,
                        source: .bundled(fileName: "mountains_Canyon.jpg"),
                        addedAt: .distantPast, aspect: 1.5),
            LibraryItem(id: "user.abc.jpg", title: "Holiday", category: .mine,
                        source: .imported(fileName: "abc.jpg"), addedAt: .now, aspect: 0.75)
        ]
        let data = try JSONEncoder().encode(items)
        let restored = try JSONDecoder().decode([LibraryItem].self, from: data)
        #expect(restored == items)
        #expect(restored[1].isUserPhoto)
        #expect(!restored[0].isUserPhoto)
    }

    @Test("The built-in catalogue is the bundled photos, every picture unique")
    func catalogueIsCuratedAndUnique() {
        let items = LibraryCatalog.builtIn()
        #expect(items.count == LibraryCatalog.bundled().count)
        #expect(items.count == LibraryCatalog.count)
        #expect(Set(items.map(\.id)).count == items.count)
        // Every category is represented.
        for category in ArtCategory.allCases where category != .mine {
            #expect(items.contains { $0.category == category }, "no pictures for \(category)")
        }
    }

    @Test("The player's name is capped, trimmed and falls back to a placeholder")
    func playerName() throws {
        let suite = "JigsawTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.displayName == String(localized: "Player"))
        settings.playerName = "   "
        #expect(settings.displayName == String(localized: "Player"))
        settings.playerName = String(repeating: "Ж", count: 40)
        #expect(settings.playerName.count == 24)
        settings.playerName = " Маша "
        #expect(settings.displayName == "Маша")
        #expect(AppSettings(defaults: defaults).playerName == " Маша ")
    }

    @Test("Shared games: newest copy wins, tombstones drop older copies, finished games become tombstones")
    func sharedGamesMerge() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func game(_ id: String, at seconds: Double, complete: Bool = false, photo: Bool = false) -> GameSnapshot {
            var snapshot = sampleSnapshot(id: id)
            snapshot.updatedAt = t0.addingTimeInterval(seconds)
            snapshot.isComplete = complete
            if photo { snapshot.source = .imported(fileName: "mine.jpg") }
            return snapshot
        }
        let ipad = SharedGames(local: [game("a", at: 10), game("b", at: 5), game("done", at: 20, complete: true),
                                       game("photo", at: 1, photo: true)])
        #expect(ipad.games.map(\.id) == ["a", "b"])
        #expect(ipad.gone["done"] == t0.addingTimeInterval(20))

        let phone = SharedGames(local: [game("a", at: 30), game("b", at: 2), game("done", at: 15)],
                                gone: ["b": t0.addingTimeInterval(4)])
        let merged = ipad.merged(with: phone, now: t0)
        // "a": the phone's later copy. "b": the iPad played it after the phone deleted it.
        // "done": finished on the iPad after the phone's last save.
        #expect(merged.games.map(\.id) == ["a", "b"])
        #expect(merged.games.first?.updatedAt == t0.addingTimeInterval(30))
        #expect(ipad.merged(with: phone, now: t0).games.count == phone.merged(with: ipad, now: t0).games.count)

        // An 800-piece game, compressed as iCloud stores it, leaves room for a dozen.
        var state = PuzzleState(columns: 40, rows: 20, cellSize: CGSize(width: 50, height: 50))
        var rng = SplitMix64(seed: 9)
        state.shuffleTray(using: &rng)
        for piece in 0..<Int32(600) { _ = state.placeFromTray(piece, translation: CGPoint(x: Double(piece) * 1.37, y: 41.3)) }
        var big = game("big", at: 0)
        big.state = state
        let data = try JSONEncoder().encode(SharedGames(games: [big]))
        let packed = try (data as NSData).compressed(using: .lzfse) as Data
        #expect(packed.count < 45_000, "800-piece save packs to \(packed.count) bytes")
    }
}

@Suite("Photo library", .serialized)
@MainActor
struct PhotoLibraryTests {

    private func sampleJPEG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext.bitmap(size: CGSize(width: width, height: height)))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = RenderedImage(cgImage: try #require(context.makeImage()))
        let url = URL.temporaryDirectory.appending(path: "sample-\(UUID().uuidString).jpg")
        try ImagePipeline.write(image, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    /// Exercises the real import path end to end — decode, copy into the
    /// container, index, reload from disk, then delete — so the "Add Photo"
    /// button cannot silently be a no-op.
    @Test("Importing a photo stores it, indexes it and survives a reload")
    func importPersistsAndDeletes() throws {
        let store = PhotoLibraryStore()
        let before = store.userItems.count

        let item = try #require(store.importPhoto(data: try sampleJPEG(width: 640, height: 480),
                                                  suggestedTitle: "Unit Test Photo"))
        defer { store.delete(item) }

        #expect(store.userItems.count == before + 1)
        #expect(item.isUserPhoto)
        #expect(abs(item.aspect - 4.0 / 3.0) < 0.02)

        guard case let .imported(fileName) = item.source else {
            Issue.record("imported photos must reference a file")
            return
        }
        let url = try #require(PhotoLibraryStore.photoURL(fileName: fileName))
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        // A fresh store reads the manifest back from disk.
        let reloaded = PhotoLibraryStore()
        #expect(reloaded.userItems.contains { $0.id == item.id })
        #expect(reloaded.items(in: .mine).contains { $0.id == item.id })

        store.rename(item, to: "Renamed")
        #expect(PhotoLibraryStore().userItems.first { $0.id == item.id }?.title == "Renamed")
    }

    @Test("Deleting a photo removes both the index entry and the file")
    func deleteRemovesFile() throws {
        let store = PhotoLibraryStore()
        let item = try #require(store.importPhoto(data: try sampleJPEG(width: 300, height: 300),
                                                  suggestedTitle: nil))
        guard case let .imported(fileName) = item.source else { return }

        store.delete(item)
        #expect(!store.userItems.contains { $0.id == item.id })
        #expect(PhotoLibraryStore.photoURL(fileName: fileName) == nil)
        #expect(!PhotoLibraryStore().userItems.contains { $0.id == item.id })
    }

    @Test("Rubbish data is rejected without crashing")
    func rejectsNonImageData() {
        let store = PhotoLibraryStore()
        let before = store.userItems.count
        #expect(store.importPhoto(data: Data(repeating: 0x42, count: 512),
                                  suggestedTitle: nil) == nil)
        #expect(store.userItems.count == before)
        #expect(store.lastError != nil)
    }
}
