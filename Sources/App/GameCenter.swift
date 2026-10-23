import GameKit
import SwiftUI

/// Game Center: leaderboards to compare with friends, and the achievement
/// wall mirrored where friends can see it. Everything here is best effort —
/// the game never waits for it and plays the same without an account.
///
/// The identifiers must match App Store Connect → Game Center exactly, and a
/// leaderboard or achievement that has shipped in any version can never be
/// deleted there. Add new ones; never rename these.
@Observable
@MainActor
final class GameCenter {

    enum Board: String, CaseIterable, Identifiable {
        /// Total puzzles solved; higher is better.
        case puzzlesSolved = "puzzles_solved"
        /// Today's daily puzzle, in seconds; a recurring board that restarts
        /// every day, lower is better.
        case dailyTime = "daily_time"
        /// Longest run of daily puzzles on consecutive days; higher is better.
        case dailyStreak = "daily_streak"
        /// Points from every solved puzzle; higher is better.
        case points = "points_total"
        /// Points earned this week; a recurring board that restarts every
        /// Monday at 00:00 UTC (`PlayerStats.leaderboardWeekStart`).
        case pointsWeek = "points_week"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .puzzlesSolved: String(localized: "Puzzles solved")
            case .dailyTime: String(localized: "Daily puzzle — best time")
            case .dailyStreak: String(localized: "Longest daily streak")
            case .points: String(localized: "Points")
            case .pointsWeek: String(localized: "Points this week")
            }
        }

        var symbol: String {
            switch self {
            case .puzzlesSolved: "puzzlepiece.fill"
            case .dailyTime: "stopwatch.fill"
            case .dailyStreak: "flame.fill"
            case .points: "star.fill"
            case .pointsWeek: "calendar"
            }
        }
    }

    /// Whether this build is signed for Game Center at all.
    let isAvailable: Bool
    private(set) var isSignedIn = false
    /// Game Center's own sign-in screen. Kept until the player asks for it
    /// rather than thrown over onboarding the moment the app starts.
    private(set) var needsSignIn = false
    @ObservationIgnored private var signIn: PlatformViewController?
    @ObservationIgnored private weak var stats: PlayerStats?
    /// What to open when the player picks one of the game's activities in
    /// the Games app or on a challenge notification.
    @ObservationIgnored var onActivity: (Activity) -> Void = { _ in }
    @ObservationIgnored private var listener: AnyObject?

    /// Activity identifiers, as set up in App Store Connect → Game Center.
    enum Activity: String {
        case dailyPuzzle = "daily_puzzle"
        case quickPuzzle = "quick_puzzle"
    }

    /// `previewSignedIn` shows the friends section as a signed-in player sees
    /// it, for the profile stage's store screenshot; nothing reaches Game Center.
    init(isAvailable: Bool, previewSignedIn: Bool = false) {
        self.isAvailable = isAvailable
        isSignedIn = previewSignedIn
    }

    func start(with stats: PlayerStats) {
        guard isAvailable else { return }
        self.stats = stats
        GKAccessPoint.shared.isActive = false
        GKLocalPlayer.local.authenticateHandler = { [weak self] controller, _ in
            nonisolated(unsafe) let controller = controller
            Task { @MainActor in self?.authenticated(controller) }
        }
    }

    private func authenticated(_ controller: PlatformViewController?) {
        signIn = controller
        needsSignIn = controller != nil
        isSignedIn = GKLocalPlayer.local.isAuthenticated
        if isSignedIn { listen() }
        report()
    }

    /// Registers once for activities. Registering a second listener is
    /// undefined behaviour, so authentication callbacks after the first
    /// leave it alone.
    private func listen() {
        guard listener == nil, #available(iOS 26, macOS 26, *) else { return }
        let listener = ActivityListener { [weak self] id in
            guard let activity = Activity(rawValue: id) else { return false }
            self?.onActivity(activity)
            return true
        }
        GKLocalPlayer.local.register(listener)
        self.listener = listener
    }

    // MARK: - Reporting

    /// Sends the all-time totals and every achievement's progress. Game
    /// Center keeps the best score and the highest progress, so sending
    /// everything each time is both simple and idempotent — and it backfills
    /// whatever was solved before Game Center existed here.
    ///
    /// `finished` is the game that just ended, if any. Only then go the
    /// boards that challenges are built on (`daily_time`, `points_week`):
    /// every score sent there uses up an attempt of a running challenge, so
    /// a launch or a sync must never send one.
    func report(finished: SolvedRecord? = nil) {
        guard isSignedIn, let stats else { return }
        var scores: [(Board, Int)] = [(.puzzlesSolved, stats.puzzlesSolved), (.points, stats.points)]
        if stats.longestStreak > 0 { scores.append((.dailyStreak, stats.longestStreak)) }
        if let finished {
            scores.append((.pointsWeek, stats.points(since: PlayerStats.leaderboardWeekStart())))
            // This attempt's own time, not today's best: a challenge counts
            // every attempt, and Game Center keeps the best one anyway.
            if stats.isDaily(finished) { scores.append((.dailyTime, max(1, Int(finished.elapsed.rounded())))) }
        }
        let progress: [(id: String, percent: Double)] = Achievement.allCases.compactMap { achievement in
            // Whole percent: Game Center wants an integer value.
            let percent = (achievement.progress(in: stats).fraction * 100).rounded(.down)
            // Partial progress would reveal a hidden achievement early.
            guard percent > 0, percent == 100 || !achievement.isHidden else { return nil }
            return (achievement.gameCenterID, percent)
        }

        Task {
            for (board, score) in scores where score > 0 {
                try? await GKLeaderboard.submitScore(score, context: 0, player: GKLocalPlayer.local,
                                                     leaderboardIDs: [board.rawValue])
            }
            let achievements = progress.map { item in
                let achievement = GKAchievement(identifier: item.id)
                achievement.percentComplete = item.percent
                // The completion card already celebrates it.
                achievement.showsCompletionBanner = false
                return achievement
            }
            if !achievements.isEmpty { try? await GKAchievement.report(achievements) }
        }
    }

    // MARK: - Showing

    /// Presents Game Center's sign-in screen, kept from launch.
    func presentSignIn() {
        guard let signIn else { return }
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(signIn, animated: true)
        #else
        NSApp.keyWindow?.contentViewController?.presentAsSheet(signIn)
        #endif
    }

    /// Opens a leaderboard filtered to friends. Game Center presents from the
    /// main window, so the caller dismisses its own sheet first.
    func show(_ board: Board) {
        GKAccessPoint.shared.trigger(leaderboardID: board.rawValue, playerScope: .friendsOnly,
                                     timeScope: .allTime) {}
    }

    func showDashboard() {
        GKAccessPoint.shared.trigger(state: .dashboard) {}
    }
}

/// Hands the activity a player picked in the Games app to `GameCenter`.
@available(iOS 26, macOS 26, *)
private final class ActivityListener: NSObject, GKLocalPlayerListener {
    private let open: @MainActor (String) -> Bool

    init(open: @escaping @MainActor (String) -> Bool) {
        self.open = open
    }

    nonisolated func player(_ player: GKPlayer, wantsToPlay activity: GKGameActivity,
                            completionHandler: @escaping (Bool) -> Void) {
        let id = activity.activityDefinition.identifier
        nonisolated(unsafe) let completionHandler = completionHandler
        Task { @MainActor in completionHandler(open(id)) }
    }
}

#if os(iOS)
typealias PlatformViewController = UIViewController
#else
typealias PlatformViewController = NSViewController
#endif

extension Achievement {
    /// Identifier of the matching Game Center achievement.
    nonisolated var gameCenterID: String { "achievement.\(rawValue)" }
}
