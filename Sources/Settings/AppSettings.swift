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

    /// A tune for the library or the board. The raw values of the first
    /// three are the 1.2 settings' (`boardMusic` was piano or vibraphone).
    enum Melody: String, CaseIterable, Identifiable, Sendable {
        case library, piano, vibraphone
        case stillLake, morningMist, starlight
        case gardenWalk, sunnyWindow, littleWaltz

        var id: String { rawValue }

        var title: String {
            switch self {
            case .library: String(localized: "Library tune")
            case .piano: String(localized: "Piano")
            case .vibraphone: String(localized: "Vibraphone")
            case .stillLake: String(localized: "Still Lake")
            case .morningMist: String(localized: "Morning Mist")
            case .starlight: String(localized: "Starlight")
            case .gardenWalk: String(localized: "Garden Walk")
            case .sunnyWindow: String(localized: "Sunny Window")
            case .littleWaltz: String(localized: "Little Waltz")
            }
        }

        var style: Style {
            switch self {
            case .library, .piano, .vibraphone: .classic
            case .stillLake, .morningMist, .starlight: .meditative
            case .gardenWalk, .sunnyWindow, .littleWaltz: .melodic
            }
        }

        var track: Feedback.Music {
            switch self {
            case .library: .library
            case .piano: .boardPiano
            case .vibraphone: .board
            case .stillLake: .calm1
            case .morningMist: .calm2
            case .starlight: .calm3
            case .gardenWalk: .tune1
            case .sunnyWindow: .tune2
            case .littleWaltz: .tune3
            }
        }

        /// Tunes of one style: a mix moves from one to the next without a change of mood.
        enum Style: CaseIterable, Identifiable {
            case classic, meditative, melodic
            var id: Self { self }
            var title: String {
                switch self {
                case .classic: String(localized: "Classic")
                case .meditative: String(localized: "Meditative")
                case .melodic: String(localized: "Melodic")
                }
            }
            var melodies: [Melody] { Melody.allCases.filter { $0.style == self } }
        }
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
    var boardMusic: Melody { didSet { write(boardMusic.rawValue, "boardMusic") } }
    var libraryMusic: Melody { didSet { write(libraryMusic.rawValue, "libraryMusic") } }
    /// The tunes take turns, staying in the chosen tune's style.
    var musicMix: Bool { didSet { write(musicMix, "musicMix") } }
    /// The host's choice for a shared table: no hints for anyone at it.
    var tableNoHints: Bool { didSet { write(tableNoHints, "tableNoHints") } }
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
    /// A phone's small pieces under a fingertip snap more readily.
    private static var defaultSnap: SnapAssist {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? .generous : .standard
        #else
        .standard
        #endif
    }

    static let syncedKeys = ["appearance", "sound", "music", "boardMusic", "libraryMusic", "musicMix", "tableNoHints",
                             "haptics", "ghost", "snapAssist",
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
        libraryMusic = .library; musicMix = false; tableNoHints = false
        hapticsEnabled = true; showGhostImage = true; snapAssist = Self.defaultSnap; defaultDifficulty = .normal
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
        boardMusic = Melody(rawValue: defaults.string(forKey: "boardMusic") ?? "") ?? .piano
        libraryMusic = Melody(rawValue: defaults.string(forKey: "libraryMusic") ?? "") ?? .library
        musicMix = defaults.bool(forKey: "musicMix")
        tableNoHints = defaults.bool(forKey: "tableNoHints")
        hapticsEnabled = defaults.object(forKey: "haptics") as? Bool ?? true
        showGhostImage = defaults.object(forKey: "ghost") as? Bool ?? true
        snapAssist = SnapAssist(rawValue: defaults.string(forKey: "snapAssist") ?? "") ?? Self.defaultSnap
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
