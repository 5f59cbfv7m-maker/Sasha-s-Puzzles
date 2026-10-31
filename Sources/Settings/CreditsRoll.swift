import SwiftUI

/// The photographers and type designers behind the game, rolling up the
/// screen like a film's closing credits and starting over at the end. A tap
/// pauses them, a drag scrolls by hand. With VoiceOver or Reduce Motion they
/// stand still in an ordinary scroll view.
struct CreditsRoll: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @State private var start = Date.now
    @State private var pausedAt: Date?
    /// How far a drag has moved the roll, in points.
    @State private var scrub: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var height: CGFloat = 0

    /// Points a second: slow enough to read a name and its picture.
    static let speed: CGFloat = 38

    var body: some View {
        if reduceMotion || voiceOver {
            ScrollView { CreditsList().padding(.vertical, 26) }
        } else {
            roll
        }
    }

    private var roll: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: pausedAt != nil)) { context in
                let elapsed = CGFloat((pausedAt ?? context.date).timeIntervalSince(start))
                let travel = max(1, height + proxy.size.height)
                // The title starts halfway up rather than below the edge: no empty screen to wait through.
                let lead = proxy.size.height * 0.5
                let moved = (elapsed * Self.speed + scrub + lead).truncatingRemainder(dividingBy: travel)
                // A view of its own, so each frame moves it without rebuilding the names.
                CreditsList()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .offset(y: proxy.size.height - (moved < 0 ? moved + travel : moved))
            }
        }
        .clipped()
        // The names fade in at the foot and out at the head, as on a screen.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                   .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .contentShape(Rectangle())
        .onTapGesture { togglePause() }
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil { dragStart = scrub }
                scrub = (dragStart ?? 0) - value.translation.height
            }
            .onEnded { _ in dragStart = nil })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("Tap to pause, drag to scroll")
                .font(Theme.body(12)).foregroundStyle(Theme.faint)
                .padding(.vertical, 10)
        }
    }

    private func togglePause() {
        if let pausedAt {
            start += Date.now.timeIntervalSince(pausedAt)
            self.pausedAt = nil
        } else {
            pausedAt = .now
        }
    }

}

private struct CreditsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // A secret picture's title stays hidden until it opens.
        let unlocks = model.unlocks
        let credited = LibraryCatalog.builtIn().filter { !($0.category == .secret && model.isLocked($0, unlocks)) }
        return VStack(spacing: 30) {
            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 56, height: 56)
                    .background(Theme.accent, in: Circle())
                Text("Sasha's Puzzles").font(Theme.display(34))
                Text("All built-in pictures are photographs from Unsplash. Thank you to the photographers!")
                    .font(Theme.body(15)).foregroundStyle(Theme.muted)
            }
            ForEach(ArtCategory.allCases.filter { category in credited.contains { $0.category == category } }) { category in
                VStack(spacing: 16) {
                    Text(category.title).font(Theme.display(24)).foregroundStyle(Theme.accentDeep)
                    ForEach(credited.filter { $0.category == category }
                        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { item in
                        if let credit = PhotoCredits.credit(for: item) {
                            VStack(spacing: 2) {
                                Text(item.title).font(Theme.body(14)).foregroundStyle(Theme.muted)
                                Text(verbatim: credit.photographer).font(Theme.body(19, .bold))
                            }
                        }
                    }
                }
            }
            VStack(spacing: 16) {
                Text("Fonts").font(Theme.display(24)).foregroundStyle(Theme.accentDeep)
                VStack(spacing: 2) {
                    Text(verbatim: "Caprasimo").font(Theme.body(14)).foregroundStyle(Theme.muted)
                    Text(verbatim: "The Caprasimo Project Authors").font(Theme.body(19, .bold))
                }
                VStack(spacing: 2) {
                    Text(verbatim: "Figtree").font(Theme.body(14)).foregroundStyle(Theme.muted)
                    Text(verbatim: "Erik Kennedy").font(Theme.body(19, .bold))
                }
            }
            Text("Thank you!").font(Theme.display(30)).padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
    }
}
