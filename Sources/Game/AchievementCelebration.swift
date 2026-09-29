import SwiftUI

// MARK: - Medal

/// An achievement's medal, drawn like its Game Center art: the number for a
/// milestone, a stopwatch or a motif, or the category's photograph.
///
/// Bumping `celebration` plays the medal's own flourish once — the number
/// counts up, the stopwatch hand sweeps, the photograph settles — with a
/// shine across the disc. `armed` shows the starting frame of that flourish
/// (a zero, the hand at twelve) for a medal that is about to celebrate.
struct AchievementBadge: View {
    let achievement: Achievement
    var size: CGFloat = 48
    var celebration = 0
    var armed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count: Int?
    @State private var hand: Double?
    @State private var zoom: CGFloat = 1
    @State private var shine: CGFloat = -1

    /// The night-sky disc of the hardest achievement, as in its Game Center art.
    static let night = Color(red: 0.29, green: 0.23, blue: 0.2)

    private var target: Int? {
        switch achievement {
        case .firstPuzzle: 1
        case .tenPuzzles: 10
        case .fiftyPuzzles: 50
        default: nil
        }
    }

    private var isArmed: Bool { armed && !reduceMotion }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .overlay { shineBand }
            .clipShape(Circle())
            .onChange(of: celebration) { celebrate() }
    }

    private var fill: Color {
        if achievement.category != nil { return Theme.sage }
        return achievement == .nightmare ? Self.night : Theme.accent
    }

    @ViewBuilder
    private var content: some View {
        if let target {
            let value = count ?? (isArmed ? 0 : target)
            Text("\(value)")
                .font(Theme.display(size * (target >= 10 ? 0.42 : 0.52)))
                .foregroundStyle(Theme.onAccent)
                .contentTransition(.numericText(value: Double(value)))
                .offset(y: size * 0.02)
        } else if achievement == .sprinter {
            stopwatch
        } else if let id = achievement.coverID, let item = LibraryCatalog.builtIn().first(where: { $0.id == id }) {
            LibraryThumbnail(item: item, longSide: 240)
                .scaleEffect(zoom)
                .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: max(1.5, size * 0.035)))
        } else {
            Image(systemName: achievement.symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .symbolEffect(.bounce.up, options: .repeat(achievement == .weekStreak ? 3 : 2), value: celebration)
        }
    }

    /// A five-minute dial: the hand rests on five, and sweeps a full turn
    /// before settling there.
    private var stopwatch: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.onAccent, lineWidth: size * 0.06)
                .padding(size * 0.2)
            RoundedRectangle(cornerRadius: size * 0.02)
                .fill(Theme.onAccent)
                .frame(width: size * 0.14, height: size * 0.08)
                .offset(y: -size * 0.36)
            Capsule()
                .fill(Theme.onAccent)
                .frame(width: size * 0.07, height: size * 0.24)
                .offset(y: -size * 0.1)
                .rotationEffect(.degrees(hand ?? (isArmed ? 0 : 30)))
            Circle().fill(Theme.onAccent).frame(width: size * 0.11)
        }
    }

    private var shineBand: some View {
        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: size * 0.45)
            .rotationEffect(.degrees(20))
            .offset(x: shine * size * 1.1)
            .allowsHitTesting(false)
    }

    private func celebrate() {
        guard celebration > 0, !reduceMotion else { return }
        if let target {
            let step = max(1, target / 25)
            let pause = Duration.milliseconds(target > 1 ? 600 / (target / step) : 200)
            Task {
                for value in stride(from: 0, through: target, by: step) {
                    withAnimation(.snappy(duration: 0.18)) { count = value }
                    try? await Task.sleep(for: pause)
                }
                withAnimation(.snappy(duration: 0.18)) { count = target }
            }
        }
        if achievement == .sprinter {
            hand = 0
            withAnimation(.easeInOut(duration: 1.1)) { hand = 390 }
        }
        if achievement.coverID != nil {
            zoom = 1.4
            withAnimation(.easeOut(duration: 1.4)) { zoom = 1 }
        }
        withAnimation(.easeInOut(duration: 0.75).delay(0.2)) {
            shine = 1
        } completion: {
            shine = -1
        }
    }
}

extension Achievement {
    /// The photograph in a category medal — the one its Game Center art
    /// uses too (`Scripts/make-achievement-badges.swift`).
    var coverID: String? {
        switch self {
        case .space: "bundled.space_Aurora over the Pines"
        case .nature: "bundled.nature_Autumn Forest from Above"
        case .mountains: "bundled.mountains_Alpine Village"
        case .sea: "bundled.sea_Cliff Lighthouse"
        case .city: "bundled.city_Boats of Vernazza"
        case .animals: "bundled.animals_Bengal Tiger"
        case .abstract: "bundled.abstract_Balloons over Cappadocia"
        default: nil
        }
    }
}

// MARK: - Burst

/// Little paper jigsaw pieces flung out of a medal as it lands, then
/// falling away. Draws nothing once it is over.
struct PieceBurst: View {
    let start: Date
    var reach: CGFloat = 80

    private struct Bit { let angle, speed, spin, size: Double; let color: Int }
    private let bits: [Bit]
    static let duration = 1.3

