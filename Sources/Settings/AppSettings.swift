import Foundation
import Observation
import SwiftUI

/// User preferences, mirrored into `UserDefaults` — and iCloud, when signed for it — on every change.
@Observable
final class AppSettings {

    enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: String(localized: "System")
            case .light: String(localized: "Light")
            case .dark: String(localized: "Dark")
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// The tune under the board; the library always plays its own.
    enum BoardMusic: String, CaseIterable, Identifiable, Sendable {
        case piano, vibraphone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .piano: String(localized: "Piano")
            case .vibraphone: String(localized: "Vibraphone")
            }
        }
        var track: Feedback.Music { self == .piano ? .boardPiano : .board }
    }

    /// What the board lies on. A trial: the user wants to see each live.
    enum TableSurface: String, CaseIterable, Identifiable, Sendable {
        case plain, wood, linen, felt
        var id: String { rawValue }
        var title: String {
            switch self {
            case .plain: String(localized: "Plain")
            case .wood: String(localized: "Wood")
            case .linen: String(localized: "Linen")
            case .felt: String(localized: "Felt")
            }
        }
    }

    var appearance: Appearance { didSet { write(appearance.rawValue, "appearance") } }
    var soundEnabled: Bool { didSet { write(soundEnabled, "sound") } }
    var musicEnabled: Bool { didSet { write(musicEnabled, "music") } }
    var boardMusic: BoardMusic { didSet { write(boardMusic.rawValue, "boardMusic") } }
    var hapticsEnabled: Bool { didSet { write(hapticsEnabled, "haptics") } }
    /// Faint copy of the picture under the board — a guide, not a solution.
    var showGhostImage: Bool { didSet { write(showGhostImage, "ghost") } }
    var snapAssist: SnapAssist { didSet { write(snapAssist.rawValue, "snapAssist") } }
    var defaultDifficulty: Difficulty { didSet { write(defaultDifficulty.rawValue, "difficulty") } }
    var defaultAspect: PuzzleAspect { didSet { write(defaultAspect.rawValue, "aspect") } }
    /// Draw a thin outline around every piece; helps on busy pictures.
    var showPieceOutlines: Bool { didSet { write(showPieceOutlines, "outlines") } }
    /// Faint grain and a matte finish on the pieces, like printed cardboard.
    var cardboardPieces: Bool { didSet { write(cardboardPieces, "cardboard") } }
    var table: TableSurface { didSet { write(table.rawValue, "table") } }
    var hasSeenOnboarding: Bool { didSet { write(hasSeenOnboarding, "onboarding") } }
    /// Achievements already looked at in the profile. `nil` until the first
    /// launch that knows about them, so an update does not flag old ones as new.
    var seenAchievements: Set<String>? { didSet { write(Array(seenAchievements ?? []), "seenAchievements") } }
    /// Asked on the last onboarding step, editable in the profile. Capped so a
    /// pasted paragraph cannot push the profile header off screen.
    var playerName: String {
        didSet {
            if playerName.count > 24 { playerName = String(playerName.prefix(24)) }
            write(playerName, "playerName")
        }
    }
    var displayName: String {
        let name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Player") : name
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// iCloud key-value storage in team-signed builds: the name and every
    /// preference follow the player to their other devices and survive a
    /// reinstall. `nil` in stage runs and ad-hoc builds.
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Keys that sync. Onboarding stays per device.
    static let syncedKeys = ["appearance", "sound", "music", "boardMusic", "haptics", "ghost", "snapAssist",
                             "difficulty", "aspect", "outlines", "cardboard", "table", "playerName",
                             "seenAchievements"]
    private static func cloudKey(_ key: String) -> String { "settings." + key }

    /// Copies the cloud's value in. Seen achievements are a union, so a device
    /// that has not earned a medal yet cannot flag it as new again elsewhere.
    private static func take(_ key: String, from cloud: NSUbiquitousKeyValueStore, into defaults: UserDefaults) {
        var value = cloud.object(forKey: cloudKey(key))
        if key == "seenAchievements", let theirs = value as? [String] {
            let union = Set(theirs).union(defaults.stringArray(forKey: key) ?? [])
            value = union.sorted()
            if union.count > Set(theirs).count { cloud.set(value, forKey: cloudKey(key)) }
        }
        defaults.set(value, forKey: key)
    }

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore? = nil) {
        self.defaults = defaults
        self.cloud = cloud
        // Cloud first where it has a value; what only this device knows goes up.
        if let cloud {
            for key in Self.syncedKeys {
                if cloud.object(forKey: Self.cloudKey(key)) != nil {
                    Self.take(key, from: cloud, into: defaults)
                } else if let value = defaults.object(forKey: key) {
                    cloud.set(value, forKey: Self.cloudKey(key))
                }
            }
        }
        appearance = .system; soundEnabled = true; musicEnabled = true; boardMusic = .piano
        hapticsEnabled = true; showGhostImage = true; snapAssist = .standard; defaultDifficulty = .normal
        defaultAspect = .original; showPieceOutlines = true; cardboardPieces = false; table = .plain
        hasSeenOnboarding = false; playerName = ""
        reload()
        guard let cloud else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.applyCloud(keys) }
        }
    }

    /// Takes in what another device changed.
    func applyCloud(_ changed: [String]) {
        guard let cloud else { return }
        let keys = Self.syncedKeys.filter { changed.contains(Self.cloudKey($0)) }
        guard !keys.isEmpty else { return }
        for key in keys { Self.take(key, from: cloud, into: defaults) }
        reload()
    }

    /// Set while properties are refilled from storage, so reading never writes:
    /// a fresh install must not push its defaults over the family's settings.
    @ObservationIgnored private var isLoading = false

    private func reload() {
        isLoading = true
        defer { isLoading = false }
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        soundEnabled = defaults.object(forKey: "sound") as? Bool ?? true
        musicEnabled = defaults.object(forKey: "music") as? Bool ?? true
        boardMusic = BoardMusic(rawValue: defaults.string(forKey: "boardMusic") ?? "") ?? .piano
        hapticsEnabled = defaults.object(forKey: "haptics") as? Bool ?? true
        showGhostImage = defaults.object(forKey: "ghost") as? Bool ?? true
        snapAssist = SnapAssist(rawValue: defaults.string(forKey: "snapAssist") ?? "") ?? .standard
        defaultDifficulty = Difficulty(rawValue: defaults.string(forKey: "difficulty") ?? "") ?? .normal
        defaultAspect = PuzzleAspect(rawValue: defaults.string(forKey: "aspect") ?? "") ?? .original
        showPieceOutlines = defaults.object(forKey: "outlines") as? Bool ?? true
        cardboardPieces = defaults.bool(forKey: "cardboard")
        table = TableSurface(rawValue: defaults.string(forKey: "table") ?? "") ?? .plain
        hasSeenOnboarding = defaults.bool(forKey: "onboarding")
        playerName = defaults.string(forKey: "playerName") ?? ""
        seenAchievements = (defaults.array(forKey: "seenAchievements") as? [String]).map(Set.init)
    }

    private func write(_ value: Any, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        if Self.syncedKeys.contains(key) { cloud?.set(value, forKey: Self.cloudKey(key)) }
    }
}
