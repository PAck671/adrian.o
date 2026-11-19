import Foundation

struct Movie: Identifiable, Codable, Hashable {
    let id: Int
    let title: String
    let year: Int
    let isShow: Bool
    let genres: [String]
    let runtime: Int            // minutes (per episode for shows), 0 = unknown
    let streaming: [String]
    let symbol: String
    let hue: Double
    var posterURL: URL?

    var runtimeText: String {
        guard runtime > 0 else { return "" }
        return isShow ? "\(runtime) min / ep" : "\(runtime / 60)h \(runtime % 60)m"
    }
}

/// Built-in catalog so the Watch tab works offline. Streaming tags are sample availability, not live data.
enum MovieCatalog {
    private static func m(_ id: Int, _ title: String, _ year: Int, _ show: Bool, _ genres: [String], _ runtime: Int,
                          _ streaming: [String], _ symbol: String, _ hue: Double) -> Movie {
        Movie(id: id, title: title, year: year, isShow: show, genres: genres, runtime: runtime,
              streaming: streaming, symbol: symbol, hue: hue)
    }

    static let all: [Movie] = [
        m(1, "Inception", 2010, false, ["Sci-Fi", "Thriller"], 148, ["Netflix"], "brain.head.profile", 0.60),
        m(2, "Spirited Away", 2001, false, ["Animation", "Fantasy"], 125, ["Max"], "wind", 0.45),
        m(3, "La La Land", 2016, false, ["Romance", "Musical"], 128, ["Netflix"], "music.note", 0.75),
        m(4, "Interstellar", 2014, false, ["Sci-Fi", "Drama"], 169, ["Paramount+"], "globe.americas.fill", 0.58),
        m(5, "The Grand Budapest Hotel", 2014, false, ["Comedy"], 99, ["Hulu"], "building.columns.fill", 0.92),
        m(6, "Everything Everywhere All at Once", 2022, false, ["Sci-Fi", "Comedy"], 139, ["Prime Video"], "circle.hexagongrid.fill", 0.82),
        m(7, "Parasite", 2019, false, ["Thriller", "Drama"], 132, ["Max"], "house.fill", 0.15),
        m(8, "Your Name", 2016, false, ["Animation", "Romance"], 106, ["Crunchyroll"], "sparkles", 0.62),
        m(9, "Before Sunrise", 1995, false, ["Romance", "Drama"], 101, ["Max"], "tram.fill", 0.10),
        m(10, "The Princess Bride", 1987, false, ["Adventure", "Comedy"], 98, ["Disney+"], "crown.fill", 0.13),
        m(11, "Pride & Prejudice", 2005, false, ["Romance", "Drama"], 129, ["Peacock"], "envelope.fill", 0.30),
        m(12, "Knives Out", 2019, false, ["Mystery", "Comedy"], 130, ["Prime Video"], "magnifyingglass", 0.05),
        m(13, "Dune", 2021, false, ["Sci-Fi", "Adventure"], 155, ["Max"], "sun.dust.fill", 0.09),
        m(14, "Spider-Man: Into the Spider-Verse", 2018, false, ["Animation", "Action"], 117, ["Netflix"], "figure.climbing", 0.97),
        m(15, "Coco", 2017, false, ["Animation", "Family"], 105, ["Disney+"], "guitars.fill", 0.88),
        m(16, "About Time", 2013, false, ["Romance", "Fantasy"], 123, ["Netflix"], "clock.fill", 0.55),
        m(17, "Mad Max: Fury Road", 2015, false, ["Action"], 120, ["Max"], "car.fill", 0.07),
        m(18, "Get Out", 2017, false, ["Horror", "Thriller"], 104, ["Peacock"], "eye.fill", 0.00),
        m(19, "Amélie", 2001, false, ["Romance", "Comedy"], 122, ["Hulu"], "camera.macro", 0.33),
        m(20, "Top Gun: Maverick", 2022, false, ["Action"], 131, ["Paramount+"], "airplane", 0.57),
        m(21, "The Notebook", 2004, false, ["Romance", "Drama"], 123, ["Netflix"], "book.closed.fill", 0.52),
        m(22, "Past Lives", 2023, false, ["Romance", "Drama"], 105, ["Paramount+"], "airplane.departure", 0.65),
        m(23, "Oppenheimer", 2023, false, ["Drama", "History"], 180, ["Peacock"], "atom", 0.08),
        m(24, "Barbie", 2023, false, ["Comedy", "Fantasy"], 114, ["Max"], "star.fill", 0.90),
        m(25, "Howl's Moving Castle", 2004, false, ["Animation", "Fantasy"], 119, ["Max"], "house.lodge.fill", 0.40),
        m(26, "The Social Network", 2010, false, ["Drama"], 120, ["Netflix"], "network", 0.60),
        m(27, "Crazy Rich Asians", 2018, false, ["Romance", "Comedy"], 120, ["Max"], "sparkle", 0.12),
        m(28, "Arrival", 2016, false, ["Sci-Fi", "Drama"], 116, ["Paramount+"], "circle.dotted", 0.50),
        m(29, "Stranger Things", 2016, true, ["Sci-Fi", "Horror"], 50, ["Netflix"], "bolt.horizontal.fill", 0.98),
        m(30, "The Office", 2005, true, ["Comedy"], 22, ["Peacock"], "paperclip", 0.60),
        m(31, "Friends", 1994, true, ["Comedy"], 22, ["Max"], "cup.and.saucer.fill", 0.08),
        m(32, "The Bear", 2022, true, ["Drama", "Comedy"], 30, ["Hulu"], "frying.pan.fill", 0.04),
        m(33, "Severance", 2022, true, ["Sci-Fi", "Thriller"], 55, ["Apple TV+"], "rectangle.split.3x3.fill", 0.55),
        m(34, "Ted Lasso", 2020, true, ["Comedy", "Sports"], 40, ["Apple TV+"], "soccerball", 0.15),
        m(35, "Bridgerton", 2020, true, ["Romance", "Drama"], 60, ["Netflix"], "fan.fill", 0.80),
        m(36, "Squid Game", 2021, true, ["Thriller"], 55, ["Netflix"], "triangle.fill", 0.95),
        m(37, "The Last of Us", 2023, true, ["Drama", "Horror"], 55, ["Max"], "leaf.fill", 0.25),
        m(38, "Arcane", 2021, true, ["Animation", "Action"], 40, ["Netflix"], "wand.and.stars", 0.70),
        m(39, "Only Murders in the Building", 2021, true, ["Mystery", "Comedy"], 30, ["Hulu"], "building.2.fill", 0.03),
        m(40, "Wednesday", 2022, true, ["Mystery", "Comedy"], 50, ["Netflix"], "hand.raised.fill", 0.75),
        m(41, "Abbott Elementary", 2021, true, ["Comedy"], 22, ["Hulu"], "graduationcap.fill", 0.14),
        m(42, "Shōgun", 2024, true, ["Drama", "History"], 60, ["Hulu"], "shield.fill", 0.02),
        m(43, "Love Is Blind", 2020, true, ["Reality", "Romance"], 50, ["Netflix"], "heart.text.square.fill", 0.93),
        m(44, "The Great British Baking Show", 2010, true, ["Reality"], 60, ["Netflix"], "birthday.cake.fill", 0.35),
        m(45, "Planet Earth II", 2016, true, ["Documentary"], 50, ["Max"], "globe.europe.africa.fill", 0.36),
        m(46, "Brooklyn Nine-Nine", 2013, true, ["Comedy"], 22, ["Peacock"], "star.circle.fill", 0.60),
    ]
}

