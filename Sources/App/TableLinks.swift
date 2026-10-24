import Foundation
import GameKit
import MultipeerConnectivity
import Observation

/// Devices in the same room, over Wi-Fi or Bluetooth: no account and no
/// internet needed. The host advertises its table; a guest browses, picks
/// one and joins. Everyone at the table shares one `MCSession`.
@Observable
@MainActor
final class NearbyLink: NSObject, TableLink {
    /// Also listed in the Info.plist's `NSBonjourServices`, as `_sasha-puzzles._tcp` and `._udp`.
    nonisolated static let service = "sasha-puzzles"

    /// A table someone nearby has opened.
    nonisolated struct Table: Identifiable {
        let id: String
        let peer: MCPeerID
        var host: String
        var title: String
        var pieces: Int
    }
    private(set) var tables: [Table] = []

    @ObservationIgnored nonisolated(unsafe) private let me: MCPeerID
    @ObservationIgnored nonisolated(unsafe) private let session: MCSession
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var peers: [String: MCPeerID] = [:]
    @ObservationIgnored var onReceive: ((Data, String) -> Void)?
    @ObservationIgnored var onConnect: ((String) -> Void)?
    @ObservationIgnored var onDisconnect: ((String) -> Void)?

    init(name: String) {
        // The display name is capped at 63 bytes of UTF-8.
        var display = name
        while display.utf8.count > 60 { display.removeLast() }
        me = MCPeerID(displayName: display.isEmpty ? "Player" : display)
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    var isAdvertising: Bool { advertiser != nil }
    var connectedPeers: [String] { Array(peers.keys) }

    func advertise(title: String, pieces: Int) {
        guard advertiser == nil else { return }
        let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["title": String(title.prefix(60)),
                                                                             "pieces": "\(pieces)"],
                                                   serviceType: Self.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    func browse() {
        guard browser == nil else { return }
        let browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func join(_ table: Table) {
        browser?.invitePeer(table.peer, to: session, withContext: nil, timeout: 20)
    }

    func send(_ data: Data, to ids: [String], reliable: Bool) {
        let targets = ids.compactMap { peers[$0] }
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: reliable ? .reliable : .unreliable)
    }

    func close() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        peers = [:]
        tables = []
    }

    nonisolated private static func key(_ peer: MCPeerID) -> String { "\(peer.hash)" }

    private func changed(_ peer: MCPeerID, to state: MCSessionState) {
        let key = Self.key(peer)
        switch state {
        case .connected:
            peers[key] = peer
            onConnect?(key)
        case .notConnected:
            if peers.removeValue(forKey: key) != nil { onDisconnect?(key) }
        default:
            break
        }
    }
}

extension NearbyLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        nonisolated(unsafe) let peer = peerID
        Task { @MainActor in self.changed(peer, to: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let key = Self.key(peerID)
        Task { @MainActor in self.onReceive?(data, key) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}

extension NearbyLink: MCNearbyServiceAdvertiserDelegate {
    /// Anyone nearby may sit down, up to four at the table.
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(session.connectedPeers.count < SharedTable.maxPlayers - 1, session)
    }
}

extension NearbyLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        let table = Table(id: Self.key(peerID), peer: peerID, host: peerID.displayName,
                          title: info?["title"] ?? "", pieces: Int(info?["pieces"] ?? "") ?? 0)
        nonisolated(unsafe) let found = table
        Task { @MainActor in
            self.tables.removeAll { $0.id == found.id }
            self.tables.append(found)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let key = Self.key(peerID)
        Task { @MainActor in self.tables.removeAll { $0.id == key } }
    }
}

/// Friends anywhere, through a Game Center match. Each player needs their
/// own Game Center account; peers are `gamePlayerID`s.
@MainActor
final class MatchLink: NSObject, TableLink {
    nonisolated(unsafe) private let match: GKMatch
    var onReceive: ((Data, String) -> Void)?
    var onConnect: ((String) -> Void)?
    var onDisconnect: ((String) -> Void)?

    init(_ match: GKMatch) {
        self.match = match
        super.init()
        match.delegate = self
    }

    var connectedPeers: [String] { match.players.map(\.gamePlayerID) }

    func send(_ data: Data, to ids: [String], reliable: Bool) {
        let players = match.players.filter { ids.contains($0.gamePlayerID) }
        guard !players.isEmpty else { return }
        try? match.send(data, to: players, dataMode: reliable ? .reliable : .unreliable)
    }

    func close() {
        match.delegate = nil
        match.disconnect()
    }
}

extension MatchLink: GKMatchDelegate {
    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let id = player.gamePlayerID
        Task { @MainActor in self.onReceive?(data, id) }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let id = player.gamePlayerID
        Task { @MainActor in
            switch state {
            case .connected: self.onConnect?(id)
            case .disconnected: self.onDisconnect?(id)
            default: break
            }
        }
    }
}
