import SwiftUI

/// Medals for the player who keeps going after the achievements: each has
/// five levels, bronze to diamond, with goals far past the achievements'.
/// Derived from the records like everything else, so they sync and backfill
/// by themselves. In-game only: Game Center would need each level set up in
/// App Store Connect first.
nonisolated enum Medal: String, CaseIterable, Identifiable, Sendable {
    case puzzles, pieces, points, dailies, bigPuzzles, quick, together, gallery

    var id: String { rawValue }

    enum Tier: Int, CaseIterable, Comparable, Sendable {
        case bronze = 1, silver, gold, platinum, diamond

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .bronze: String(localized: "Bronze")
            case .silver: String(localized: "Silver")
            case .gold: String(localized: "Gold")
            case .platinum: String(localized: "Platinum")
            case .diamond: String(localized: "Diamond")
            }
        }

        var color: Color {
            switch self {
            case .bronze: Color(red: 0.76, green: 0.49, blue: 0.28)
            case .silver: Color(red: 0.62, green: 0.66, blue: 0.71)
            case .gold: Color(red: 0.89, green: 0.68, blue: 0.20)
            case .platinum: Color(red: 0.50, green: 0.70, blue: 0.70)
            case .diamond: Color(red: 0.40, green: 0.68, blue: 0.95)
            }
        }

        var next: Tier? { Tier(rawValue: rawValue + 1) }
    }

    var title: String {
        switch self {
        case .puzzles: String(localized: "Puzzles solved")
        case .pieces: String(localized: "Pieces placed")
        case .points: String(localized: "Points")
        case .dailies: String(localized: "Daily puzzles")
        case .bigPuzzles: String(localized: "Big puzzles")
        case .quick: String(localized: "Quick hands")
        case .together: String(localized: "Played together")
        case .gallery: String(localized: "Gallery")
        }
    }

    var detail: String {
        switch self {
        case .puzzles: String(localized: "every finished puzzle counts")
        case .pieces: String(localized: "every piece you put in")
        case .points: String(localized: "points earned")
        case .dailies: String(localized: "daily puzzles solved, in a row or not")
        case .bigPuzzles: String(localized: "puzzles of 500 pieces or more")
        case .quick: String(localized: "48 pieces or more in under 5 minutes")
        case .together: String(localized: "puzzles solved at a shared table")
        case .gallery: String(localized: "different pictures solved")
        }
    }

    var symbol: String {
        switch self {
        case .puzzles: "puzzlepiece.fill"
        case .pieces: "square.grid.3x3.fill"
        case .points: "star.fill"
        case .dailies: "sun.max.fill"
        case .bigPuzzles: "mountain.2.fill"
        case .quick: "bolt.fill"
        case .together: "person.2.fill"
        case .gallery: "photo.stack.fill"
        }
    }

    /// What each level asks for, bronze first.
    var goals: [Int] {
        switch self {
        case .puzzles: [25, 75, 150, 300, 600]
        case .pieces: [2_000, 10_000, 30_000, 75_000, 150_000]
        case .points: [3_000, 10_000, 30_000, 75_000, 150_000]
        case .dailies: [10, 30, 75, 150, 365]
        case .bigPuzzles: [1, 5, 15, 40, 100]
        case .quick: [3, 10, 30, 75, 150]
        case .together: [1, 5, 15, 40, 100]
        // Diamond is every built-in picture, however many there are by then.
        case .gallery: [20, 50, 90, 130, LibraryCatalog.count]
        }
    }

    /// The level reached at `value`, if any.
    func tier(at value: Int) -> Tier? {
        Tier.allCases.last { value >= goals[$0.rawValue - 1] }
    }
}

/// A level reached in the game just finished, for the completion card.
nonisolated struct MedalAward: Hashable, Sendable {
    var medal: Medal
    var tier: Medal.Tier
}

@MainActor
extension Medal {
    func value(in stats: PlayerStats) -> Int {
        switch self {
        case .puzzles: stats.puzzlesSolved
        case .pieces: stats.piecesPlaced
        case .points: stats.points
        case .dailies: stats.dailyCount
        case .bigPuzzles: stats.records.filter { $0.pieces >= 500 }.count
        case .quick: stats.records.filter { $0.pieces >= 48 && $0.elapsed <= 300 && !$0.isShared }.count
        case .together: stats.records.filter(\.isShared).count
        case .gallery: Set(stats.records.filter { !$0.isUserPhoto }.map(\.itemID)).count
        }
    }

    func tier(in stats: PlayerStats) -> Tier? { tier(at: value(in: stats)) }

    /// Toward the next level; numbers only, so it needs no translation.
    func progress(in stats: PlayerStats) -> (fraction: Double, label: String) {
        let value = value(in: stats)
        guard let next = tier(at: value)?.next ?? (tier(at: value) == nil ? .bronze : nil) else {
            return (1, value.formatted())
        }
        let goal = goals[next.rawValue - 1]
        return (Double(min(value, goal)) / Double(goal), "\(min(value, goal).formatted()) / \(goal.formatted())")
    }
}

/// A medal's face in its level's metal; dashed and grey before bronze.
struct MedalBadge: View {
    let medal: Medal
    let tier: Medal.Tier?
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let tier {
                Image(systemName: medal.symbol)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        Circle().fill(LinearGradient(colors: [tier.color.opacity(0.75), tier.color],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: size * 0.05).padding(size * 0.06))
                    .overlay(alignment: .topTrailing) {
                        if tier == .diamond {
                            Image(systemName: "sparkle")
                                .font(.system(size: size * 0.28, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: tier.color, radius: 3)
                                .offset(x: size * 0.06, y: -size * 0.06)
                        }
                    }
                    .shadow(color: tier.color.opacity(0.35), radius: 4, y: 2)
            } else {
                Image(systemName: medal.symbol)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Theme.track, style: StrokeStyle(lineWidth: 2, dash: [4, 4])))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One medal in the profile: its level, the five steps, the way to the next.
struct MedalRow: View {
    let medal: Medal
    let stats: PlayerStats

    var body: some View {
        let tier = medal.tier(in: stats)
        let progress = medal.progress(in: stats)
        HStack(spacing: 14) {
            MedalBadge(medal: medal, tier: tier)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(medal.title).font(Theme.body(16, .bold)).lineLimit(1)
                    if let tier {
                        Text(tier.title)
                            .font(Theme.body(11, .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tier.color, in: Capsule())
                    }
                }
                Text(medal.detail).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(2)
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(Medal.Tier.allCases, id: \.self) { step in
                            Circle()
                                .fill(tier.map { step <= $0 } == true ? step.color : Theme.track)
                                .frame(width: 8, height: 8)
                        }
                    }
                    if tier == .diamond {
                        Text("All levels").font(Theme.body(12, .bold)).foregroundStyle(Theme.muted)
                    } else {
                        ProgressBar(value: progress.fraction, height: 6)
                        Text(verbatim: progress.label)
                            .font(Theme.body(12, .bold).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .fixedSize()
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(tier == nil ? Theme.surface : Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [medal.title, tier?.title ?? String(localized: "not started"), progress.label].joined(separator: ", ")))
    }
}