    init(start: Date, seed: UInt64, reach: CGFloat = 80) {
        self.start = start
        self.reach = reach
        var rng = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 11)
        bits = (0..<22).map { index in
            // Evenly around the circle with a little jitter, so the burst
            // never leaves an empty side.
            Bit(angle: (Double(index) + rng.unit() * 0.7) / 22 * 2 * .pi,
                speed: 0.55 + rng.unit() * 0.6,
                spin: (rng.unit() - 0.5) * 14,
                size: 8 + rng.unit() * 7,
                color: Int(rng.unit() * 5))
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                guard t >= 0, t < Self.duration else { return }
                let colors = [Theme.accent, Theme.sage, Theme.accentSoft, Theme.sageSoft, Theme.accentDeep]
                let progress = t / Self.duration
                let flight = 1 - pow(1 - min(1, t / 0.6), 3)
                for bit in bits {
                    let travel = reach * bit.speed * flight
                    var layer = context
                    layer.opacity = 1 - progress * progress
                    layer.translateBy(x: size.width / 2 + cos(bit.angle) * travel,
                                      y: size.height / 2 + sin(bit.angle) * travel + 70 * t * t)
                    layer.rotate(by: .radians(bit.angle + bit.spin * t))
                    let scale = bit.size * (1 - 0.35 * progress)
                    layer.scaleBy(x: scale, y: scale)
                    layer.fill(Self.piece, with: .color(colors[bit.color]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A unit jigsaw piece with tabs on the top and right.
    private static let piece: Path = {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: -0.5, y: -0.5, width: 1, height: 1),
                            cornerSize: CGSize(width: 0.12, height: 0.12))
        path.addEllipse(in: CGRect(x: -0.18, y: -0.84, width: 0.36, height: 0.36))
        path.addEllipse(in: CGRect(x: 0.48, y: -0.18, width: 0.36, height: 0.36))
        return path
    }()
}

// MARK: - Reveal

/// New achievements on the completion card. The medals drop in one after
/// another; each lands with a burst of pieces, a chime and its own
/// flourish, and the caption follows the medal that landed last.
struct AchievementReveal: View {
    let achievements: [Achievement]
    var compact = false
    /// Before a medal starts to fall, and as it lands — for effects that
    /// belong to the whole screen rather than the card.
    var onDrop: (Achievement) -> Void = { _ in }
    var onLand: (Achievement) -> Void = { _ in }

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var arrived: Set<Int> = []
    @State private var landed = 0
    @State private var bursts: [Int: Date] = [:]

    private var badge: CGFloat { compact ? 36 : 48 }
    private var current: Achievement { achievements[max(0, landed - 1)] }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: -badge * 0.2) {
                ForEach(Array(achievements.enumerated()), id: \.element) { index, achievement in
                    AchievementBadge(achievement: achievement, size: badge,
                                     celebration: index < landed ? 1 : 0, armed: true)
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .overlay {
                            if let start = bursts[index] {
                                PieceBurst(start: start, seed: UInt64(index + 1), reach: badge * 2.2)
                                    .frame(width: badge * 5, height: badge * 5)
                            }
                        }
                        .scaleEffect(arrived.contains(index) || reduceMotion ? 1 : 1.9)
                        .offset(y: arrived.contains(index) || reduceMotion ? 0 : -badge * 2.4)
                        .opacity(arrived.contains(index) ? 1 : 0)
                        .zIndex(Double(index))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Kicker(text: "new achievement").foregroundStyle(Theme.accentDeep)
                Text("\(current.title) — \(current.detail)")
                    .font(Theme.body(17, .bold)).lineLimit(2)
                    .id(current)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(compact ? EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
                         : EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(visible ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(achievements.map { "\($0.title) — \($0.detail)" }.joined(separator: ", ")))
        .task { await run() }
    }

    private func run() async {
        // After the card's own entrance, so the two do not compete.
        try? await Task.sleep(for: .seconds(0.9))
        withAnimation(.easeOut(duration: 0.3)) { visible = true }
        for (index, achievement) in achievements.enumerated() {
            if !reduceMotion {
                onDrop(achievement)
                if achievement == .nightmare { try? await Task.sleep(for: .seconds(0.45)) }
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.42, dampingFraction: 0.6)) {
                _ = arrived.insert(index)
            }
            try? await Task.sleep(for: .seconds(0.28))
            withAnimation(.snappy) { landed = index + 1 }
            Feedback.shared.play(.achievement, settings: settings)
            Feedback.shared.impact(.strong, settings: settings)
            if !reduceMotion {
                bursts[index] = .now
                onLand(achievement)
            }
            try? await Task.sleep(for: .seconds(1.4))
            bursts[index] = nil
        }
    }
}

// MARK: - Profile

/// Soft pulsing ring around a medal the player has not looked at yet.
struct NewMedalGlow: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .background {
                if active {
                    Circle()
                        .fill(Theme.accent.opacity(0.35))
                        .padding(-6)
                        .scaleEffect(pulse ? 1.12 : 0.92)
                        .opacity(pulse ? 0.25 : 0.9)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
                        }
                }
            }
    }
}
