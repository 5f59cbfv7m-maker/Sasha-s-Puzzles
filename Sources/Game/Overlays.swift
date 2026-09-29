import SwiftUI

/// Frosted backdrop shared by every overlay.
private struct OverlayBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Theme.surface.opacity(0.72)
        }
        .ignoresSafeArea()
    }
}

/// Centres an overlay card, and scrolls it when the screen is shorter than
/// the card: an iPhone in landscape has well under 400pt of height, and the
/// buttons at the bottom of the card used to sit out of reach.
private struct FittedCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            // Falling medals and their bursts reach past the card.
            .scrollClipDisabled()
        }
    }
}

/// Shown while the picture is decoded and the pieces are cut.
struct LoadingOverlay: View {
    let session: GameSession

    private var progress: Double { max(0.02, session.textures.progress) }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Blob(size: 300).offset(x: -260, y: -240)
            Blob(color: Theme.blob2, size: 260).offset(x: 260, y: 240)
            VStack(spacing: 0) {
                ZStack {
                    Circle().stroke(Theme.surface, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: progress)
                    Text(verbatim: "\(Int(progress * 100))%")
                        .font(Theme.display(26).monospacedDigit())
                }
                .frame(width: 120, height: 120)
                Text("Cutting \(session.pieceCount) pieces")
                    .font(Theme.display(28))
                    .padding(.top, 24)
                Text("Real lock geometry: every cut exists once, so the pieces meet without gaps.")
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                ProgressBar(value: progress, height: 10)
                    .padding(.top, 22)
                Text("\(Int(progress * Double(session.pieceCount))) of \(session.pieceCount)")
                    .font(Theme.body(13).monospacedDigit())
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel(Text("Preparing puzzle"))
    }
}

struct ErrorOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            OverlayBackdrop()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Something went wrong").font(Theme.display(26))
                Text(message)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                PillButton(title: "Back to Library", action: onDismiss)
            }
            .padding(36)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
        }
    }
}

struct PauseOverlay: View {
    let session: GameSession
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }
    #else
    private let compact = false
    #endif

    var body: some View {
        ZStack {
            OverlayBackdrop()
            FittedCard {
                VStack(spacing: 4) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: compact ? 60 : 84, height: compact ? 60 : 84)
                        .background(Theme.accent, in: Circle())
                    Text("Break").font(Theme.display(30)).padding(.top, compact ? 10 : 16)
                    Text("The table is saved — come back whenever you like")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                    Text(TimeFormatting.clock(session.elapsed))
                        .font(Theme.display(compact ? 34 : 44).monospacedDigit())
                        .padding(.top, compact ? 8 : 14)
                    HStack(spacing: 10) {
                        PillButton(title: "Resume", symbol: "play.fill", expand: true) { session.resume() }
                            .keyboardShortcut(.space, modifiers: [])
                        PillButton(title: "Library", style: .secondary, size: 17) { model.showLibrary() }
                    }
                    .padding(.top, compact ? 16 : 24)
                }
                .padding(compact ? 24 : 40)
                .frame(maxWidth: 420)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
                .padding(20)
            }
        }
        .transition(.opacity)
    }
}

