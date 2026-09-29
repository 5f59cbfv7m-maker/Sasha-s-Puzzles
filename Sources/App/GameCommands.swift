import SwiftUI

/// Menu bar commands. On macOS these are the primary way to reach every action
/// with the keyboard; on iOS they surface through hardware-keyboard shortcuts.
struct GameCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Puzzle…") { model.showLibrary() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Back to Library") { model.showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.path.isEmpty)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.session?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.session?.canUndo != true)
            Button("Redo") { model.session?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.session?.canRedo != true)
        }

        CommandMenu("Game") {
            Button(model.session?.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!model.canPlay)
            Button("Hint") { model.session?.requestHint() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!model.canPlay)
            Button { model.session?.performTrayAction() } label: {
                model.session?.trayAction == .gather ? Text("Gather Pieces") : Text("Scatter Pieces")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model.session?.trayAction == nil)
            Divider()
            Button("Restart This Puzzle") { model.restartCurrent() }
                .disabled(!model.canPlay)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { model.boardController.zoomStep(1.25) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.canPlay)
            Button("Zoom Out") { model.boardController.zoomStep(0.8) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canPlay)
            Button("Fit Board") { model.boardController.fitBoard() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!model.canPlay)
            Button("Fit Table") { model.boardController.fitTable() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(!model.canPlay)
        }
    }
}
