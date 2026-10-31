// Creates the medal achievements of `docs/gamecenter/medals.json` in App Store
// Connect through its API (v2 Game Center endpoints): the achievement with its
// version, a localization per language, and the badge on every localization.
// Safe to run again: what already exists is left alone, what is missing is
// added, so an interrupted run just continues.
//
//   ASC_ISSUER=<issuer id> ASC_KEY_ID=<key id> ASC_KEY=<path to AuthKey_….p8> \
//     swift Scripts/upload-gamecenter-medals.swift [--dry-run]
//
// The key comes from App Store Connect → Users and Access → Integrations →
// App Store Connect API (App Manager access is enough). It is read from disk
// and never printed. New achievements still have to be added to the app
// version under review in App Store Connect before they go live.

import CryptoKit
import Foundation

let bundleID = "com.kirillrychkov.SashasPuzzle"
let api = URL(string: "https://api.appstoreconnect.apple.com")!
let dryRun = CommandLine.arguments.contains("--dry-run")

struct Localization: Decodable { let name: String; let beforeEarnedDescription: String; let afterEarnedDescription: String }
struct Medal: Decodable {
    let vendorIdentifier: String, referenceName: String, points: Int
    let showBeforeEarned: Bool, repeatable: Bool, image: String
    let localizations: [String: Localization]
}

let medals = try JSONDecoder().decode([Medal].self, from: Data(contentsOf: URL(fileURLWithPath: "docs/gamecenter/medals.json")))
print("\(medals.count) medals, \(medals.reduce(0) { $0 + $1.localizations.count }) localizations in docs/gamecenter/medals.json")
for medal in medals where !FileManager.default.fileExists(atPath: medal.image) {
    fatalError("missing badge \(medal.image): run swift Scripts/make-achievement-badges.swift . docs/gamecenter")
}

// MARK: - Token

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func token() throws -> String {
    let env = ProcessInfo.processInfo.environment
    guard let issuer = env["ASC_ISSUER"], let keyID = env["ASC_KEY_ID"], let path = env["ASC_KEY"] else {
        fatalError("set ASC_ISSUER, ASC_KEY_ID and ASC_KEY")
    }
    let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: path, encoding: .utf8))
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let now = Int(Date().timeIntervalSince1970)
    let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 15 * 60,
                                                            "aud": "appstoreconnect-v1"])
    let input = base64URL(header) + "." + base64URL(claims)
    let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
    return input + "." + base64URL(signature)
}

// MARK: - Requests

var bearer = ""
var bearerMade = Date.distantPast

@discardableResult
func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
    if Date().timeIntervalSince(bearerMade) > 10 * 60 { bearer = try token(); bearerMade = Date() }
    var request = URLRequest(url: URL(string: path, relativeTo: api)!)
    request.httpMethod = method
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as! HTTPURLResponse).statusCode
    guard (200..<300).contains(status) else {
        fatalError("\(method) \(path) → \(status)\n\(String(decoding: data, as: UTF8.self))")
    }
    return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
}

/// Every resource of a list, following `links.next`.
func list(_ path: String) async throws -> [[String: Any]] {
    var all: [[String: Any]] = [], next: String? = path
    while let page = next {
        let json = try await call("GET", page)
        all += json["data"] as? [[String: Any]] ?? []
        next = (json["links"] as? [String: Any])?["next"] as? String
    }
    return all
}

func attributes(_ resource: [String: Any]) -> [String: Any] { resource["attributes"] as? [String: Any] ?? [:] }
func id(_ resource: [String: Any]) -> String { resource["id"] as! String }

// MARK: - Run

guard !dryRun else {
    for medal in medals { print("would create \(medal.vendorIdentifier): \(medal.localizations["en-US"]?.name ?? "")") }
    exit(0)
}

guard let app = try await list("/v1/apps?filter[bundleId]=\(bundleID)").first else { fatalError("no app \(bundleID)") }
let detail = try await call("GET", "/v1/apps/\(id(app))/gameCenterDetail")["data"] as! [String: Any]
if let group = ((detail["relationships"] as? [String: Any])?["gameCenterGroup"] as? [String: Any])?["data"] as? [String: Any] {
    fatalError("the app's Game Center lives in group \(group["id"] ?? ""): add the achievements to the group instead")
}
print("app \(id(app)), Game Center detail \(id(detail))")

