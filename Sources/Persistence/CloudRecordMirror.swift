import Foundation
#if os(macOS)
import Security
#endif

/// The solved-game history in iCloud key-value storage, shared by every
/// device signed in to the same Apple Account — iPhone, iPad and Mac alike,
/// since they share one bundle identifier and so one store.
///
/// Key-value storage suits this exactly: a small blob, no schema, no CloudKit
/// console, and the system syncs it even while the app is closed. Its limit
/// is 1 MB for the whole store, shared with saved games and settings; this
/// key takes up to 400 KB, about 2,000 games, and past that the oldest stay local only.
@MainActor
final class CloudRecordMirror: RecordMirror {
    private static let key = "stats.v1"
    private static let byteLimit = 400_000

    var onExternalChange: (() -> Void)?
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
        store.synchronize()
    }

    func load() -> StatsArchive? {
        store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(StatsArchive.self, from: $0) }
    }

    func save(_ archive: StatsArchive) {
        var archive = archive
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(archive) else { return }
        while data.count > Self.byteLimit, !archive.records.isEmpty {
            archive.records.removeFirst(max(1, archive.records.count / 10))
            data = (try? encoder.encode(archive)) ?? Data()
        }
        store.set(data, forKey: Self.key)
    }

    /// Whether this build may use iCloud and Game Center at all. The App Store
    /// and TestFlight builds are signed with both; a Mac build signed ad hoc
    /// (Debug, `install-mac.sh`) carries neither, and key-value storage
    /// without its entitlement only logs errors. Stage runs are kept out so a
    /// `--clear-saves` never wipes the family's history on every device.
    static var isAvailable: Bool {
        #if DEBUG
        if StageSandbox.isActive { return false }
        #endif
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil) != nil
        #else
        return true
        #endif
    }
}

/// Unfinished games in the same key-value store, compressed. Saves are small
/// (geometry regenerates from the seed), but the store holds 1 MB in all, so
/// the oldest games stay local only once the share is full.
@MainActor
final class CloudGamesMirror {
    private static let key = "games.v1"
    private static let byteLimit = 560_000

    var onExternalChange: (() -> Void)?
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            guard keys.contains(Self.key) else { return }
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
    }

    func load() -> SharedGames? {
        guard let packed = store.data(forKey: Self.key),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(SharedGames.self, from: data)
    }

    func save(_ shared: SharedGames) {
        var shared = shared
        while true {
            guard let data = try? JSONEncoder().encode(shared),
                  let packed = try? (data as NSData).compressed(using: .lzfse) as Data else { return }
            if packed.count <= Self.byteLimit || shared.games.isEmpty {
                store.set(packed, forKey: Self.key)
                return
            }
            shared.games.removeLast()
        }
    }
}
