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
/// is 1 MB; about 5,000 games fit, and past that the oldest stay local only.
@MainActor
final class CloudRecordMirror: RecordMirror {
    private static let key = "stats.v1"
    private static let byteLimit = 1_000_000 - 16_384

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