let existing = try await list("/v1/gameCenterDetails/\(id(detail))/gameCenterAchievementsV2?limit=200")
var byVendor = Dictionary(uniqueKeysWithValues: existing.map { (attributes($0)["vendorIdentifier"] as! String, $0) })
print("\(existing.count) achievements already there")

for medal in medals {
    var achievement = byVendor[medal.vendorIdentifier]
    if achievement == nil {
        let created = try await call("POST", "/v2/gameCenterAchievements", [
            "data": [
                "type": "gameCenterAchievements",
                "attributes": ["referenceName": medal.referenceName, "vendorIdentifier": medal.vendorIdentifier,
                               "points": medal.points, "showBeforeEarned": medal.showBeforeEarned,
                               "repeatable": medal.repeatable],
                "relationships": [
                    "gameCenterDetail": ["data": ["type": "gameCenterDetails", "id": id(detail)]],
                    "versions": ["data": [["type": "gameCenterAchievementVersions", "id": "${version}"]]],
                ],
            ],
            "included": [["type": "gameCenterAchievementVersions", "id": "${version}"]],
        ])
        achievement = created["data"] as? [String: Any]
        byVendor[medal.vendorIdentifier] = achievement
        print("+ \(medal.vendorIdentifier)")
    }
    guard let achievement else { continue }
    // The newest version is the one still being edited.
    guard let version = try await list("/v2/gameCenterAchievements/\(id(achievement))/versions").last else {
        fatalError("\(medal.vendorIdentifier) has no version")
    }
    let localizations = try await list("/v2/gameCenterAchievementVersions/\(id(version))/localizations")
    var byLocale = Dictionary(uniqueKeysWithValues: localizations.map { (attributes($0)["locale"] as! String, $0) })
    for (locale, text) in medal.localizations.sorted(by: { $0.key < $1.key }) {
        if byLocale[locale] == nil {
            let created = try await call("POST", "/v2/gameCenterAchievementLocalizations", [
                "data": [
                    "type": "gameCenterAchievementLocalizations",
                    "attributes": ["locale": locale, "name": text.name,
                                   "beforeEarnedDescription": text.beforeEarnedDescription,
                                   "afterEarnedDescription": text.afterEarnedDescription],
                    "relationships": ["version": ["data": ["type": "gameCenterAchievementVersions", "id": id(version)]]],
                ],
            ])
            byLocale[locale] = created["data"] as? [String: Any]
            print("  + \(locale)")
        }
        guard let localization = byLocale[locale] else { continue }
        let image = try await call("GET", "/v2/gameCenterAchievementLocalizations/\(id(localization))/image")["data"]
        if image is [String: Any] { continue }
        let file = try Data(contentsOf: URL(fileURLWithPath: medal.image))
        let reserved = try await call("POST", "/v2/gameCenterAchievementImages", [
            "data": [
                "type": "gameCenterAchievementImages",
                "attributes": ["fileSize": file.count, "fileName": (medal.image as NSString).lastPathComponent],
                "relationships": ["localization": ["data": ["type": "gameCenterAchievementLocalizations",
                                                            "id": id(localization)]]],
            ],
        ])["data"] as! [String: Any]
        for operation in attributes(reserved)["uploadOperations"] as? [[String: Any]] ?? [] {
            var put = URLRequest(url: URL(string: operation["url"] as! String)!)
            put.httpMethod = operation["method"] as? String ?? "PUT"
            for header in operation["requestHeaders"] as? [[String: String]] ?? [] {
                put.setValue(header["value"], forHTTPHeaderField: header["name"] ?? "")
            }
            let offset = operation["offset"] as? Int ?? 0, length = operation["length"] as? Int ?? file.count
            let (_, response) = try await URLSession.shared.upload(for: put, from: file.subdata(in: offset..<offset + length))
            guard (200..<300).contains((response as! HTTPURLResponse).statusCode) else {
                fatalError("upload of \(medal.image) failed")
            }
        }
        try await call("PATCH", "/v2/gameCenterAchievementImages/\(id(reserved))", [
            "data": ["type": "gameCenterAchievementImages", "id": id(reserved), "attributes": ["uploaded": true]],
        ])
        print("  ↑ \(locale) image")
    }
}
print("done: \(medals.count) medals. Add them to the version under review in App Store Connect → Game Center.")
