import Foundation

struct TVApp: Identifiable, Hashable {
    let component: String
    let name: String
    var id: String { component }
}

/// Builds every command sent to the TV, so all user text passes through one quoting path.
enum TVCommands {
    enum Key {
        static let home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, ok = 23
        static let volumeUp = 24, volumeDown = 25, power = 26, enter = 66, delete = 67
        static let playPause = 85, rewind = 89, forward = 90, mute = 164, wakeup = 224
    }

    enum LinkAction: Equatable {
        case app(String), media(String), open
    }

    static let quickPanel = "cmd input keyevent --longpress 3"
    static let listApps = "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER"
    static let settings = "am start -a android.settings.SETTINGS"
    static let library = "am start -n com.google.android.videos/.tv.presenter.activity.TvLauncherActivity"
    static let syncTuner = "am start -a com.google.android.chromecast.chromecastservice.sliceprovider.SHOW_AUDIO_AV_SYNC_TUNING_WARNING -n com.droidlogic.tv.settings/.sliceprovider.dialog.AVSyncTuningActivity"

    private static let hiddenPackages: Set<String> = ["com.android.tv.settings", "com.android.vending"]
    private static let names: [String: String] = [
        "com.amazon.amazonvideo.livingroom": "Prime Video",
        "com.apple.atve.androidtv.appletv": "Apple TV",
        "com.cbs.ott": "Paramount+",
        "com.disney.disneyplus": "Disney+",
        "com.espn.score_center": "ESPN",
        "com.goodtoolapps.zeus": "Zeus",
        "com.google.android.videos": "Google TV Library",
        "com.google.android.youtube.tv": "YouTube",
        "com.google.android.youtube.tvunplugged": "YouTube TV",
        "com.hulu.livingroomplus": "Hulu",
        "com.nbaimd.gametime.nba2011": "NBA",
        "com.netflix.ninja": "Netflix",
        "com.peacocktv.peacockandroid": "Peacock",
        "com.playstation.remoteplay.tv": "PS Remote Play",
        "com.spotify.tv.android": "Spotify",
        "com.tubitv": "Tubi",
        "com.wbd.stream": "HBO Max",
        "tv.pluto.android": "Pluto TV",
        "org.smarttube.stable": "SmartTube",
        "org.localsend.localsend_app": "LocalSend",
    ]
    private static let mediaTypes: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mkv": "video/x-matroska",
        "m3u8": "application/x-mpegURL", "mpd": "application/dash+xml",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "flac": "audio/flac", "ogg": "audio/ogg",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
    ]

    static func key(_ code: Int) -> String { "cmd input keyevent \(code)" }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func launch(_ app: TVApp) -> String? {
        isComponent(app.component) ? "am start -n \(quote(app.component))" : nil
    }

    static func search(_ query: String) -> String {
        "am start -a android.search.action.GLOBAL_SEARCH --es query \(quote(oneLine(query)))"
    }

    // shortcut: Android's `input text` only types ASCII, upgrade with a helper IME if accents or emoji are needed.
    static func inputText(_ text: String) -> String? {
        let ascii = oneLine(text).filter(\.isASCII)
        guard !ascii.isEmpty else { return nil }
        return "cmd input text \(quote(ascii.replacingOccurrences(of: " ", with: "%s")))"
    }

    static func openLink(_ url: URL, package: String? = nil) -> String {
        var command = "am start -a android.intent.action.VIEW -d \(quote(url.absoluteString))"
        if let package { command += " \(quote(package))" }
        return command
    }

    static func classify(_ url: URL) -> LinkAction? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            return .app("com.google.android.youtube.tv")
        }
        if host == "netflix.com" || host.hasSuffix(".netflix.com") { return .app("com.netflix.ninja") }
        if let type = mediaTypes[url.pathExtension.lowercased()] { return .media(type) }
        return .open
    }

    // The official YouTube app can be disabled in favor of another installed app that opens the same links.
    static func linkPackage(_ package: String, enabled: String) -> String? {
        let installed = Set(enabled.split(whereSeparator: \.isNewline).map {
            $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces)
        })
        if installed.contains(package) { return package }
        if package == "com.google.android.youtube.tv", installed.contains("org.smarttube.stable") {
            return "org.smarttube.stable"
        }
        return nil
    }

    static func isPrivateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part).flatMap { $0 <= 255 ? $0 : nil }
        }
        guard parts.count == 4, octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    static func parseApps(_ output: String) -> [TVApp] {
        var seen = Set<String>()
        var apps: [TVApp] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard isComponent(line) else { continue }
            let package = String(line.prefix { $0 != "/" })
            guard !hiddenPackages.contains(package), seen.insert(package).inserted else { continue }
            apps.append(TVApp(component: line, name: names[package] ?? fallbackName(package)))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isComponent(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$"#, options: .regularExpression) != nil
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func fallbackName(_ package: String) -> String {
        (package.split(separator: ".").last.map(String.init) ?? package).capitalized
    }
}
