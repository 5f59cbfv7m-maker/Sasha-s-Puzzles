import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true

    /// The library tune while a picture is chosen (set-up included), the board
    /// tune once the game is on screen, silence in the background.
    private var music: Feedback.Music? {
        guard scenePhase == .active else { return nil }
        return model.path.last == .game ? model.settings.boardMusic.track : .library
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            HomeView()
                .navigationDestination(for: AppModel.Route.self) { route in
                    Group {
                        switch route {
                        case let .setup(itemID):
                            if let item = model.library.item(id: itemID) {
                                SetupView(item: item)
                            } else {
                                ContentUnavailableView("Picture not found", systemImage: "photo")
                            }
                        case .game:
                            if let session = model.session {
                                // A fresh view per game: "Play again" keeps the route, and
                                // the old view's state would skip loading the new game.
                                GameView(session: session).id(session.id)
                            } else {
                                ContentUnavailableView("No game in progress", systemImage: "puzzlepiece")
                            }
                        }
                    }
                    .toolbar(.hidden)
                }
                // Every screen draws its own header in the design; the system
                // bar would only duplicate it. The modifier is per screen, so
                // the pushed destinations carry it too.
                .toolbar(.hidden)
        }
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
        .overlay {
            if showSplash {
                SplashView {
                    withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
                    if !model.settings.hasSeenOnboarding { model.sheet = .onboarding }
                }
                .transition(.opacity)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .onboarding:
                    OnboardingView {
                        model.settings.hasSeenOnboarding = true
                        model.sheet = nil
                    }
                    .interactiveDismissDisabled()
                case .settings: SettingsView()
                case .profile: ProfileView()
                }
            }
            // A fixed page, not a content-sized sheet: content that adapts to
            // the size class would otherwise resize the sheet, which changes
            // the size class, which re-lays out the content — forever.
            .presentationSizing(.page)
            // Handed over explicitly: the iPad build running on a Mac hosts
            // the sheet without the presenter's environment, and 1.0 crashed
            // there on the first onboarding frame ("No Observable object").
            .environment(model)
            .environment(model.settings)
        }
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .onChange(of: music, initial: true) { Feedback.shared.setMusic(music, settings: model.settings) }
        // Hands the game in progress to the player's other devices.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.session?.saveNow(); model.refreshSaves() }
        }
        .onChange(of: model.settings.musicEnabled) { Feedback.shared.setMusic(music, settings: model.settings) }
        .environment(model.settings)
        #if os(iOS)
        // Under memory pressure the derived-image caches are the cheapest thing
        // to give back: everything in them can be regenerated or re-decoded.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await ImageStore.shared.purgeMemory() }
        }
        #endif
        #if DEBUG
        .task { await DebugStageDriver.run(model: model) }
        #endif
    }
}

/// First frame: the mark assembles from four pieces with the same geometry as
/// the puzzle, then the name rises under it.
private struct SplashView: View {
    let onFinish: () -> Void
    @State private var assembled = false
    @State private var named = false

    nonisolated private static let geometry = PuzzleGeometry(columns: 2, rows: 2, aspect: 1, seed: 0x5A5A)
    private static let flyIn: [CGSize] = [
        CGSize(width: -90, height: -70), CGSize(width: 96, height: -58),
        CGSize(width: -78, height: 88), CGSize(width: 104, height: 76),
    ]

    var body: some View {
        ZStack {
            Theme.bg
            Blob(size: 280).offset(x: -140, y: -260)
            Blob(color: Theme.blob2, size: 230).opacity(0.8).offset(x: 160, y: 200)
            VStack(spacing: 26) {
                ZStack {
                    let colors = [Theme.accent, Theme.accentSoft, Theme.sage, Theme.sageSoft]
                    ForEach(0..<4, id: \.self) { index in
                        MarkPiece(index: index)
                            .fill(colors[index])
                            .shadow(color: .black.opacity(0.22), radius: 6, y: 5)
                            .offset(assembled ? .zero : Self.flyIn[index])
                            .rotationEffect(.degrees(assembled ? 0 : [-28, 24, 20, -22][index]))
                            .scaleEffect(assembled ? 1 : 1.3)
                            .opacity(assembled ? 1 : 0)
                            .animation(.spring(response: 0.7, dampingFraction: 0.7)
                                .delay(0.12 * Double(index)), value: assembled)
                    }
                }
                .frame(width: 128, height: 128)
                VStack(spacing: 6) {
                    Text("Sasha's Puzzles").font(Theme.display(32))
                    Text("real locks, a warm table")
                        .font(Theme.body(14)).foregroundStyle(Theme.faint)
                }
                .opacity(named ? 1 : 0)
                .offset(y: named ? 0 : 14)
                .animation(.easeOut(duration: 0.45), value: named)
            }
        }
        .ignoresSafeArea()
        .task {
            assembled = true
            try? await Task.sleep(for: .milliseconds(650))
            named = true
            try? await Task.sleep(for: .milliseconds(900))
            onFinish()
        }
    }

    /// One of the four mark pieces, in the 128pt frame the splash uses.
    nonisolated private struct MarkPiece: Shape {
        let index: Int
        func path(in rect: CGRect) -> Path {
            let scale = rect.width / (SplashView.geometry.boardSize.width * 1.28)
            let inset = (rect.width - SplashView.geometry.boardSize.width * scale) / 2
            let transform = CGAffineTransform(translationX: rect.minX + inset, y: rect.minY + inset)
                .scaledBy(x: scale, y: scale)
            return Path(SplashView.geometry.path(of: index)).applying(transform)
        }
    }
}
