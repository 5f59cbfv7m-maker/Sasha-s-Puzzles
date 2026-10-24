import SwiftUI

/// "Play together". In a game it opens the table to players nearby and
/// invites Game Center friends; in the library it lists the tables nearby.
struct TogetherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Play Together").font(Theme.display(28))
                Spacer()
                PillButton(title: "Done", size: 15) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(EdgeInsets(top: 26, leading: 26, bottom: 18, trailing: 26))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Everyone puts together the same puzzle on their own device and sees where the others put their pieces. Up to four players.")
                        .font(Theme.body(15)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let table = model.table, table.isTogether || !table.isHost { players(table) }
                    if model.session != nil, model.table?.isHost != false { hosting } else if model.table == nil { joining }
                }
                .padding(EdgeInsets(top: 0, leading: 26, bottom: 26, trailing: 26))
            }
        }
        .background(Theme.surface)
        .foregroundStyle(Theme.text)
        .onAppear { if model.session == nil { model.browseNearby() } }
        .onDisappear { model.stopBrowsing() }
    }

    // MARK: - Host

    @ViewBuilder
    private var hosting: some View {
        if !model.canShareTable {
            card {
                Label("Only pictures from the library can be shared: the others do not have your photos.",
                      systemImage: "photo")
                    .font(Theme.body(15))
            }
        } else {
            section("Nearby", "Family and friends in the same room, over Wi-Fi or Bluetooth. No account needed.") {
                if model.nearbyHost != nil {
                    Label("The table is open. On the other device, tap the two figures in the library.",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(Theme.body(15, .semibold)).foregroundStyle(Theme.onSageTint)
                } else {
                    PillButton(title: "Open the Table", symbol: "dot.radiowaves.left.and.right", size: 16) {
                        model.openTableNearby()
                    }
                }
            }
            section("Game Center", "Invite friends anywhere. Each player needs their own Apple Account.") {
                if model.gameCenter.isSignedIn {
                    PillButton(title: "Invite Friends", symbol: "envelope.fill", style: .secondary, size: 16) {
                        model.inviteFriends()
                    }
                } else if model.gameCenter.needsSignIn {
                    PillButton(title: "Sign in to Game Center", style: .secondary, size: 16) {
                        dismiss()
                        model.gameCenter.presentSignIn()
                    }
                } else {
                    Text("Sign in to Game Center in Settings to invite friends.")
                        .font(Theme.body(14)).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    // MARK: - Guest

    private var joining: some View {
        section("Tables nearby", "Ask the other player to open the table in their game.") {
            let tables = model.nearby?.tables ?? []
            if tables.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for tables…").font(Theme.body(15)).foregroundStyle(Theme.muted)
                }
            }
            ForEach(tables) { table in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.host).font(Theme.body(16, .bold)).lineLimit(1)
                        Text("\(table.title) · \(table.pieces) pieces")
                            .font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    PillButton(title: "Join", size: 15) { model.join(table) }
                }
            }
            Text("Invitations from Game Center friends arrive as a notification.")
                .font(Theme.body(13)).foregroundStyle(Theme.faint)
        }
    }

    // MARK: - Pieces

    private func players(_ table: SharedTable) -> some View {
        section("At the table", nil) {
            if table.players.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Sitting down…").font(Theme.body(15)).foregroundStyle(Theme.muted)
                }
            }
            ForEach(table.players.filter(\.isHere)) { player in
                HStack(spacing: 10) {
                    Circle().fill(Theme.player(player.slot)).frame(width: 14, height: 14)
                    (player.id == table.me ? Text("\(player.name) (you)") : Text(player.name))
                        .font(Theme.body(16, .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(table.pieces(of: player))").font(Theme.body(15, .bold).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, _ note: LocalizedStringKey?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: title).padding(.horizontal, 12)
            card {
                if let note {
                    Text(note).font(Theme.body(14)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Who is at the table and how many pieces each has joined, over the board.
struct TableRoster: View {
    let table: SharedTable

    var body: some View {
        Group {
            if let reason = table.endReason {
                Label(reason == .hostLeft ? LocalizedStringKey("The host left. The puzzle is yours to finish.")
                                          : LocalizedStringKey("Update the app to play at this table."),
                      systemImage: "person.2.slash")
            } else if table.isTogether {
                HStack(spacing: 12) {
                    ForEach(table.players.filter(\.isHere)) { player in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.player(player.slot)).frame(width: 10, height: 10)
                            Text(player.name).lineLimit(1)
                            Text("\(table.pieces(of: player))").monospacedDigit().foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
        .font(Theme.body(13, .bold))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.card.opacity(0.94), in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
        .opacity(table.endReason != nil || table.isTogether ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// The completion card's line for a shared puzzle: everyone's pieces.
struct TableTally: View {
    let table: SharedTable

    var body: some View {
        let players = table.players.sorted { table.pieces(of: $0) > table.pieces(of: $1) }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { tally(players) }
            VStack(alignment: .leading, spacing: 6) { tally(players) }
        }
        .font(Theme.body(15, .bold))
    }

    private func tally(_ players: [TablePlayer]) -> some View {
        ForEach(players) { player in
            HStack(spacing: 6) {
                Circle().fill(Theme.player(player.slot)).frame(width: 11, height: 11)
                Text(player.name).lineLimit(1)
                Text("\(table.pieces(of: player))").monospacedDigit().foregroundStyle(Theme.muted)
            }
        }
    }
}
