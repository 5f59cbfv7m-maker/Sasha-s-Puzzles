import CoreGraphics
import Foundation

/// Where a puzzle picture comes from.
nonisolated enum ImageSource: Sendable, Hashable, Codable {
    /// A photo the user imported; `fileName` lives in the app's library folder.
    case imported(fileName: String)
    /// A photograph shipped in the bundle from `Resources/Pictures/`.
    case bundled(fileName: String)

    var isUserPhoto: Bool { if case .imported = self { true } else { false } }
}

/// One entry in the photo library.
nonisolated struct LibraryItem: Identifiable, Sendable, Hashable, Codable {
    var id: String
    var title: String
    var category: ArtCategory
    var source: ImageSource
    var addedAt: Date
    /// Known aspect ratio (width / height); user photos record their real one.
    var aspect: CGFloat

    var isUserPhoto: Bool { source.isUserPhoto }
}

/// Coarse grouping used by the library's category filter.
nonisolated enum ArtCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case space, nature, mountains, sea, city, animals, abstract, secret, mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .space: String(localized: "Space")
        case .nature: String(localized: "Nature")
        case .mountains: String(localized: "Mountains")
        case .sea: String(localized: "Sea")
        case .city: String(localized: "City")
        case .animals: String(localized: "Animals")
        case .abstract: String(localized: "Abstract")
        case .secret: String(localized: "Secret")
        case .mine: String(localized: "My Photos")
        }
    }

    var symbol: String {
        switch self {
        case .space: "sparkles"
        case .nature: "tree"
        case .mountains: "mountain.2"
        case .sea: "water.waves"
        case .city: "building.2"
        case .animals: "bird"
        case .abstract: "paintpalette"
        case .secret: "gift"
        case .mine: "person.crop.square"
        }
    }
}
