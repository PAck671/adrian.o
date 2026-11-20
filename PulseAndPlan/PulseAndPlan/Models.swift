import Foundation
import CoreLocation
import SwiftUI

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var deviceId = UUID()
    var myName = "You"
    var partnerName = "Partner"
    var myAvatar = "🦊"
    var partnerAvatar = "🐼"
    var coupleCode = ""
    var myTimeZone = TimeZone.current.identifier
    var partnerTimeZone = "Asia/Tokyo"
    var useMiles = Locale.current.measurementSystem == .us
    var tmdbKey = ""
    var precision: PrecisionMode = .live
    var sharingEnabled = false
    var partnerPhone = ""
    var alertPulses = true
    var alertBattery = true
    var alertArrivals = true
    var alertNearby = true
    var stayConnected = false
    var services: [String] = []
    var syncCalendar = false
    var alertPrivacy = true      // partner goes Ghost / turns Location Services off
    var shareActivity = true     // send sitting / walking / driving… with my location
}

// MARK: - Activity (what the phone's sensors suggest you're doing)

enum PartnerActivity: String, Codable, CaseIterable {
    case sitting, onPhone, lyingDown, phoneDown, walking, running, cycling, driving, train, flying
    var label: String {
        switch self {
        case .sitting: "Sitting"
        case .onPhone: "On their phone"
        case .lyingDown: "Lying down"
        case .phoneDown: "Phone set down"
        case .walking: "Walking"
        case .running: "Running"
        case .cycling: "Cycling"
        case .driving: "In a car"
        case .train: "On a train"
        case .flying: "Flying"
        }
    }
    var emoji: String {
        switch self {
        case .sitting: "🪑"
        case .onPhone: "📱"
        case .lyingDown: "🛌"
        case .phoneDown: "📵"
        case .walking: "🚶"
        case .running: "🏃"
        case .cycling: "🚴"
        case .driving: "🚗"
        case .train: "🚄"
        case .flying: "✈️"
        }
    }
    var isMoving: Bool { [.walking, .running, .cycling, .driving, .train, .flying].contains(self) }
}

func formatSpeed(_ metersPerSecond: Double, miles: Bool) -> String {
    let value = metersPerSecond * (miles ? 2.236_94 : 3.6)
    return "\(Int(value.rounded())) \(miles ? "mph" : "km/h")"
}

// MARK: - Streaming services

/// Services you subscribe to. None of them expose personal watch history, so we match availability via TMDB.
enum StreamingService: String, Codable, CaseIterable, Identifiable {
    case netflix, hboMax, disney, hulu, prime, appleTV, peacock, paramount, youtube
    var id: String { rawValue }
    var label: String {
        switch self {
        case .netflix: "Netflix"
        case .hboMax: "HBO Max"
        case .disney: "Disney+"
        case .hulu: "Hulu"
        case .prime: "Prime Video"
        case .appleTV: "Apple TV+"
        case .peacock: "Peacock"
        case .paramount: "Paramount+"
        case .youtube: "YouTube"
        }
    }
    /// Catalog tags that count as this service (the built-in catalog predates the HBO Max rename).
    var catalogTags: [String] { self == .hboMax ? ["HBO Max", "Max"] : [label] }
    /// Names TMDB uses in its watch-provider list.
    var tmdbNames: [String] {
        switch self {
        case .netflix: ["Netflix"]
        case .hboMax: ["HBO Max", "Max"]
        case .disney: ["Disney Plus"]
        case .hulu: ["Hulu"]
        case .prime: ["Amazon Prime Video"]
        case .appleTV: ["Apple TV Plus", "Apple TV+", "Apple TV"]
        case .peacock: ["Peacock", "Peacock Premium"]
        case .paramount: ["Paramount Plus", "Paramount+"]
        case .youtube: ["YouTube", "YouTube Premium"]
        }
    }
    func searchURL(for title: String) -> URL? {
        let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        switch self {
        case .netflix: return URL(string: "https://www.netflix.com/search?q=\(q)")
        case .hulu: return URL(string: "https://www.hulu.com/search?q=\(q)")
        case .youtube: return URL(string: "https://www.youtube.com/results?search_query=\(q)")
        case .prime: return URL(string: "https://www.amazon.com/s?k=\(q)&i=instant-video")
        case .appleTV: return URL(string: "https://tv.apple.com/search?term=\(q)")
        // shortcut: these services have no stable public search URL; JustWatch links into their apps. Swap in a direct URL if one is published.
        case .hboMax, .disney, .peacock, .paramount: return URL(string: "https://www.justwatch.com/us/search?q=\(q)")
        }
    }
}

