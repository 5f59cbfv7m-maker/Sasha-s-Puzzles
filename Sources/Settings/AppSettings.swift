import Foundation
import Observation
import SwiftUI

/// User preferences, mirrored into `UserDefaults` on every change.
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        hasSeenOnboarding = defaults.bool(forKey: "onboarding")
        seenAchievements = (defaults.array(forKey: "seenAchievements") as? [String]).map(Set.init)
        playerName = defaults.string(forKey: "playerName") ?? ""
    }

    private func write(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
