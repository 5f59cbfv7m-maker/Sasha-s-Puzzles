import PhotosUI
import SwiftUI

/// The library screen — the app's home.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isCompact) private var isCompact

    @State private var category: ArtCategory?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImportingFiles = false
    @State private var importError: String?
    @State private var isImporting = false

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 18)]
    private var gutter: CGFloat { isCompact ? 16 : 26 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                header
                dailyCard
                if !model.resumable.isEmpty {
                    continueSection
                }
                Section {
                    sectionTitle
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(items) { item in
                            PictureCard(item: item, solved: solvedTime(for: item),
                                        inProgress: progressPieces(for: item)) {
                                model.openSetup(for: item)
                            }
                            .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding(.horizontal, gutter)
                    .padding(.bottom, 30)
                } header: {
                    categoryBar
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        // Solid status bar: pictures scrolling under the clock made it unreadable.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0).background(Theme.bg.ignoresSafeArea(edges: .top))
        }
        .fileImporter(isPresented: $isImportingFiles,
                      allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            handleFileImport(result)
        }
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            Task { await importPhotos(selection) }
        }
        // A `.constant` binding cannot be written back, so any dismissal the OK
        // button doesn't handle — Escape, or the Return key on a hardware
        // keyboard — left `importError` set and the alert re-presented itself
        // immediately. Clearing it from the setter makes every route dismiss.
        .alert("Import failed", isPresented: Binding(get: { importError != nil },
                                                     set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .overlay(alignment: .bottom) {
            if isImporting {
                Label("Importing…", systemImage: "arrow.down.circle")
                    .font(Theme.body(14, .bold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.card, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .onAppear { model.refreshSaves() }
    }

    private var items: [LibraryItem] {
        model.library.items(in: category)
    }

    private func solvedTime(for item: LibraryItem) -> TimeInterval? {
        model.stats.bestTime(for: item.id)
    }

    private func progressPieces(for item: LibraryItem) -> Int? {
        model.savedGames.first { !$0.isComplete && $0.itemID == item.id }?.pieceCount
    }

    // MARK: - Sections

    /// On a phone the title and four buttons cannot share one row — the
    /// name came out as "Sasha's Puzz…" even on the widest iPhone — so the
    /// buttons move up into a bar of their own and the title sits under
    /// them, like a large navigation title.
    private var header: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        headerButtons
                    }
                    HStack(spacing: 12) {
                        headerMark
                        headerTitle
                    }
                }
            } else {
                HStack(spacing: 14) {
                    headerMark
                    headerTitle
                    Spacer()
                    headerButtons
                }
            }
        }
        .padding(.horizontal, gutter)
        .padding(.top, isCompact ? 4 : 10)
    }

    private var headerMark: some View {
        Image(systemName: "puzzlepiece.fill")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 44, height: 44)
            .background(Theme.accent, in: Circle())
            .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
    }

    private var headerTitle: some View {
        Text("Sasha's Puzzles")
            .font(Theme.display(isCompact ? 30 : 34))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var headerButtons: some View {
        let chip: CGFloat = isCompact ? 40 : 44
        return HStack(spacing: isCompact ? 6 : 8) {
            PhotosPicker(selection: $photoSelection, maxSelectionCount: 20, matching: .images) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: chip * 0.42, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: chip, height: chip)
                    .background(Theme.chip, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text("Add Photo"))
            RoundIconButton(symbol: "folder.badge.plus", size: chip) { isImportingFiles = true }
                .accessibilityLabel(Text("Import from Files"))
            RoundIconButton(symbol: "person.fill", size: chip) { model.showProfile = true }
                .overlay(alignment: .topTrailing) {
                    // An achievement not yet looked at in the profile.
                    if !model.unseenAchievements.isEmpty {
                        Circle().fill(Theme.accent)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                            .offset(x: 1, y: -1)
                            .transition(.scale)
                    }
                }
                .accessibilityLabel(Text("Profile"))
            RoundIconButton(symbol: "gearshape", size: chip) { model.showSettings = true }
                .accessibilityLabel(Text("Settings"))
        }
    }

    private var dailyCard: some View {
        let item = LibraryCatalog.dailyItem()
        let solvedToday = model.stats.dailySolvedToday
        let streak = model.stats.streak
        let thumbnail = LibraryThumbnail(item: item, longSide: 640)
            .washed()
            .overlay { LatticeOverlay(columns: 6, rows: 4, opacity: 0.5) }
            .frame(width: isCompact ? nil : 216, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        let copy = VStack(alignment: .leading, spacing: 6) {
            Tag(text: String(localized: "Daily puzzle"), symbol: "sparkles", style: .sage)
            Text(item.title)
                .font(Theme.display(28))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 4)
            Text(streak > 0 ? "\(LibraryCatalog.dailyPieces) pieces · \(streak)-day streak"
                            : "\(LibraryCatalog.dailyPieces) pieces")
                .font(Theme.body(15))
                .foregroundStyle(Theme.muted)
            // The week: one dot per day of the streak, the next one dashed.
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    if day < min(streak, 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 22, height: 22)
                            .background(Theme.accent, in: Circle())
                    } else {
                        Circle().strokeBorder(Theme.track, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                            .frame(width: 22, height: 22)
                    }
                }
            }
            .padding(.top, 8)
            .accessibilityHidden(true)
        }
        let button = PillButton(title: solvedToday ? "Play again" : "Play",
                                symbol: solvedToday ? "checkmark" : "play.fill",
                                style: solvedToday ? .sage : .primary, expand: isCompact) {
            model.startDaily()
        }

        return Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 16) {
                    thumbnail
                    copy
                    button
                }
            } else {
                HStack(spacing: 22) {
                    thumbnail
                    copy
                    Spacer(minLength: 0)
                    button
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                Theme.surface
                Blob(color: Theme.blob2, size: 220).opacity(0.7).offset(x: 70, y: -70)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
        .padding(.horizontal, gutter)
        .accessibilityElement(children: .contain)
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Continue").font(Theme.display(22))
                Text("\(model.resumable.count) saved games")
                    .font(Theme.body(14)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(model.resumable) { snapshot in
                        ResumeCard(snapshot: snapshot) {
                            model.resume(snapshot)
                        } onDelete: {
                            model.delete(snapshot)
                        }
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.bottom, 6)
            }
        }
    }

    private var sectionTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(category?.title ?? String(localized: "All pictures"))
                .font(Theme.display(22))
            Text("\(items.filter { solvedTime(for: $0) != nil }.count) of \(items.count) solved")
                .font(Theme.body(14)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, gutter)
        .padding(.bottom, -8)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                chip(title: "\(String(localized: "All")) \(model.library.items(in: nil).count)",
                     symbol: "square.grid.2x2.fill", value: nil)
                ForEach(ArtCategory.allCases) { candidate in
                    chip(title: candidate.title, symbol: nil, value: candidate)
                }
            }
            .padding(.horizontal, gutter)
            .padding(.vertical, 14)
        }
        .background(Theme.bg)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }

    private func chip(title: String, symbol: String?, value: ArtCategory?) -> some View {
        let selected = category == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { category = value }
        } label: {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .bold)) }
                Text(title)
            }
            .font(Theme.body(15, selected ? .bold : .semibold))
            .foregroundStyle(selected ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(selected ? Theme.accent : Theme.chip, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func contextMenu(for item: LibraryItem) -> some View {
        Button { model.openSetup(for: item) } label: { Label("Start Puzzle", systemImage: "play") }
        if item.isUserPhoto {
            Button(role: .destructive) {
                model.library.delete(item)
            } label: {
                Label("Delete Photo", systemImage: "trash")
            }
        }
    }

    // MARK: - Import

    private func importPhotos(_ selection: [PhotosPickerItem]) async {
        isImporting = true
        defer {
            isImporting = false
            photoSelection = []
        }
        for entry in selection {
            do {
                guard let data = try await entry.loadTransferable(type: Data.self) else { continue }
                if model.library.importPhoto(data: data, suggestedTitle: nil) == nil {
                    importError = model.library.lastError
                        ?? String(localized: "This image format is not supported.")
                }
            } catch {
                importError = error.localizedDescription
            }
        }
        category = .mine
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            for url in urls where model.library.importPhoto(url: url) == nil {
                importError = model.library.lastError
                    ?? String(localized: "This image format is not supported.")
            }
            category = .mine
        case let .failure(error):
            importError = error.localizedDescription
        }
    }
}