// MARK: - Notices & notes

enum NoticeKind: String, Codable {
    case onMyWay, custom
}

/// One-off heads-up from your partner ("On my way · 18 min").
struct PartnerNotice: Identifiable, Codable, Hashable {
    var id = UUID()
    var senderId: UUID
    var kind: NoticeKind
    var text: String
    var sentAt = Date()
}

enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case yellow, pink, mint, sky, lilac
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .yellow: Color(red: 1, green: 0.86, blue: 0.4)
        case .pink: Color(red: 1, green: 0.62, blue: 0.75)
        case .mint: Color(red: 0.55, green: 0.92, blue: 0.75)
        case .sky: Color(red: 0.56, green: 0.8, blue: 1)
        case .lilac: Color(red: 0.8, green: 0.7, blue: 1)
        }
    }
}

struct SharedNote: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var color: NoteColor = .yellow
    var pinned = false
    var authorId: UUID
    var updatedAt = Date()
}

// MARK: - Pulses

enum PulsePattern: String, Codable, CaseIterable, Identifiable {
    case tap, hold, heartbeat, doubleSqueeze, morseTap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tap: "Tap"
        case .hold: "Hold"
        case .heartbeat: "Heartbeat"
        case .doubleSqueeze: "Double Squeeze"
        case .morseTap: "Morse ILY"
        }
    }
    var symbol: String {
        switch self {
        case .tap: "hand.tap.fill"
        case .hold: "hand.raised.fill"
        case .heartbeat: "heart.fill"
        case .doubleSqueeze: "hands.clap.fill"
        case .morseTap: "ellipsis.message.fill"
        }
    }
}

struct Pulse: Identifiable, Codable, Hashable {
    var id = UUID()
    var senderId: UUID
    var pattern: PulsePattern
    var duration: Double = 0
    var sentAt = Date()
}

// MARK: - Videos

struct VideoClip: Identifiable, Codable, Hashable {
    var id = UUID()
    var senderId: UUID
    var localName: String?      // file in Documents/Clips (survives container path changes)
    var remoteURL: URL?
    var createdAt = Date()
    var duration: Double
    var reaction: String?

    static var directory: URL {
        let dir = URL.documentsDirectory.appending(path: "Clips", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var playbackURL: URL? {
        if let localName { return Self.directory.appending(path: localName) }
        return remoteURL
    }
}

// MARK: - Location

enum PrecisionMode: String, Codable, CaseIterable, Identifiable {
    case live, fuzzy, ghost
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .live: "location.fill"
        case .fuzzy: "circle.dashed"
        case .ghost: "eye.slash.fill"
        }
    }
}

struct LocationShare: Codable, Equatable {
    var userId: UUID
    var lat: Double?
    var lng: Double?
    var precision: PrecisionMode
    var battery: Int?
    var placeLabel: String?
    var city: String?
    var updatedAt = Date()
    var activity: PartnerActivity?
    var speed: Double?           // m/s, Live mode only
    var locationOff: Bool?       // Location Services were switched off on their phone
    var course: Double?          // degrees from north, Live mode only
    var accuracy: Double?        // meters (horizontal), Live mode only

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

struct SavedPlace: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var lat: Double
    var lng: Double
    var radius: Double = 150

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

extension CLLocationCoordinate2D {
    /// Snaps to a ~3 km grid. A fixed grid (not random jitter) can't be averaged back to the true spot.
    func fuzzed(step: Double = 0.03) -> CLLocationCoordinate2D {
        .init(latitude: (latitude / step).rounded() * step, longitude: (longitude / step).rounded() * step)
    }
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

func formatDistance(_ meters: CLLocationDistance, miles: Bool) -> String {
    let value = miles ? meters / 1609.344 : meters / 1000
    return value < 10 ? String(format: "%.1f %@", value, miles ? "mi" : "km")
                      : "\(Int(value).formatted()) \(miles ? "mi" : "km")"
}

// MARK: - Movies

struct MovieSwipe: Codable, Hashable {
    var userId: UUID
    var movieId: Int
    var liked: Bool
}

// MARK: - Calendar

enum EventKind: String, Codable, CaseIterable, Identifiable {
    case event, dateNight, busy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .event: "Event"
        case .dateNight: "Date Night"
        case .busy: "Busy"
        }
    }
    var color: Color {
        switch self {
        case .event: .blue
        case .dateNight: .pink
        case .busy: .orange
        }
    }
}

