import SwiftUI

@main
struct JigsawPuzzleApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() { Fonts.register() }

    var body: some Scene {
        #if os(macOS)
        // One `Window`, not a `WindowGroup`: the app has a single shared model,
        // so a second window (File ▸ New, or the tab bar's "+") made no sense,
        // and a `Window` scene is listed in the Window menu so it can always be
        // reopened. Closing it quits the app — see `AppDelegate`.
        Window("Sasha's Puzzles", id: "main") {
            root
                // A minimum size is a *window* constraint, so it lives on the
                // Mac scene only. Applying it on iOS forces the layout wider
                // than a phone screen, pushing the HUD and the toolbar off
                // both edges.
                .frame(minWidth: 620, minHeight: 460)
                .onAppear { appDelegate.model = model }
        }
        .commands { GameCommands(model: model) }
        .defaultSize(width: 1320, height: 880)

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
        }
        #else
        WindowGroup {
            root
        }
        .commands { GameCommands(model: model) }
        #endif
    }

    private var root: some View {
        RootView()
            .environment(model)
            .environment(model.settings)
    }
}
