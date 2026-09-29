import Foundation
import Observation
import SwiftUI

/// Application-level state: preferences, library, navigation and the live game.
@Observable
@MainActor
final class AppModel {

    enum Route: Hashable {
        case setup(itemID: String)
        case game
    }

    #if DEBUG
    let settings = StageSandbox.isActive ? AppSettings(defaults: StageSandbox.makeDefaults()) : AppSettings()
    #else
    let settings = AppSettings()
    #endif
    let library = PhotoLibraryStore()
    /// Solved games, merged across the player's devices through iCloud.
    let stats: PlayerStats
    let gameCenter: GameCenter
    /// Shared so the menu bar can drive zoom and fit without reaching into views.
    let boardController = BoardInputController()

    enum Sheet: String, Identifiable {
        case onboarding, settings, profile
        var id: String { rawValue }
    }

    var path: [Route] = []
    /// The one modal over the root. A single stored value, because several
    /// `.sheet` modifiers on one view stop presenting after the first dismissal.
    var sheet: Sheet?
    var showSettings: Bool {
        get { sheet == .settings }
        set { sheet = newValue ? .settings : nil }
    }
    var showProfile: Bool {
        get { sheet == .profile }
        set { sheet = newValue ? .profile : nil }
    }
    /// Record and achievement news for the game that just finished.
    private(set) var lastCompletion: CompletionSummary?
    private(set) var session: GameSession?
    private(set) var savedGames: [GameSnapshot] = []

    @ObservationIgnored private let saveStore = SaveStore()

    init() {
        // iCloud and Game Center come as a pair: both need a build signed by
        // the team, and neither may run in a stage sandbox.
        let signed = CloudRecordMirror.isAvailable
        stats = PlayerStats(mirror: signed ? CloudRecordMirror() : nil)
        gameCenter = GameCenter(isAvailable: signed)
        refreshSaves()
        stats.onExternalChange = { [weak self] in self?.gameCenter.report() }
        gameCenter.start(with: stats)
        if settings.seenAchievements == nil { markAchievementsSeen() }
    }

    /// Unlocked achievements the player has not looked at in the profile —
    /// earned here or on another device.
    var unseenAchievements: [Achievement] {
        let seen = settings.seenAchievements ?? []
        return Achievement.allCases.filter { !seen.contains($0.rawValue) && $0.isUnlocked(in: stats) }
    }

    func markAchievementsSeen() {
        settings.seenAchievements = Set(Achievement.allCases.filter { $0.isUnlocked(in: stats) }.map(\.rawValue))
    }

    var resumable: [GameSnapshot] { savedGames.filter { !$0.isComplete } }

    func refreshSaves() {
        savedGames = saveStore.load()
    }

    // MARK: - Navigation

    func openSetup(for item: LibraryItem) {
        path = [.setup(itemID: item.id)]
    }

    func showLibrary() {
        session?.saveNow()
        session?.textures.cancel()
        session = nil
        path = []
        refreshSaves()
    }

    func start(item: LibraryItem, aspect: PuzzleAspect, pieces: Int) {
        session?.saveNow()
        session?.textures.cancel()
        session = GameSession(item: item, aspect: aspect, targetPieces: pieces)
        attach(session)
        path = [.game]
    }

    func startDaily() {
        start(item: LibraryCatalog.dailyItem(), aspect: .original, pieces: LibraryCatalog.dailyPieces)
    }

    private func attach(_ session: GameSession?) {
        lastCompletion = nil
        session?.onComplete = { [weak self] finished in
            guard let self else { return }
            lastCompletion = stats.record(finished)
            #if DEBUG
            if let forced = DebugStageDriver.forcedAchievements { lastCompletion?.newAchievements = forced }
            #endif
            gameCenter.report()
        }
    }

    func resume(_ snapshot: GameSnapshot) {
        // A user photo may have been deleted since the game was saved.
        if case let .imported(fileName) = snapshot.source,
           PhotoLibraryStore.photoURL(fileName: fileName) == nil {
            delete(snapshot)
            return
        }
        session?.saveNow()
        session?.textures.cancel()
        session = GameSession(snapshot: snapshot)
        attach(session)
        path = [.game]
    }

    func restartCurrent() {
        guard let current = session else { return }
        start(item: current.item, aspect: current.puzzleAspect, pieces: current.targetPieces)
    }

    // MARK: - Saves

    func delete(_ snapshot: GameSnapshot) {
        try? saveStore.delete(id: snapshot.id)
        refreshSaves()
    }

    func deleteAllSaves() {
        try? saveStore.deleteAll()
        refreshSaves()
    }

    // MARK: - Menu commands

    var canPlay: Bool { session != nil }

    func togglePause() {
        guard let session else { return }
        session.phase == .paused ? session.resume() : session.pause()
    }
}
