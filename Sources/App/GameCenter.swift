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

        var id: String { rawValue }

        var title: String {
            switch self {
            case .puzzlesSolved: String(localized: "Puzzles solved")
            case .dailyTime: String(localized: "Daily puzzle — best time")
            case .dailyStreak: String(localized: "Longest daily streak")
            }
        }

        var symbol: String {
            switch self {
            case .puzzlesSolved: "puzzlepiece.fill"
            case .dailyTime: "stopwatch.fill"
            case .dailyStreak: "flame.fill"
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

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
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
        report()
    }

    // MARK: - Reporting

    /// Sends the current totals and every unlocked achievement. Game Center
    /// keeps the best score and ignores achievements already earned, so
    /// sending everything each time is both simple and idempotent — and it
    /// backfills whatever was solved before Game Center existed here.
    func report() {
        guard isSignedIn, let stats else { return }
        var scores: [(Board, Int)] = [(.puzzlesSolved, stats.puzzlesSolved)]
        if stats.longestStreak > 0 { scores.append((.dailyStreak, stats.longestStreak)) }
        if let best = stats.dailyBestToday { scores.append((.dailyTime, max(1, Int(best.rounded())))) }
        let unlocked = Achievement.allCases.filter { $0.isUnlocked(in: stats) }.map(\.gameCenterID)

        Task {
            for (board, score) in scores where score > 0 {
                try? await GKLeaderboard.submitScore(score, context: 0, player: GKLocalPlayer.local,
                                                     leaderboardIDs: [board.rawValue])
            }
            let achievements = unlocked.map { id in
                let achievement = GKAchievement(identifier: id)
                achievement.percentComplete = 100
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

#if os(iOS)
typealias PlatformViewController = UIViewController
#else
typealias PlatformViewController = NSViewController
#endif

extension Achievement {
    /// Identifier of the matching Game Center achievement.
    nonisolated var gameCenterID: String { "achievement.\(rawValue)" }
}
