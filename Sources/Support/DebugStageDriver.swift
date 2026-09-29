#if DEBUG
import SwiftUI

/// Debug-only harness that drives the app into a named state at launch.
///
/// Verifying a game visually needs the app *in a specific situation* — a board
/// mid-solve, a completed puzzle, 800 scattered pieces. Reaching those by
/// scripting taps is slow and brittle; driving the model directly is exact and
/// reproducible. Launch with `--stage <name>` and the app settles there and
/// stays, ready to be photographed.
///
/// Compiled out of release builds entirely.
@MainActor
enum DebugStageDriver {

    static var requestedStage: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--stage") else { return nil }
        return CommandLine.arguments[safe: index + 1]
    }

    /// `--achievements sprinter,space` makes the next completion announce
    /// these, to look at the reveal without earning them.
    static var forcedAchievements: [Achievement]? {
        guard let index = CommandLine.arguments.firstIndex(of: "--achievements"),
              let list = CommandLine.arguments[safe: index + 1] else { return nil }
        return list.split(separator: ",").compactMap { Achievement(rawValue: String($0)) }
    }

    static func run(model: AppModel) async {
        guard let stage = requestedStage else { return }
        // Stats too: otherwise every staged solve adds one, and the tenth
        // language's screenshots show "31 puzzles completed".
        if CommandLine.arguments.contains("--clear-saves") {
            model.deleteAllSaves()
            model.stats.reset()
        }
        #if os(macOS)
        // Mac App Store screenshots are 16:10; 1440×900 pt is one of the
        // accepted sizes at 1× and doubles to 2880×1800 on a Retina screen.
        if let window = NSApp.windows.first(where: \.isVisible) {
            window.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)
        }
        #endif
        await settle(0.6)

        guard let picture = model.library.builtIn.first(where: { $0.id == "bundled.city_Riomaggiore Harbour" })
                ?? model.library.builtIn.first else { return }

        switch stage {
        case "library":
            break

        case "dark":
            model.settings.appearance = .dark

        case "settings":
            model.showSettings = true

        case "profile":
            // Everything earned so far shows as new.
            model.settings.hasSeenOnboarding = true
            model.settings.seenAchievements = []
            await settle(2.5)
            model.showProfile = true

        case "setup":
            model.openSetup(for: picture)

        case "board", "scattered", "snapped", "hint", "completed":
            model.start(item: picture, aspect: .landscape32, pieces: 48)
            await waitForBoard(model)
            if stage == "board" { break }

            model.session?.scatterTray()
            await settle(0.5)
            model.boardController.fitTable()
            await settle(0.4)
            if stage == "scattered" { break }

            if let session = model.session { await assembleSome(session, limit: 22) }
            model.boardController.fitBoard()
            await settle(0.4)
            if stage == "snapped" { break }

            if stage == "hint" {
                model.session?.requestHint()
                await settle(0.3)
                break
            }
            model.session?.debugAddPlayTime(14 * 60 + 37)
            model.session?.solveImmediately()
            await settle(1.2)

        case "huge":
            model.start(item: picture, aspect: .landscape32, pieces: 800)
            await waitForBoard(model, timeout: 90)
            model.session?.scatterTray()
            await settle(0.8)
            model.boardController.fitTable()
            await settle(0.6)

        case "hugeSolved":
            model.start(item: picture, aspect: .landscape32, pieces: 800)
            await waitForBoard(model, timeout: 90)
            if let session = model.session { await assembleSome(session, limit: 500) }
            model.boardController.fitBoard()
            await settle(0.6)

        default:
            break
        }
        #if canImport(UIKit)
        // `simctl` cannot rotate a simulator; `--landscape` rotates the scene
        // once the stage is up, the way a player turns the phone mid-game.
        if CommandLine.arguments.contains("--landscape") || CommandLine.arguments.contains("--landscape-left") {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let orientation: UIInterfaceOrientationMask = CommandLine.arguments.contains("--landscape-left") ? .landscapeLeft : .landscapeRight
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            await settle(1.0)
        }
        #endif
    }

    /// Snaps pieces into place through the real drag path, so what ends up on
    /// screen is produced by the same code a player's mouse would run.
    private static func assembleSome(_ session: GameSession, limit: Int) async {
        for _ in 0..<limit {
            guard let group = session.state.groups.values.first(where: { !$0.isHome }),
                  let piece = group.members.first else { break }
            let centre = session.state.solvedOrigin(of: piece)
                + CGPoint(x: session.geometry.cellSize.width / 2,
                          y: session.geometry.cellSize.height / 2)
            guard session.beginDrag(at: centre + group.translation) else { break }
            session.updateDrag(to: centre)
            _ = session.endDrag(viewScale: session.viewport.scale, assist: .generous)
        }
        await settle(0.3)
    }

    private static func waitForBoard(_ model: AppModel, timeout: TimeInterval = 40) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let session = model.session, session.isLoaded, session.textures.isReady { break }
            await settle(0.2)
        }
        await settle(0.7)
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// A stage run is a photo shoot, not a game. It keeps its saves, photos and
/// statistics in a scratch directory and its settings in a separate defaults
/// domain, so `--clear-saves` or the `dark` stage never reach the player's own
/// data — on the Mac the debug build shares the real app's container, and a
/// screenshot session used to wipe its saved games.
nonisolated enum StageSandbox {
    static let isActive = ProcessInfo.processInfo.arguments.contains("--stage")

    static let directory: URL = {
        let url = URL.temporaryDirectory.appending(path: "JigsawPuzzle-stage", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Fresh every launch, seeded from the command line (`-appearance light`,
    /// `-onboarding YES`), so one stage's settings never leak into the next.
    static func makeDefaults() -> UserDefaults {
        let name = "JigsawPuzzle.stage"
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        suite.register(defaults: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
        return suite
    }
}
#endif
