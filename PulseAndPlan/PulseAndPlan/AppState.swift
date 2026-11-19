import SwiftUI
import Observation
@preconcurrency import CoreLocation

/// Single source of truth. Views read it from the environment; every outbound change goes through `sync`.
@Observable
@MainActor
final class AppState {
    var settings: AppSettings = Persist.load("settings", default: AppSettings()) {
        didSet {
            Persist.save(settings, "settings")
            if settings.mode != oldValue.mode || settings.coupleCode != oldValue.coupleCode
                || settings.demoCity != oldValue.demoCity {
                restartSync()
            }
        }
    }
    var missedPulses: [Pulse] = Persist.load("missedPulses", default: []) { didSet { Persist.save(missedPulses, "missedPulses") } }
    var clips: [VideoClip] = Persist.load("clips", default: []) { didSet { Persist.save(clips, "clips") } }
    var mySwipes: [Int: Bool] = Persist.load("mySwipes", default: [:]) { didSet { Persist.save(mySwipes, "mySwipes") } }
    var partnerSwipes: [Int: Bool] = Persist.load("partnerSwipes", default: [:]) { didSet { Persist.save(partnerSwipes, "partnerSwipes") } }
    var queue: [Int] = Persist.load("queue", default: []) { didSet { Persist.save(queue, "queue") } }
    var extraMovies: [Movie] = Persist.load("tmdbMovies", default: []) { didSet { Persist.save(extraMovies, "tmdbMovies") } }
    var events: [SharedEvent] = Persist.load("events", default: []) { didSet { Persist.save(events, "events") } }
    var savedPlaces: [SavedPlace] = Persist.load("savedPlaces", default: []) { didSet { Persist.save(savedPlaces, "savedPlaces") } }
    var visit: Visit = Persist.load("visit", default: Visit()) { didSet { Persist.save(visit, "visit") } }
    var partnerLocation: LocationShare? = Persist.load("partnerLocation", default: nil) { didSet { Persist.save(partnerLocation, "partnerLocation") } }
    var gameStates: [String: GameState] = [:]

    // Transient UI state
    var partnerOnline = false
    var syncStatus = ""
    var lastIncomingPulse: Pulse?
    var match: Movie?

