import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var page = Page.settings

    private enum Page { case settings, credits, points }

    var body: some View {
        Group {
            switch page {
            case .settings: settingsPage
            case .credits: creditsPage
            case .points: pointsPage
            }
        }
        .background(Theme.surface)
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
        .confirmationDialog("Delete all saved games and statistics?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.deleteAllSaves()
                model.stats.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are also removed on your other devices that use the same iCloud account.")
        }
        // A minimum size is a *window* constraint: the macOS Settings scene needs
        // one, but on iOS this sheet is the phone screen and 460pt forces the
        // form wider than it, clipping the Done button off the trailing edge.
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    private var settingsPage: some View {
        @Bindable var settings = model.settings

        return VStack(spacing: 0) {
            HStack {
                Text("Settings").font(Theme.display(28))
                Spacer()
                PillButton(title: "Done", size: 15) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(EdgeInsets(top: 26, leading: 26, bottom: 18, trailing: 26))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Appearance") {
                        stacked("Theme") {
                            PillSegments(options: AppSettings.Appearance.allCases,
                                         selection: $settings.appearance, title: { $0.title }, expand: true)
                        }
                        toggle("Picture guide on the table", $settings.showGhostImage)
                        toggle("Outline pieces", $settings.showPieceOutlines)
                        toggle("Cardboard pieces", $settings.cardboardPieces)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Table").font(Theme.body(16))
                            PillSegments(options: AppSettings.TableSurface.allCases,
                                         selection: $settings.table, title: { $0.title }, expand: true)
                        }
                        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
                    }
                    group("Feedback") {
                        toggle("Sounds", $settings.soundEnabled)
                        if Feedback.hasMusic {
                            toggle("Background music", $settings.musicEnabled)
                            if settings.musicEnabled {
                                stacked("Music at the table") { MelodyPicker(selection: $settings.boardMusic) }
                                stacked("Music in the library") { MelodyPicker(selection: $settings.libraryMusic) }
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 12) {
                                        Text("Mix").font(Theme.body(16))
                                        Spacer()
                                        Toggle("Mix", isOn: $settings.musicMix).labelsHidden().toggleStyle(.switch)
                                    }
                                    Text("The tunes take turns during the game, all in the style of the one you chose.")
                                        .font(Theme.body(13)).foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
                            }
                        }
                        #if os(iOS)
                        toggle("Haptic feedback", $settings.hapticsEnabled)
                        #endif
                    }
                    group("Gameplay") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Snap assist").font(Theme.body(16))
                                Spacer()
                                Text(settings.snapAssist.title)
                                    .font(Theme.body(14, .bold)).foregroundStyle(Theme.accentDeep)
                            }
                            PillSegments(options: SnapAssist.allCases,
                                         selection: $settings.snapAssist, title: { $0.title }, expand: true)
                        }
                        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
                        row("Default difficulty") {
                            Picker("Default difficulty", selection: $settings.defaultDifficulty) {
                                ForEach(Difficulty.allCases) {
                                    Text("\($0.title) · \($0.targetPieces)").tag($0)
                                }
                            }
                            .labelsHidden()
                        }
                        row("Default framing") {
                            Picker("Default framing", selection: $settings.defaultAspect) {
                                ForEach(PuzzleAspect.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    group("Saved games") {
                        row("Saved games") {
                            Text("\(model.savedGames.count)")
                                .font(Theme.body(14, .bold)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 11).padding(.vertical, 3)
                                .background(Theme.surface, in: Capsule())
                        }
                        row("Puzzles solved") {
                            Text("\(model.stats.puzzlesSolved)")
                                .font(Theme.body(14, .bold)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 11).padding(.vertical, 3)
                                .background(Theme.surface, in: Capsule())
                        }
                        link("Points history") { page = .points }
                        Button { confirmReset = true } label: {
                            Text("Reset saved games and statistics")
                                .font(Theme.body(16, .bold))
                                .foregroundStyle(Theme.accentDeep)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    group("About") {
                        link("Photo credits") { page = .credits }
                    }
                    Text("Sasha's Puzzles · \(LibraryCatalog.count) built-in pictures · \(model.library.userItems.count) of your photos · works entirely offline")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding(EdgeInsets(top: 0, leading: 22, bottom: 26, trailing: 22))
            }
        }
    }

    /// Who took each built-in photograph, rolling up like a film's credits.
    private var creditsPage: some View {
        VStack(spacing: 0) {
            subpageHeader("Photo credits")
            CreditsRoll()
        }
    }

    /// What every solved puzzle earned, newest first. Out of the way behind
    /// a row, for the player who wonders where a number came from.
    private var pointsPage: some View {
        let history = model.stats.pointsHistory
        return VStack(spacing: 0) {
            subpageHeader("Points history")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(Theme.accent)
                        Text("\(model.stats.points) points").font(Theme.display(22)).monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    if history.isEmpty {
                        Text("No points yet. Every puzzle you finish adds a point a piece.")
                            .font(Theme.body(15)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 12)
                    } else {
                        Text("A point a piece, a quarter more from 150 pieces and half as much again from 500. The first daily puzzle of the day counts double, plus 50 a day of the streak, up to 350.")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.element.record.id) { index, entry in
                                if index > 0 { Theme.hairline.frame(height: 1).padding(.horizontal, 14) }
                                pointsRow(entry)
                            }
                        }
                        .padding(6)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 22, bottom: 26, trailing: 22))
            }
        }
    }

    private func pointsRow(_ entry: (record: SolvedRecord, points: Int, daily: Bool, streakBonus: Int)) -> some View {
        let record = entry.record
        let title = record.isUserPhoto ? String(localized: "Your photo")
            : model.library.item(id: record.itemID)?.title ?? String(localized: "Picture")
        var reasons = [String(localized: "\(record.pieces) pieces")]
        if let own = record.sharedPieces { reasons.append(String(localized: "together: \(own) of them yours")) }
        if entry.daily { reasons.append(String(localized: "daily puzzle ×2")) }
        if entry.streakBonus > 0 { reasons.append(String(localized: "+\(entry.streakBonus) for the streak")) }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body(16, .semibold)).lineLimit(1)
                Text(reasons.joined(separator: " · "))
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.body(12)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            Text(verbatim: "+\(entry.points)").font(Theme.body(16, .bold).monospacedDigit())
                .foregroundStyle(Theme.accentDeep)
        }
        .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
    }

    private func subpageHeader(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            RoundIconButton(symbol: "chevron.left", size: 40) { page = .settings }
                .accessibilityLabel(Text("Back"))
            Text(title).font(Theme.display(28)).lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 4)
            PillButton(title: "Done", size: 15) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(EdgeInsets(top: 26, leading: 26, bottom: 18, trailing: 26))
    }

    // MARK: - Building blocks

    private func group<Content: View>(_ title: LocalizedStringKey,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: title).padding(.horizontal, 12)
            Group(subviews: content()) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id {
                            Theme.hairline.frame(height: 1).padding(.horizontal, 14)
                        }
                    }
                }
            }
            .padding(6)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func row<Trailing: View>(_ title: LocalizedStringKey,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.body(16))
            Spacer()
            trailing()
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
    }

    /// Title above, control below at full width: for choices whose names
    /// would not fit beside the title on a phone.
    private func stacked<Control: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.body(16))
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
    }

    /// A row that opens a page of its own.
    private func link(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.body(16))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.faint)
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Label left, switch right on every platform: a bare `Toggle` fills the
    /// row on iOS but hugs its label on the Mac, which centred both.
    private func toggle(_ title: LocalizedStringKey, _ isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// Every tune, grouped by style; used in Settings and in the library.
struct MelodyPicker: View {
    @Binding var selection: AppSettings.Melody

    var body: some View {
        Picker("Music", selection: $selection) {
            ForEach(AppSettings.Melody.Style.allCases) { style in
                Section(style.title) {
                    ForEach(style.melodies) { Text($0.title).tag($0) }
                }
            }
        }
        .labelsHidden()
        // The tune's name on one line; the row's title wraps instead.
        .fixedSize()
    }
}
