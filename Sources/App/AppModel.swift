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
    let settings = StageSandbox.isActive ? AppSettings(defaults: StageSandbox.makeDefaults())
        : AppSettings(cloud: CloudRecordMirror.isAvailable ? .default : nil)
    #else
    let settings = AppSettings(cloud: CloudRecordMirror.isAvailable ? .default : nil)
    #endif
    let library = PhotoLibraryStore()
    /// Solved games, merged across the player's devices through iCloud.
    let stats: PlayerStats
    let gameCenter: GameCenter
    /// Shared so the menu bar can drive zoom and fit without reaching into views.
    let boardController = BoardInputController()

    enum Sheet: String, Identifiable {
        case onboarding, settings, profile, together
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
    /// The board shared with other players, while there is one.
    private(set) var table: SharedTable?
    /// Looks for tables nearby while the library's "Play together" is open.
    private(set) var nearby: NearbyLink?

    @ObservationIgnored private let saveStore = SaveStore()
    /// Unfinished games shared with the player's other devices.
    @ObservationIgnored private let sharedGames: CloudGamesMirror?

    init() {
        // iCloud and Game Center come as a pair: both need a build signed by
        // the team, and neither may run in a stage sandbox.
        let signed = CloudRecordMirror.isAvailable
        stats = PlayerStats(mirror: signed ? CloudRecordMirror() : nil)
        #if DEBUG
        gameCenter = GameCenter(isAvailable: signed, previewSignedIn: DebugStageDriver.requestedStage == "profile")
        #else
        gameCenter = GameCenter(isAvailable: signed)
        #endif
        sharedGames = signed ? CloudGamesMirror() : nil
        refreshSaves()
        sharedGames?.onExternalChange = { [weak self] in self?.refreshSaves() }
        stats.onExternalChange = { [weak self] in self?.gameCenter.report() }
        gameCenter.onActivity = { [weak self] activity in self?.open(activity) }
        gameCenter.onMatch = { [weak self] match in self?.join(MatchLink(match)) }
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
        // A union: marks seen on another device stay, even for medals this one has not synced yet.
        settings.seenAchievements = (settings.seenAchievements ?? [])
            .union(Achievement.allCases.filter { $0.isUnlocked(in: stats) }.map(\.rawValue))
    }

    var resumable: [GameSnapshot] { savedGames.filter { !$0.isComplete } }

    /// Reloads saves after trading with iCloud: newer copies from other
    /// devices come in, games finished or deleted elsewhere go, and what this
    /// device has goes up. `gone` adds tombstones for games deleted here.
    func refreshSaves(gone: [String: Date] = [:]) {
        if let sharedGames {
            let local = saveStore.load()
            let merged = SharedGames(local: local, gone: gone).merged(with: sharedGames.load() ?? SharedGames())
            for game in merged.games.reversed()
            where local.first(where: { $0.id == game.id }).map({ $0.updatedAt < game.updatedAt }) ?? true {
                try? saveStore.save(game)
            }
            for game in local where !game.isComplete && game.id != session?.id {
                if let at = merged.gone[game.id], at >= game.updatedAt { try? saveStore.delete(id: game.id) }
            }
            sharedGames.save(merged)
        }
        savedGames = saveStore.load()
    }

    // MARK: - Navigation

    func openSetup(for item: LibraryItem) {
        guard !isLocked(item, unlocks) else { return }
        path = [.setup(itemID: item.id)]
    }

    /// What the player has earned, computed once for a whole screen of cards.
    struct Unlocks { var points: Int; var gifts: Int }
    var unlocks: Unlocks { Unlocks(points: stats.points, gifts: stats.giftsEarned) }

    /// A reward picture the player has not reached yet. Today's daily puzzle
    /// is open to everyone: it is the same picture worldwide, for the daily
    /// leaderboard, and a taste of what the points open for good.
    func isLocked(_ item: LibraryItem, _ unlocks: Unlocks) -> Bool {
        if let index = LibraryCatalog.secretOrder.firstIndex(of: item.id) { return index >= unlocks.gifts }
        guard let need = LibraryCatalog.requiredPoints(for: item.id) else { return false }
        return unlocks.points < need && item.id != LibraryCatalog.dailyItem().id
    }

    func showLibrary() {
        leaveTable()
        session?.saveNow()
        session?.textures.cancel()
        session = nil
        path = []
        refreshSaves()
    }

    func start(item: LibraryItem, aspect: PuzzleAspect, pieces: Int) {
        session?.saveNow()
        session?.textures.cancel()
        let next = GameSession(item: item, aspect: aspect, targetPieces: pieces)
        session = next
        attach(next)
        // The host's "Play again" takes everyone at the table along; a guest
        // starting a game of their own leaves it.
        if let table, table.isHost, !item.isUserPhoto { table.attach(next) } else { leaveTable() }
        path = [.game]
    }

    func startDaily() {
        start(item: LibraryCatalog.dailyItem(), aspect: .original, pieces: LibraryCatalog.dailyPieces)
    }

    /// A short game on a random picture the player has open — the Games
    /// app's "Quick puzzle" activity, sized for the Sprinter achievement.
    func startQuick() {
        let unlocks = unlocks
        let open = LibraryCatalog.builtIn().filter { !isLocked($0, unlocks) }
        guard let item = open.randomElement() else { return }
        start(item: item, aspect: .original, pieces: Self.quickPieces)
    }

    static let quickPieces = 48

    /// Solved or started a puzzle here or, through iCloud, on another device.
    var hasPlayed: Bool { !stats.records.isEmpty || !savedGames.isEmpty }

    /// Onboarding greets a new player only. Its flag is per device and gone
    /// after a reinstall, so a name, a record or a save also mark someone
    /// who has played before.
    func greetIfNew() {
        guard !settings.hasSeenOnboarding else { return }
        if hasPlayed || !settings.playerName.isEmpty {
            settings.hasSeenOnboarding = true
        } else {
            sheet = .onboarding
        }
    }

    /// An activity picked in the Games app or from a challenge notification.
    /// Settings or the profile go away (onboarding stays, the game waits
    /// under it); a game in progress is saved by `start`.
    func open(_ activity: GameCenter.Activity) {
        if sheet != .onboarding { sheet = nil }
        switch activity {
        case .dailyPuzzle: startDaily()
        case .quickPuzzle: startQuick()
        }
    }

    private func attach(_ session: GameSession?) {
        lastCompletion = nil
        session?.onComplete = { [weak self] finished in
            guard let self else { return }
            lastCompletion = stats.record(finished, sharedPieces: table?.ownPieces(in: finished))
            #if DEBUG
            if let forced = DebugStageDriver.forcedAchievements { lastCompletion?.newAchievements = forced }
            #endif
            gameCenter.report(finished: lastCompletion?.solved)
        }
    }

    func resume(_ snapshot: GameSnapshot) {
        // A user photo may have been deleted since the game was saved.
        if case let .imported(fileName) = snapshot.source,
           PhotoLibraryStore.photoURL(fileName: fileName) == nil {
            delete(snapshot)
            return
        }
        leaveTable()
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

    // MARK: - Playing together

    /// Bundled pictures only: a partner's device has those, not this one's photos.
    var canShareTable: Bool { session.map { !$0.item.isUserPhoto } ?? false }

    private func hostTable() -> SharedTable? {
        if let table, table.isHost { return table }
        guard let session, canShareTable else { return nil }
        let table = SharedTable(hosting: session, name: settings.displayName, settings: settings)
        self.table = table
        return table
    }

    /// Lets players in the same room sit down at this game.
    func openTableNearby() {
        guard let table = hostTable(), let session, nearbyHost == nil else { return }
        let link = NearbyLink(name: settings.displayName)
        link.advertise(title: session.item.title, pieces: session.pieceCount)
        table.add(link)
        nearbyHost = link
    }

    /// The table this device has opened to players nearby.
    private(set) var nearbyHost: NearbyLink?

    /// Game Center's friend picker; the friends who accept sit down at this game.
    func inviteFriends() {
        guard canShareTable else { return }
        sheet = nil
        // Game Center presents from the main window, once the sheet is gone.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            gameCenter.inviteFriends { [weak self] match in
                self?.hostTable()?.add(MatchLink(match))
            }
        }
    }

    func browseNearby() {
        guard nearby == nil else { return }
        let link = NearbyLink(name: settings.displayName)
        link.browse()
        nearby = link
    }

    func stopBrowsing() {
        // A table that never answered (full, or gone) is given up with the sheet.
        if let table, !table.isHost, table.session == nil { leaveTable() }
        guard table == nil else { return }
        nearby?.close()
        nearby = nil
    }

    func join(_ found: NearbyLink.Table) {
        guard let nearby else { return }
        nearby.join(found)
        self.nearby = nil
        join(nearby)
    }

    /// Sits down at someone else's table; their game opens once it arrives.
    func join(_ link: TableLink) {
        leaveTable()
        let table = SharedTable(joining: link, name: settings.displayName, settings: settings)
        table.onGame = { [weak self] game in self?.play(game) }
        self.table = table
    }

    /// The host's game, on a guest's device.
    private func play(_ game: GameSession) {
        if session !== game {
            session?.saveNow()
            session?.textures.cancel()
        }
        session = game
        attach(game)
        if sheet == .together { sheet = nil }
        path = [.game]
    }

    func leaveTable() {
        table?.close()
        table = nil
        nearbyHost = nil
        nearby?.close()
        nearby = nil
    }

    // MARK: - Saves

    func delete(_ snapshot: GameSnapshot) {
        try? saveStore.delete(id: snapshot.id)
        refreshSaves(gone: [snapshot.id: .now])
    }

    func deleteAllSaves() {
        let gone = Dictionary(savedGames.map { ($0.id, Date.now) }, uniquingKeysWith: max)
        try? saveStore.deleteAll()
        refreshSaves(gone: gone)
    }

    // MARK: - Menu commands

    var canPlay: Bool { session != nil }

    func togglePause() {
        guard let session else { return }
        session.phase == .paused ? session.resume() : session.pause()
    }
}
