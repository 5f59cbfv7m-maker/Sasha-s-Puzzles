#if os(macOS)
import AppKit

/// Makes the Mac app behave as the single-window app it is: closing the main
/// window saves the game in progress and quits. Without this the app stayed
/// running with no window and no way back to one — App Review rejected 1.0
/// for exactly that (Guideline 4). The `Window` scene in `JigsawPuzzleApp`
/// also lists the window in the Window menu, which covers the case where the
/// Settings window keeps the app alive after the main window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // ⌘Q does not reliably run `GameView.onDisappear`; save here as well.
        model?.session?.saveNow()
    }
}
#endif