struct CompletionOverlay: View {
    let session: GameSession
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact }
    #else
    private let compact = false
    #endif
    @State private var appeared = false
    /// The nightmare medal falls in the dark and lands with a flash.
    @State private var night = 0.0
    @State private var flash = 0.0

    private var pace: String {
        let minutes = max(session.elapsed, 60) / 60
        return String(format: "%.1f", Double(session.pieceCount) / minutes)
    }

    var body: some View {
        ZStack {
            // `Color.clear` is what takes part in layout: a filled image in a
            // ZStack would grow the stack and push the card off centre.
            Color.clear
                .overlay {
                    if let ghost = session.ghostImage {
                        ghost.resizable().aspectRatio(contentMode: .fill).washed().opacity(0.3)
                    }
                }
                .clipped()
                .ignoresSafeArea()
            OverlayBackdrop()
            Confetti().ignoresSafeArea()

            FittedCard {
                VStack(spacing: 0) {
                    // On an iPhone in landscape the mark sits beside the title:
                    // stacked, it alone pushed the buttons below the screen.
                    if compact {
                        HStack(spacing: 16) {
                            checkmark
                            VStack(alignment: .leading, spacing: 2) { title; subtitle }
                        }
                    } else {
                        checkmark
                        title.padding(.top, 22)
                        subtitle.padding(.top, 6)
                    }

                    HStack(spacing: 12) {
                        stat(TimeFormatting.clock(session.elapsed), "time")
                        if let best = model.lastCompletion?.previousBest, best - session.elapsed >= 1 {
                            stat("−" + TimeFormatting.short(best - session.elapsed), "faster than record", tinted: true)
                        } else {
                            stat("\(session.pieceCount)", "pieces")
                        }
                        stat(pace, "per minute")
                    }
                    .padding(.top, compact ? 16 : 26)

                    if let news = model.lastCompletion?.newAchievements, !news.isEmpty {
                        AchievementReveal(achievements: news, compact: compact,
                                          onDrop: { if $0 == .nightmare { withAnimation(.easeIn(duration: 0.4)) { night = 0.6 } } },
                                          onLand: { if $0 == .nightmare { lightning() } })
                            .padding(.top, compact ? 12 : 18)
                    }

                    HStack(spacing: 12) {
                        PillButton(title: "Play again", expand: true) { model.restartCurrent() }
                        PillButton(title: "Library", style: .ghost, expand: true) { model.showLibrary() }
                    }
                    .padding(.top, compact ? 18 : 26)
                }
                .padding(compact ? EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28)
                                 : EdgeInsets(top: 44, leading: 40, bottom: 40, trailing: 40))
                .frame(maxWidth: 560)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 16, y: 10)
                .scaleEffect(appeared ? 1 : 0.9)
                .opacity(appeared ? 1 : 0)
                .padding(compact ? 12 : 20)
            }
            Color.black.opacity(night).ignoresSafeArea().allowsHitTesting(false)
            Color.white.opacity(flash).ignoresSafeArea().allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.6)) { appeared = true }
        }
    }

    private func lightning() {
        night = 0
        flash = 0.75
        withAnimation(.easeOut(duration: 0.8)) { flash = 0 }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: compact ? 26 : 46, weight: .heavy))
            .foregroundStyle(Theme.onAccent)
            .frame(width: compact ? 56 : 104, height: compact ? 56 : 104)
            .background(Theme.accent, in: Circle())
            .shadow(color: Theme.accentDeep.opacity(0.36), radius: 16, y: 10)
            .scaleEffect(appeared ? 1 : 0.4)
            .rotationEffect(.degrees(appeared ? 0 : -24))
    }

    private var title: some View {
        Text("Puzzle solved!").font(Theme.display(compact ? 28 : 38))
    }

    private var subtitle: some View {
        Text("\(session.item.title) · \(session.pieceCount) pieces")
            .font(Theme.body(compact ? 15 : 17))
            .foregroundStyle(Theme.muted)
    }

    private func stat(_ value: String, _ title: LocalizedStringKey, tinted: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.display(26).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title).font(Theme.body(12))
        }
        .foregroundStyle(tinted ? Theme.onSageTint : Theme.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 10 : 16)
        .padding(.horizontal, 8)
        .background(tinted ? Theme.sageTint : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A dozen paper pieces drifting down, in the palette.
private struct Confetti: View {
    private struct Piece {
        let x: CGFloat, size: CGFloat, delay: Double, duration: Double, round: Bool, color: Int
    }

    private static let pieces: [Piece] = {
        var rng = SplitMix64(seed: 7)
        return (0..<28).map { _ in
            Piece(x: CGFloat(rng.unit()), size: 10 + CGFloat(rng.unit()) * 8,
                  delay: rng.unit() * 3, duration: 3 + rng.unit() * 1.4,
                  round: rng.unit() > 0.5, color: Int(rng.unit() * 4))
        }
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let colors = [Theme.accent, Theme.sage, Theme.accentSoft, Theme.sageSoft]
                let now = timeline.date.timeIntervalSinceReferenceDate
                for piece in Self.pieces {
                    let t = ((now + piece.delay).truncatingRemainder(dividingBy: piece.duration)) / piece.duration
                    let y = -40 + t * (size.height + 80)
                    let rect = CGRect(x: piece.x * size.width - piece.size / 2, y: y,
                                      width: piece.size, height: piece.round ? piece.size : piece.size * 1.5)
                    var layer = context
                    layer.opacity = min(1, t / 0.1, (1 - t) / 0.3)
                    layer.translateBy(x: rect.midX, y: rect.midY)
                    layer.rotate(by: .degrees(t * 520))
                    let path = piece.round
                        ? Path(ellipseIn: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
                        : Path(roundedRect: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height), cornerRadius: 4)
                    layer.fill(path, with: .color(colors[piece.color]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Full-size reference view of the picture being assembled.
struct OriginalImageSheet: View {
    let session: GameSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.item.title).font(Theme.display(22)).lineLimit(1)
                Spacer()
                PillButton(title: "Done", size: 15) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 14, trailing: 22))
            Group {
                if let ghost = session.ghostImage {
                    ghost
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
                        .shadow(color: .black.opacity(0.24), radius: 16, y: 10)
                        .padding(EdgeInsets(top: 4, leading: 26, bottom: 26, trailing: 26))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        // Same window-constraint trap: on a phone this sheet is already the full
        // screen, and 520pt pushes the navigation bar past both edges.
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 380)
        #endif
    }
}