struct SharedEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var kind: EventKind
    var start: Date
    var end: Date
    var createdBy: UUID
    var fromCalendar: Bool?   // imported busy block from the device calendar (title is always just "Busy")
}

enum VisitTheme: String, Codable, CaseIterable, Identifiable {
    case sunset, ocean, forest, rose
    var id: String { rawValue }
    var colors: [Color] {
        switch self {
        case .sunset: [.orange, .pink]
        case .ocean: [.cyan, .indigo]
        case .forest: [.green, .teal]
        case .rose: [.pink, .purple]
        }
    }
}

struct Visit: Codable, Equatable {
    var date = Date().addingTimeInterval(86_400 * 23)
    var destination = "Tokyo"
    var theme: VisitTheme = .sunset
}

// MARK: - Games

enum GameKind: String, Codable, CaseIterable, Identifiable {
    case circuit, labyrinth, seaBattle, fourInRow, blockDrop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circuit: "Circuit Defusal"
        case .labyrinth: "Blind Labyrinth"
        case .seaBattle: "Sea Battle"
        case .fourInRow: "Four in a Row"
        case .blockDrop: "Block Drop Duel"
        }
    }
    var symbol: String {
        switch self {
        case .circuit: "bolt.circle.fill"
        case .labyrinth: "square.grid.3x3.fill"
        case .seaBattle: "sailboat.fill"
        case .fourInRow: "circle.grid.3x3.fill"
        case .blockDrop: "square.stack.3d.down.right.fill"
        }
    }
    var blurb: String {
        switch self {
        case .circuit: "Asymmetric: one sees the bomb, one has the manual."
        case .labyrinth: "Asymmetric: one walks blind, one sees the map."
        case .seaBattle: "Take turns firing at each other's hidden fleet."
        case .fourInRow: "Drop discs and connect four first."
        case .blockDrop: "Same falling pieces for both of you. Highest score wins."
        }
    }
}

enum GameRole: String, CaseIterable, Identifiable {
    case a, b
    var id: String { rawValue }
}

/// Shared progress for a game room. The puzzle itself is never sent: both phones rebuild it from the code.
struct GameState: Codable, Equatable {
    var code: String
    var game: GameKind
    var position = 0
    var solved: Set<Int> = []
    var strikes = 0
    var switchOn = false
    var moves: [Int] = []              // turn-based games: every move in order (A moves first)
    var scores: [String: Int] = [:]    // keyed by GameRole.rawValue
    var finished: [String] = []        // roles whose Block Drop board topped out
    var updatedBy: UUID
}

// MARK: - Sync

enum SyncEvent {
    case pulse(Pulse)
    case video(VideoClip)
    case swipe(MovieSwipe)
    case location(LocationShare)
    case eventUpserted(SharedEvent)
    case eventDeleted(UUID)
    case game(GameState)
    case visit(Visit)
    case presence(online: Bool)
    case status(String)
    case notice(PartnerNotice)
    case noteUpserted(SharedNote)
    case noteDeleted(UUID)
    case profile(userId: UUID, avatarURL: URL)
}

// MARK: - Persistence

enum Persist {
    static func load<T: Codable>(_ key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        return decode(data, default: value)
    }

    /// Saves from an older app version lack newer fields; overlay what was saved onto the defaults
    /// instead of throwing everything away (which would also reset the device id).
    static func decode<T: Codable>(_ data: Data, default value: T) -> T {
        if let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(saved) { _, new in new }),
              let decoded = try? JSONDecoder().decode(T.self, from: merged) else { return value }
        return decoded
    }
    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
