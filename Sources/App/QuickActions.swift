#if os(iOS)
import UIKit

/// The menu on a long press of the app icon: today's puzzle, the game left
/// open, a quick one, and playing together.
enum QuickAction: String {
    case daily, resume, quick, together

    /// An action that arrived while the app was still starting.
    @MainActor private static var pending: QuickAction?
    /// Set by `RootView` once the model is up; takes a pending action at once.
    @MainActor static var perform: ((QuickAction) -> Void)? {
        didSet {
            guard let perform, let pending else { return }
            self.pending = nil
            perform(pending)
        }
    }

    @MainActor static func received(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(rawValue: item.type) else { return false }
        if let perform { perform(action) } else { pending = action }
        return true
    }
}

/// SwiftUI has no hook for quick actions: a cold launch brings one in the
/// scene's connection options, a running app through the scene delegate.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { _ = QuickAction.received(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickAction.received(shortcutItem))
    }
}

extension AppModel {
    private var latestGame: GameSnapshot? { resumable.max { $0.updatedAt < $1.updatedAt } }

    /// Rebuilt each time the app goes to the background, so the menu names
    /// the game just left open.
    func refreshQuickActions() {
        let daily = LibraryCatalog.dailyItem()
        var items = [
            UIApplicationShortcutItem(type: QuickAction.daily.rawValue, localizedTitle: String(localized: "Daily puzzle"),
                                      localizedSubtitle: String(localized: "\(daily.title) · \(LibraryCatalog.dailyPieces) pieces"),
                                      icon: UIApplicationShortcutIcon(systemImageName: "sparkles")),
            UIApplicationShortcutItem(type: QuickAction.quick.rawValue, localizedTitle: String(localized: "Quick puzzle"),
                                      localizedSubtitle: String(localized: "\(Self.quickPieces) pieces, a random picture"),
                                      icon: UIApplicationShortcutIcon(systemImageName: "bolt.fill")),
            UIApplicationShortcutItem(type: QuickAction.together.rawValue, localizedTitle: String(localized: "Play Together"),
                                      localizedSubtitle: String(localized: "Find a table nearby"),
                                      icon: UIApplicationShortcutIcon(systemImageName: "person.2.fill")),
        ]
        if let game = latestGame {
            items.insert(UIApplicationShortcutItem(type: QuickAction.resume.rawValue, localizedTitle: String(localized: "Continue"),
                                                   localizedSubtitle: "\(game.itemTitle) · \(game.state.placedCount)/\(game.pieceCount)",
                                                   icon: UIApplicationShortcutIcon(systemImageName: "play.fill")), at: 0)
        }
        UIApplication.shared.shortcutItems = items
    }

    /// Like an activity from the Games app: settings or the profile go away,
    /// onboarding stays, and a game in progress is saved by `start`.
    func perform(_ action: QuickAction) {
        if sheet != .onboarding { sheet = nil }
        switch action {
        case .daily: startDaily()
        case .quick: startQuick()
        case .resume: if let game = latestGame { resume(game) }
        case .together:
            if session != nil { showLibrary() }
            if sheet == nil { sheet = .together }
        }
    }
}
#endif
