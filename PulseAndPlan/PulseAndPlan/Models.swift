import Foundation
import CoreLocation
import SwiftUI

// MARK: - Settings

enum SyncMode: String, Codable, CaseIterable, Identifiable {
    case demo, live
    var id: String { rawValue }
    var label: String { self == .demo ? "Demo / Solo Test" : "Live Pair (Supabase)" }
}

struct AppSettings: Codable, Equatable {
    var mode: SyncMode = .demo
    var deviceId = UUID()
    var myName = "Me"
    var partnerName = "Sam"
    var myAvatar = "🦊"
    var partnerAvatar = "🐼"
    var coupleCode = ""
    var myTimeZone = TimeZone.current.identifier
    var partnerTimeZone = "Asia/Tokyo"
    var demoCity = "Tokyo"
    var useMiles = Locale.current.measurementSystem == .us
    var tmdbKey = ""
    var precision: PrecisionMode = .live
    var sharingEnabled = false
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
    case circuit, labyrinth
    var id: String { rawValue }
    var label: String { self == .circuit ? "Circuit Defusal" : "Blind Labyrinth" }
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
}

// MARK: - Demo cities

struct DemoCity: Identifiable, Hashable {
    let name: String
    let lat: Double
    let lng: Double
    let timeZone: String
    var id: String { name }

    static let all: [DemoCity] = [
        .init(name: "Tokyo", lat: 35.6595, lng: 139.7005, timeZone: "Asia/Tokyo"),
        .init(name: "Seoul", lat: 37.5563, lng: 126.9220, timeZone: "Asia/Seoul"),
        .init(name: "London", lat: 51.5136, lng: -0.1365, timeZone: "Europe/London"),
        .init(name: "Paris", lat: 48.8530, lng: 2.3499, timeZone: "Europe/Paris"),
        .init(name: "Berlin", lat: 52.5200, lng: 13.4050, timeZone: "Europe/Berlin"),
        .init(name: "New York", lat: 40.7306, lng: -73.9866, timeZone: "America/New_York"),
        .init(name: "Chicago", lat: 41.8789, lng: -87.6359, timeZone: "America/Chicago"),
        .init(name: "Los Angeles", lat: 34.0522, lng: -118.2437, timeZone: "America/Los_Angeles"),
        .init(name: "Toronto", lat: 43.6532, lng: -79.3832, timeZone: "America/Toronto"),
        .init(name: "Sydney", lat: -33.8688, lng: 151.2093, timeZone: "Australia/Sydney"),
        .init(name: "Manila", lat: 14.5995, lng: 120.9842, timeZone: "Asia/Manila"),
        .init(name: "São Paulo", lat: -23.5505, lng: -46.6333, timeZone: "America/Sao_Paulo"),
    ]
    static func named(_ name: String) -> DemoCity { all.first { $0.name == name } ?? all[0] }
}

// MARK: - Persistence

enum Persist {
    static func load<T: Decodable>(_ key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return decoded
    }
    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