// MARK: - Cards

private struct PictureCard: View {
    let item: LibraryItem
    /// Elapsed time of a finished game with this picture, if any.
    let solved: TimeInterval?
    /// Piece count of an unfinished saved game, if any.
    let inProgress: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                LibraryThumbnail(item: item)
                    .washed()
                    .aspectRatio(3.0 / 2.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) { badge.padding(10) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(Theme.body(17, .bold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(item.category.title)
                        Circle().fill(Theme.track).frame(width: 4, height: 4)
                        if let solved {
                            Text(TimeFormatting.clock(solved)).monospacedDigit()
                        } else {
                            Text("not solved")
                        }
                    }
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
            }
            .foregroundStyle(Theme.text)
            .card()
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(item.title))
        .accessibilityHint(Text("Opens puzzle options"))
    }

    @ViewBuilder
    private var badge: some View {
        if solved != nil {
            Tag(text: String(localized: "Solved"), style: .sage)
        } else if let inProgress {
            Tag(text: String(localized: "\(inProgress) pieces"), style: .card)
        }
    }
}

private struct ResumeCard: View {
    let snapshot: GameSnapshot
    let action: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LibraryThumbnail(item: snapshot.libraryItem, longSide: 220)
                    .washed()
                    .frame(width: 96, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.itemTitle)
                        .font(Theme.body(17, .bold))
                        .lineLimit(1)
                    Text("\(snapshot.pieceCount) pieces · \(TimeFormatting.clock(snapshot.elapsed))")
                        .font(Theme.body(13).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                    ProgressBar(value: Double(snapshot.state.placedCount) / Double(max(1, snapshot.pieceCount)))
                        .padding(.top, 7)
                }
                .frame(width: 150, alignment: .leading)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent, in: Circle())
            }
            .foregroundStyle(Theme.text)
            .padding(12)
            .card()
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Saved Game", systemImage: "trash")
            }
        }
    }
}