/// Optional: pulls this week's trending titles when a TMDB key is set in Settings.
enum TMDB {
    private struct Page: Decodable { let results: [Item] }
    private struct Item: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let mediaType: String?
        let releaseDate: String?
        let firstAirDate: String?
        let posterPath: String?
        let genreIds: [Int]?
    }

    private static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
        18: "Drama", 10751: "Family", 14: "Fantasy", 27: "Horror", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 53: "Thriller", 10759: "Action", 10765: "Sci-Fi", 10764: "Reality",
    ]

    /// Accepts a v3 API key or a v4 read-access token.
    static func trending(apiKey: String) async throws -> [Movie] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var comps = URLComponents(string: "https://api.themoviedb.org/3/trending/all/week")
        let isBearer = key.count > 40
        if !isBearer { comps?.queryItems = [URLQueryItem(name: "api_key", value: key)] }
        guard let url = comps?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if isBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Page.self, from: data).results.compactMap { item in
            guard let title = item.title ?? item.name, item.mediaType != "person" else { return nil }
            let show = item.mediaType == "tv"
            return Movie(id: (show ? 2_000_000 : 1_000_000) + item.id, title: title,
                         year: Int((item.releaseDate ?? item.firstAirDate ?? "").prefix(4)) ?? 0, isShow: show,
                         genres: Array((item.genreIds ?? []).compactMap { genreNames[$0] }.prefix(2)),
                         runtime: 0, streaming: [], symbol: show ? "tv.fill" : "film.fill",
                         hue: Double(item.id % 100) / 100,
                         posterURL: item.posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") })
        }
    }
}