    let haptics = HapticEngine()
    let location = LocationManager()
    @ObservationIgnored private var sync: SyncService?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var simulatedMissed = false

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        location.onUpdate = { [weak self] in self?.publish($0) }
        restartSync()
        resumeSharingIfNeeded()
    }

    /// App became active (a foreground moment, so iOS allows starting location updates).
    func resumeSharingIfNeeded() {
        if settings.sharingEnabled, settings.precision != .ghost, !location.isUpdating { location.start() }
    }

    func didEnterBackground() { UserDefaults.standard.set(Date(), forKey: "lastActive") }

    func restartSync() {
        sync?.stop()
        sync = nil
        partnerOnline = false
        let service: SyncService
        switch settings.mode {
        case .demo:
            let lastActive = UserDefaults.standard.object(forKey: "lastActive") as? Date ?? .distantPast
            service = DemoPartnerService(city: DemoCity.named(settings.demoCity), partnerName: settings.partnerName,
                                         missedSince: simulatedMissed ? nil : lastActive,
                                         sendWelcomeClip: !clips.contains { isPartner($0.senderId) })
            simulatedMissed = true
        case .live:
            guard let live = SupabaseSyncService(settings: settings) else {
                syncStatus = Config.isSupabaseConfigured ? "Enter a 6-character couple code in Settings"
                                                         : "Add SUPABASE_URL and SUPABASE_ANON_KEY in Config.swift"
                return
            }
            service = live
        }
        service.onEvent = { [weak self] in self?.handle($0) }
        sync = service
        service.start()
    }

    func isPartner(_ id: UUID) -> Bool { id != settings.deviceId }

    private func handle(_ event: SyncEvent) {
        switch event {
        case let .pulse(p):
            receive(p)
        case let .video(clip):
            if let i = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[i].reaction = clip.reaction // keep our local file; take the partner's reaction
            } else {
                clips.append(clip)
                clips.sort { $0.createdAt < $1.createdAt }
            }
        case let .swipe(s):
            guard isPartner(s.userId) else { return }
            partnerSwipes[s.movieId] = s.liked
            checkMatch(s.movieId)
        case let .location(l):
            partnerLocation = l
        case let .eventUpserted(e):
            if let i = events.firstIndex(where: { $0.id == e.id }) { events[i] = e } else { events.append(e) }
        case let .eventDeleted(id):
            events.removeAll { $0.id == id }
        case let .game(g):
            gameStates[Self.gameKey(g.code, g.game)] = g
        case let .visit(v):
            visit = v
        case let .presence(online):
            partnerOnline = online
        case let .status(text):
            syncStatus = text
        }
    }

    // MARK: Pulses

    func sendPulse(_ pattern: PulsePattern, duration: Double = 0) {
        sync?.sendPulse(Pulse(senderId: settings.deviceId, pattern: pattern, duration: duration))
    }

    private func receive(_ p: Pulse) {
        guard isPartner(p.senderId), !missedPulses.contains(where: { $0.id == p.id }) else { return }
        if Date().timeIntervalSince(p.sentAt) > 30 {
            missedPulses.append(p) // delivered late → it was sent while we were offline
        } else {
            haptics.play(p.pattern, duration: p.duration)
            lastIncomingPulse = p
            sync?.markPulsesSeen([p.id])
        }
    }

    func playMissed(_ p: Pulse) {
        haptics.play(p.pattern, duration: p.duration)
        lastIncomingPulse = p
        missedPulses.removeAll { $0.id == p.id }
        sync?.markPulsesSeen([p.id])
    }

    func clearMissed() {
        sync?.markPulsesSeen(missedPulses.map(\.id))
        missedPulses = []
    }

    // MARK: Videos

    func sendClip(localName: String, duration: Double) async {
        let clip = VideoClip(senderId: settings.deviceId, localName: localName, duration: duration)
        clips.append(clip)
        do { try await sync?.sendVideo(clip) } catch { syncStatus = "Video upload failed: \(error.localizedDescription)" }
    }

    func react(_ clip: VideoClip, _ emoji: String) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[i].reaction = emoji
        sync?.react(clipId: clip.id, reaction: emoji)
    }

    // MARK: Movies

    var allMovies: [Movie] { MovieCatalog.all + extraMovies }
    var deck: [Movie] { allMovies.filter { mySwipes[$0.id] == nil } }
    func movie(_ id: Int) -> Movie? { allMovies.first { $0.id == id } }

    func swipe(_ movie: Movie, liked: Bool) {
        mySwipes[movie.id] = liked
        sync?.sendSwipe(MovieSwipe(userId: settings.deviceId, movieId: movie.id, liked: liked))
        checkMatch(movie.id)
    }

    private func checkMatch(_ id: Int) {
        guard mySwipes[id] == true, partnerSwipes[id] == true, !queue.contains(id) else { return }
        queue.append(id)
        match = movie(id)
        haptics.success()
    }

    // MARK: Location

    var batteryPercent: Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    /// Called from the precision pill (a foreground tap).
    func setPrecision(_ mode: PrecisionMode) {
        settings.precision = mode
        if mode == .ghost {
            location.stop()
            sync?.sendLocation(LocationShare(userId: settings.deviceId, precision: .ghost))
        } else {
            settings.sharingEnabled = true
            location.start()
            if let last = location.lastLocation { publish(last) }
        }
    }

    private func publish(_ loc: CLLocation) {
        let mode = settings.precision
        guard mode != .ghost else { return }
        let coord = mode == .fuzzy ? loc.coordinate.fuzzed() : loc.coordinate
        // Fuzzy hides saved-place badges and the neighborhood: they would undo the 3 km blur.
        let place = mode == .live ? savedPlaces.first { $0.coordinate.distance(to: loc.coordinate) <= $0.radius } : nil
        let city = mode == .fuzzy ? location.placeName?.components(separatedBy: ", ").last : location.placeName
        sync?.sendLocation(LocationShare(userId: settings.deviceId, lat: coord.latitude, lng: coord.longitude,
                                         precision: mode, battery: batteryPercent,
                                         placeLabel: place.map { "At \($0.name)" }, city: city))
    }

    var myCoordinate: CLLocationCoordinate2D? { location.lastLocation?.coordinate }

    var distanceMeters: CLLocationDistance? {
        guard let me = myCoordinate, let partner = partnerLocation?.coordinate else { return nil }
        return me.distance(to: partner)
    }

    // MARK: Calendar

    var myTZ: TimeZone { TimeZone(identifier: settings.myTimeZone) ?? .current }
    var partnerTZ: TimeZone { TimeZone(identifier: settings.partnerTimeZone) ?? .current }

    func saveEvent(_ e: SharedEvent) {
        if let i = events.firstIndex(where: { $0.id == e.id }) { events[i] = e } else { events.append(e) }
        sync?.saveEvent(e)
    }

    func deleteEvent(_ e: SharedEvent) {
        events.removeAll { $0.id == e.id }
        sync?.deleteEvent(e.id)
    }

    func saveVisit(_ v: Visit) {
        visit = v
        sync?.saveVisit(v)
    }

    // MARK: Games

    static func gameKey(_ code: String, _ game: GameKind) -> String { "\(game.rawValue)-\(code.uppercased())" }

    func gameState(code: String, game: GameKind) -> GameState {
        gameStates[Self.gameKey(code, game)] ?? GameState(code: code.uppercased(), game: game, updatedBy: settings.deviceId)
    }

    func updateGame(_ state: GameState) {
        var state = state
        state.updatedBy = settings.deviceId
        gameStates[Self.gameKey(state.code, state.game)] = state
        sync?.sendGame(state)
    }
}
