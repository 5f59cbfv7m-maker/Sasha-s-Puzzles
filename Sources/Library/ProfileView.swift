import SwiftUI

/// Profile and statistics: totals, the weekly chart and the achievement wall.
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isCompact) private var isCompact

    private var stats: PlayerStats { model.stats }
    private var gutter: CGFloat { isCompact ? 18 : 30 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                tiles
                friends
                chart
                achievements
            }
            .padding(EdgeInsets(top: 26, leading: gutter, bottom: 30, trailing: gutter))
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        // Looked at: the "New" marks stay for this visit and go after it.
        .onDisappear { model.markAchievementsSeen() }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 720)
        #endif
    }

    private var header: some View {
        @Bindable var settings = model.settings
        return HStack(spacing: 16) {
            Text(settings.displayName.prefix(1))
                .font(Theme.display(26))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 64, height: 64)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                // Tap the name to change it; empty shows "Player" as the placeholder.
                HStack(spacing: 8) {
                    TextField("Player", text: $settings.playerName)
                        .textFieldStyle(.plain)
                        .font(Theme.display(26))
                        .textContentType(.givenName)
                        .fixedSize()
                        .accessibilityLabel(Text("Your name"))
                    Image(systemName: "pencil").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .accessibilityHidden(true)
                }
                Text(subtitle).font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
            Spacer()
            RoundIconButton(symbol: "gearshape") {
                dismiss()
                model.showSettings = true
            }
            .accessibilityLabel(Text("Settings"))
            PillButton(title: "Done", size: 15) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let first = stats.firstPlayed {
            // "MMMM" is the genitive month in Russian ("с сентября"); the
            // FormatStyle equivalent gives the standalone form.
            let month = DateFormatter()
            month.dateFormat = "MMMM"
            parts.append(String(localized: "At the table since \(month.string(from: first))"))
        }
        if stats.streak > 0 { parts.append(String(localized: "\(stats.streak) days in a row")) }
        return parts.isEmpty ? String(localized: "The first puzzle is waiting") : parts.joined(separator: " · ")
    }

    private var tiles: some View {
        // Fixed column counts: an adaptive grid in a form sheet sizes the sheet
        // from its content and the columns from the sheet — an endless loop.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: isCompact ? 2 : 4),
                  spacing: 12) {
            tile("\(stats.puzzlesSolved)", "puzzles solved")
            tile(stats.piecesPlaced.formatted(), "pieces placed")
            tile(hours, "at the table")
            tile("\(stats.streak)", "days in a row", tinted: true)
        }
    }

    private var hours: String {
        let hours = stats.timePlayed / 3600
        return hours < 1 ? String(localized: "\(Int(stats.timePlayed / 60)) min")
                         : String(localized: "\(Int(hours)) h")
    }

    private func tile(_ value: String, _ title: LocalizedStringKey, tinted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(30).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(Theme.body(12))
        }
        .foregroundStyle(tinted ? Theme.onSageTint : Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 18, leading: 14, bottom: 18, trailing: 14))
        .background(tinted ? Theme.sageTint : Theme.card,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Friends' leaderboards in Game Center. Hidden in builds that are not
    /// signed for it (ad-hoc Mac builds, stage runs).
    @ViewBuilder
    private var friends: some View {
        let gameCenter = model.gameCenter
        if gameCenter.isAvailable {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("With friends").font(Theme.display(19))
                    Text(verbatim: "Game Center").font(Theme.body(13)).foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                    if gameCenter.isSignedIn {
                        Button { afterDismiss { gameCenter.showDashboard() } } label: {
                            Text("All").font(Theme.body(14, .bold)).foregroundStyle(Theme.accentDeep)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if gameCenter.isSignedIn {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: isCompact ? 1 : 3),
                              spacing: 12) {
                        ForEach(GameCenter.Board.allCases) { board in
                            Button { afterDismiss { gameCenter.show(board) } } label: { boardRow(board) }
                                .buttonStyle(PressableStyle())
                        }
                    }
                } else if gameCenter.needsSignIn {
                    PillButton(title: "Sign in to Game Center", symbol: "person.2.fill", style: .sage, size: 15) {
                        gameCenter.presentSignIn()
                    }
                } else {
                    Text("Sign in to Game Center in the system settings to compare results with friends.")
                        .font(Theme.body(14)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func boardRow(_ board: GameCenter.Board) -> some View {
        HStack(spacing: 12) {
            Image(systemName: board.symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 40, height: 40)
                .background(Theme.accent, in: Circle())
            Text(board.title).font(Theme.body(15, .bold)).lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.faint)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Game Center presents from the main window, which cannot while this
    /// sheet covers it — close the sheet, then open Game Center.
    private func afterDismiss(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    /// Twelve bars, one per week; the busiest week takes the accent.
    private var chart: some View {
        let weeks = stats.weeklyPieces
        let peak = max(1, weeks.max() ?? 1)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Last 12 weeks").font(Theme.display(19))
                Text("pieces per week").font(Theme.body(13)).foregroundStyle(Theme.faint)
            }
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, pieces in
                    let share = Double(pieces) / Double(peak)
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 6,
                                           bottomTrailingRadius: 6, topTrailingRadius: 12)
                        .fill(barColor(share, isPeak: pieces == peak && pieces > 0))
                        .frame(height: max(6, 140 * share))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("\(pieces) pieces"))
                }
            }
            .frame(height: 140, alignment: .bottom)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func barColor(_ share: Double, isPeak: Bool) -> Color {
        if isPeak { return Theme.accent }
        if share > 0.75 { return Theme.sage }
        if share > 0.5 { return Theme.sageSoft }
        if share > 0.25 { return Theme.muted.opacity(0.5) }
        return Theme.track
    }

    private var achievements: some View {
        let unlocked = Achievement.allCases.filter { $0.isUnlocked(in: stats) }
        let unseen = model.unseenAchievements
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Achievements").font(Theme.display(19))
                Text("\(unlocked.count) of \(Achievement.allCases.count)")
                    .font(Theme.body(13)).foregroundStyle(Theme.faint)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: isCompact ? 1 : 2),
                      spacing: 12) {
                ForEach(Achievement.allCases) { achievement in
                    AchievementRow(achievement: achievement, unlocked: unlocked.contains(achievement),
                                   progress: achievement.progress(in: stats),
                                   isNew: unseen.contains(achievement))
                }
            }
        }
    }
}

struct AchievementRow: View {
    let achievement: Achievement
    let unlocked: Bool
    /// Shown as a bar until the medal is earned.
    var progress: (fraction: Double, label: String)?
    /// Earned since the player last opened the profile.
    var isNew = false

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if unlocked {
                    AchievementBadge(achievement: achievement)
                        .modifier(NewMedalGlow(active: isNew))
                } else {
                    Image(systemName: "lock")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 48, height: 48)
                        .overlay(Circle().strokeBorder(Theme.track, style: StrokeStyle(lineWidth: 2, dash: [4, 4])))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(achievement.title).font(Theme.body(16, .bold)).lineLimit(1)
                    if isNew {
                        Text("New")
                            .font(Theme.body(11, .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(achievement.detail).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(2)
                if let progress, !unlocked {
                    HStack(spacing: 8) {
                        ProgressBar(value: progress.fraction, height: 6)
                        Text(verbatim: progress.label)
                            .font(Theme.body(12, .bold).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .fixedSize()
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(unlocked ? Theme.card : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if isNew {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5)
            }
        }
        .opacity(unlocked ? 1 : 0.8)
        .accessibilityElement(children: .combine)
    }
}
