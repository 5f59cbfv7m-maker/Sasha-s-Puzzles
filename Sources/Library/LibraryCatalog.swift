import Foundation

/// Builds the built-in picture library.
nonisolated enum LibraryCatalog {

    static var count: Int { items.count }

    /// The daily puzzle is always played at this size.
    static let dailyPieces = 150

    /// One built-in picture per calendar day. Past days must keep the picture
    /// they had: a solved record counts as a daily only while it still matches,
    /// so a reshuffled rotation would break every streak. Days before
    /// `newPicturesFrom` therefore rotate over the 1.1 library only.
    static func dailyItem(on date: Date = .now) -> LibraryItem {
        let day = gregorian.ordinality(of: .day, in: .era, for: date) ?? 0
        let pool = date < newPicturesFrom ? legacyItems : dailyPool
        return pool[day % pool.count]
    }

    /// Set safely after 1.2 reaches the App Store: until then a 1.1 device and
    /// a 1.2 device in the same family show the same daily picture.
    static let newPicturesFrom = DateComponents(calendar: gregorian, year: 2026, month: 12, day: 1).date!

    /// Not `Calendar.current`: a Thai phone counts Buddhist years, where 2026
    /// is long past, and its era-day count would pick another daily picture
    /// than the rest of the family. The time zone is still the player's own.
    private static var gregorian: Calendar { Calendar(identifier: .gregorian) }

    /// The pictures 1.2 added, locked until the player has the points. Four
    /// open at each threshold, one from each of four categories; every other
    /// bundled picture was in 1.1 and is always open.
    static let rewardOrder: [String] = [
        "bundled.animals_Red Panda", "bundled.city_Blue Domes of Santorini",
        "bundled.nature_Sunflowers at Sunset", "bundled.sea_Sea Turtle",
        "bundled.mountains_Fuji in Blossom", "bundled.space_Earth and the Space Station",
        "bundled.abstract_Tangle of Yarn", "bundled.animals_King Penguins",
        "bundled.city_Canals of Burano", "bundled.nature_Blue Hydrangeas",
        "bundled.sea_Moon Jellyfish", "bundled.mountains_Moraine Lake",
        "bundled.space_City Lights from Orbit", "bundled.abstract_Red and Yellow Doors",
        "bundled.animals_Hummingbird", "bundled.city_Hallstatt by the Lake",
        "bundled.nature_Poppies at Dusk", "bundled.sea_Water Villas",
        "bundled.mountains_Matterhorn at Sunrise", "bundled.space_Violet Milky Way",
        "bundled.abstract_Rose Window", "bundled.animals_Elephant on the Savanna",
        "bundled.city_Lisbon Tram", "bundled.nature_Rice Terraces",
        "bundled.sea_Sea Stacks at Sunset", "bundled.mountains_Lofoten Fishing Village",
        "bundled.space_Milky Way over the Rocks", "bundled.abstract_Vegetable Market",
    ]
    static let rewardThresholds = [300, 1_000, 2_500, 5_000, 8_000, 12_000, 18_000]

    /// The secret pictures, one for every seven daily puzzles in a row, in
    /// this order. Hidden until then and never a daily puzzle themselves.
    static let secretOrder: [String] = [
        "bundled.secret_Fairytale Castle",
        "bundled.secret_Red-eyed Tree Frog",
        "bundled.secret_Glowing Shore",
        "bundled.secret_Peacock Feathers",
        "bundled.secret_Aurora over the Cabin",
        "bundled.secret_Sleeping Fennec",
        "bundled.secret_Frozen Bubble",
        "bundled.secret_Snowy Owl",
        "bundled.secret_Sky Lanterns",
        "bundled.secret_Lion and Cub",
        "bundled.secret_Blue Ice Cave",
        "bundled.secret_Mandarin Duck",
        "bundled.secret_Glowworm Cave",
        "bundled.secret_Snow Leopard",
        "bundled.secret_Fireflies and Stars",
        "bundled.secret_Polar Bear Underwater",
        "bundled.secret_Castle in the Mist",
        "bundled.secret_Arctic Fox",
        "bundled.secret_Antelope Canyon",
        "bundled.secret_Swans in Love",
        "bundled.secret_Mushroom Glade",
        "bundled.secret_Sunbeams in the Forest",
    ]
    static let addedIn1_2 = Set(rewardOrder)

    /// Points a picture needs, or nil for one that is always open.
    static func requiredPoints(for id: String) -> Int? {
        rewardOrder.firstIndex(of: id).map { rewardThresholds[$0 / 4] }
    }

    /// The next threshold above `points`, if any picture is still locked.
    static func nextThreshold(after points: Int) -> Int? {
        rewardThresholds.first { $0 > points }
    }

    /// The built-in pictures: the photographs in `Resources/Pictures/`. Nothing
    /// is decoded here — bundled files only have their header read — so the
    /// library screen appears instantly and the bitmaps are produced lazily as
    /// cells scroll into view.
    static func builtIn() -> [LibraryItem] { items }

    /// Built once: the list is pure, and the profile asks for it on every layout pass.
    private static let items: [LibraryItem] = bundled()
    static let dailyPool = items.filter { $0.category != .secret }
    static let legacyItems = dailyPool.filter { !addedIn1_2.contains($0.id) }

    /// Photographs dropped into `Resources/Pictures/`. The file name carries
    /// the metadata — `sea_Sunset Beach.jpg` is category `sea`, title
    /// "Sunset Beach" — and the title is looked up in the string catalog so it
    /// can be translated. Unparseable names are skipped, not crashed on.
    static func bundled(in bundle: Bundle = .main) -> [LibraryItem] {
        ["jpg", "jpeg", "png", "heic"]
            .flatMap { bundle.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
            .compactMap(bundledItem(at:))
            .sorted { $0.id < $1.id }
    }

    static func bundledItem(at url: URL) -> LibraryItem? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let split = stem.firstIndex(of: "_"),
              let category = ArtCategory(rawValue: String(stem[..<split])),
              let size = ImagePipeline.dimensions(url: url), size.height > 0
        else { return nil }
        let title = String(stem[stem.index(after: split)...])
        return LibraryItem(
            id: "bundled.\(stem)",
            title: String(localized: String.LocalizationValue(title)),
            category: category,
            source: .bundled(fileName: url.lastPathComponent),
            addedAt: .distantPast,
            aspect: size.width / size.height)
    }
}
