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
            location.keepAlive = settings.stayConnected
            if settings.shareActivity != oldValue.shareActivity { resumeSharingIfNeeded() }
        }
    }
    var theme: ThemeSettings = Persist.load("theme", default: ThemeSettings()) { didSet { Persist.save(theme, "theme") } }
    var backgroundImage: UIImage? = UIImage(contentsOfFile: ThemeSettings.photoURL.path())
    var notes: [SharedNote] = Persist.load("notes", default: []) { didSet { Persist.save(notes, "notes") } }
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
    var toast: String?
    var messageDraft: MessageDraft?
    private(set) var isActive = true

    var myPhoto: UIImage? = UIImage(contentsOfFile: AppState.photoURL(me: true).path())
    var partnerPhoto: UIImage? = UIImage(contentsOfFile: AppState.photoURL(me: false).path())

    let haptics = HapticEngine()
    let location = LocationManager()
    let motion = MotionSense()
    let calendar = CalendarBridge()
    @ObservationIgnored private var reportedLocationOff = false
    @ObservationIgnored private var diedAlerted = false
    @ObservationIgnored private var sync: SyncService?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var simulatedMissed = false
    @ObservationIgnored private var batteryBucket = 100
    @ObservationIgnored private var lastArrivalAlert: [String: Date] = [:]
    @ObservationIgnored private var wasNearby = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        location.onUpdate = { [weak self] location in
            guard let self else { return }
            self.motion.updateSpeed(location.speed)
            if !self.motion.running { self.updateTracking(speed: location.speed) } // no motion data: go by GPS speed
            self.publish(location)
        }
        location.onAuthorizationChange = { [weak self] in self?.authorizationChanged($0) }
        motion.onChange = { [weak self] activity in
            guard let self else { return }
            self.updateTracking(activity: activity)
            if let last = self.location.lastLocation { self.publish(last) } // posture changes never move the phone
        }
        location.keepAlive = settings.stayConnected
        restartSync()
        resumeSharingIfNeeded()
        Task {
            _ = await Notifier.requestPermission()
            if settings.syncCalendar { _ = await importCalendarBusy() }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.checkPartnerWentQuiet()
            }
        }
    }

    // MARK: Location off / Ghost (so the partner is told)

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        guard settings.sharingEnabled, settings.precision != .ghost else { return }
        if status == .denied || status == .restricted {
            reportLocationOff()
        } else if reportedLocationOff, status == .authorizedWhenInUse || status == .authorizedAlways {
            reportedLocationOff = false
            resumeSharingIfNeeded()
        }
    }

    /// Location Services just went off: tell the partner before iOS suspends us (a background task buys a few seconds).
    private func reportLocationOff() {
        guard !reportedLocationOff else { return }
        reportedLocationOff = true
        motion.stop()
        let task = UIApplication.shared.beginBackgroundTask(withName: "location-off", expirationHandler: nil)
        sync?.sendLocation(LocationShare(userId: settings.deviceId, precision: settings.precision, battery: batteryPercent, locationOff: true))
        Task {
            try? await Task.sleep(for: .seconds(8))
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// Life360-style "phone probably died": low battery, then silence.
    private func checkPartnerWentQuiet() {
        guard settings.alertBattery, !diedAlerted, let loc = partnerLocation, loc.precision != .ghost, loc.locationOff != true,
              let battery = loc.battery, battery <= 10 else { return }
        let quiet = Date().timeIntervalSince(loc.updatedAt)
        guard quiet > 15 * 60 else { return }
        diedAlerted = true
        alert("🪫 \(settings.partnerName)'s phone probably died", "Last seen at \(battery)%, \(Int(quiet / 60)) min ago.")
    }

    // MARK: Profile photos

    nonisolated static func photoURL(me: Bool) -> URL {
        URL.documentsDirectory.appending(path: me ? "avatar-me.jpg" : "avatar-partner.jpg")
    }

    /// Center-crops to a 512 px square JPEG (small enough to sync quickly).
    static func squareJPEG(_ image: UIImage, side: CGFloat = 512) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }

    /// `me == false` sets the partner's photo on this phone only (their own upload replaces it in Live mode).
    func setPhoto(_ data: Data, me: Bool) {
        guard let image = UIImage(data: data), let jpeg = Self.squareJPEG(image) else { return showToast("That image couldn't be read.") }
        do {
            try jpeg.write(to: Self.photoURL(me: me), options: .atomic)
        } catch {
            return showToast("Couldn't save the photo: \(error.localizedDescription)")
        }
        if me {
            myPhoto = UIImage(data: jpeg)
            Task {
                do { try await sync?.sendAvatar(jpeg) } catch { showToast("Photo saved here, but upload failed: \(error.localizedDescription)") }
            }
        } else {
            partnerPhoto = UIImage(data: jpeg)
        }
    }

    func removePhoto(me: Bool) {
        try? FileManager.default.removeItem(at: Self.photoURL(me: me))
        if me { myPhoto = nil } else { partnerPhoto = nil }
    }

    private func downloadPartnerPhoto(_ url: URL) {
        guard UserDefaults.standard.string(forKey: "partnerPhotoSource") != url.absoluteString else { return }
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return }
            try? data.write(to: Self.photoURL(me: false), options: .atomic)
            partnerPhoto = image
            UserDefaults.standard.set(url.absoluteString, forKey: "partnerPhotoSource")
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { resumeSharingIfNeeded() } else { didEnterBackground() }
    }

    /// In-app toast while open, local notification (with the system buzz) while in the background.
    func alert(_ title: String, _ body: String) {
        if isActive {
            showToast("\(title)\n\(body)")
        } else {
            Notifier.post(title: title, body: body)
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    /// App became active (a foreground moment, so iOS allows starting location updates).
    func resumeSharingIfNeeded() {
        guard settings.sharingEnabled, settings.precision != .ghost else { return }
        if location.isDenied { return reportLocationOff() } // turned off while we were suspended
        if !location.isUpdating { location.start() }
        if settings.shareActivity { motion.start() } else { motion.stop() }
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
                                         sendWelcomeClip: !clips.contains { isPartner($0.senderId) },
                                         seedNote: !notes.contains { isPartner($0.authorId) })
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
            checkPartnerAlerts(old: partnerLocation, new: l)
            partnerLocation = l
            diedAlerted = false
        case let .profile(userId, url):
            if isPartner(userId) { downloadPartnerPhoto(url) }
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
        case let .notice(n):
            guard isPartner(n.senderId) else { return }
            alert(n.kind == .onMyWay ? "🚗 \(settings.partnerName) is on the way" : "💬 \(settings.partnerName)", n.text)
        case let .noteUpserted(note):
            if let i = notes.firstIndex(where: { $0.id == note.id }) {
                notes[i] = note
            } else {
                notes.append(note)
                if isPartner(note.authorId) { alert("📝 \(settings.partnerName) shared a note", String(note.text.prefix(80))) }
            }
        case let .noteDeleted(id):
            notes.removeAll { $0.id == id }
        }
    }

    // MARK: Partner alerts (battery, arrivals, nearby)

    private func checkPartnerAlerts(old: LocationShare?, new: LocationShare) {
        let name = settings.partnerName
        if let level = new.battery {
            let bucket = level <= 5 ? 5 : level <= 15 ? 15 : 100
            if settings.alertBattery, bucket < batteryBucket {
                alert("🔋 \(name)'s phone is at \(level)%", bucket == 5 ? "It's about to die." : "Their battery is getting low.")
            }
            batteryBucket = bucket
        }
        guard old != nil else { return } // first fix after launch is not an arrival
        if settings.alertPrivacy {
            let wasHidden = old?.precision == .ghost || old?.locationOff == true
            if new.locationOff == true, old?.locationOff != true {
                alert("⚠️ \(name) turned off location", "Location Services are off on their phone, so their pin won't update.")
            } else if new.precision == .ghost, old?.precision != .ghost {
                alert("👻 \(name) went Ghost", "They paused location sharing.")
            } else if wasHidden, new.precision != .ghost, new.locationOff != true {
                alert("📍 \(name) is sharing again", new.placeLabel ?? new.city ?? "Their pin is back on the map.")
            }
        }
        if settings.alertArrivals, let place = new.placeLabel, place != old?.placeLabel,
           Date().timeIntervalSince(lastArrivalAlert[place] ?? .distantPast) > 600 {
            lastArrivalAlert[place] = Date()
            alert("📍 \(name) arrived", "\(name) is \(place.lowercased().hasPrefix("at ") ? place.lowercased() : place).")
        }
        if let me = myCoordinate, let them = new.coordinate {
            let near = me.distance(to: them) < 1000
            if settings.alertNearby, near, !wasNearby { alert("💞 \(name) is nearby", "Less than \(formatDistance(1000, miles: settings.useMiles)) away.") }
            wasNearby = near
        }
    }

    /// Schedules sample notifications so you can lock the phone and see how alerts look.
    func sendTestAlerts() {
        let name = settings.partnerName
        Notifier.post(title: "💓 \(name) sent a Heartbeat", body: "Open Red Thread to feel it.", after: 5)
        Notifier.post(title: "🔋 \(name)'s phone is at 12%", body: "Their battery is getting low.", after: 8)
        Notifier.post(title: "📍 \(name) arrived", body: "\(name) is at home.", after: 11)
        Notifier.post(title: "👻 \(name) went Ghost", body: "They paused location sharing.", after: 14)
        Notifier.post(title: "⚠️ \(name) turned off location", body: "Location Services are off on their phone.", after: 17)
        showToast("Lock your phone: 5 test alerts arrive in 5–17 s")
        (sync as? DemoPartnerService)?.simulateGhost(after: 25, for: 20) // and a real in-app Ghost alert in Demo mode
    }

    // MARK: On my way & iMessage

    func sendOnMyWay() async -> String {
        var text = "On my way to you"
        if let me = myCoordinate, let them = partnerLocation?.coordinate {
            if let eta = await TravelTime.eta(from: me, to: them) {
                text += " · about \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))"
            } else {
                text += " · \(formatDistance(me.distance(to: them), miles: settings.useMiles)) to go"
            }
        }
        sync?.sendNotice(PartnerNotice(senderId: settings.deviceId, kind: .onMyWay, text: text))
        showToast("Sent to \(settings.partnerName): \(text)")
        return text
    }

    func textPartner(_ body: String) { messageDraft = MessageDraft(body: body) }

    // MARK: Notes

    func saveNote(_ note: SharedNote) {
        var note = note
        note.updatedAt = Date()
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.append(note) }
        sync?.saveNote(note)
    }

    func deleteNote(_ note: SharedNote) {
        notes.removeAll { $0.id == note.id }
        sync?.deleteNote(note.id)
    }

    // MARK: Calendar

    /// Replaces your previously imported busy blocks with the next 14 days from the phone's calendars.
    /// Returns how many were imported, or nil without calendar access.
    func importCalendarBusy() async -> Int? {
        guard await calendar.requestAccess() else { return nil }
        let me = settings.deviceId
        for old in events where old.fromCalendar == true && old.createdBy == me { deleteEvent(old) }
        let intervals = calendar.busyIntervals(from: Calendar.current.startOfDay(for: Date()), days: 14)
        for interval in intervals {
            saveEvent(SharedEvent(title: "Busy", kind: .busy, start: interval.start, end: interval.end, createdBy: me, fromCalendar: true))
        }
        settings.syncCalendar = true
        return intervals.count
    }

    func addToCalendar(_ event: SharedEvent) async {
        guard await calendar.requestAccess() else { return showToast("Allow calendar access in iOS Settings first.") }
        do {
            try calendar.add(event, partnerName: settings.partnerName)
            showToast("Added \"\(event.title)\" to your calendar")
        } catch {
            showToast("Couldn't add it: \(error.localizedDescription)")
        }
    }

    // MARK: Appearance

    func setBackgroundPhoto(_ data: Data) {
        guard let image = UIImage(data: data) else { return showToast("That image couldn't be read.") }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = image.preparingThumbnail(of: size) ?? image
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        do {
            try jpeg.write(to: ThemeSettings.photoURL, options: .atomic)
            backgroundImage = resized
            theme.effect = .photo
        } catch {
            showToast("Couldn't save the photo: \(error.localizedDescription)")
        }
    }

    // MARK: Pulses

    func sendPulse(_ pattern: PulsePattern, duration: Double = 0) {
        sync?.sendPulse(Pulse(senderId: settings.deviceId, pattern: pattern, duration: duration))
    }

    private func receive(_ p: Pulse) {
        guard isPartner(p.senderId), !missedPulses.contains(where: { $0.id == p.id }) else { return }
        if Date().timeIntervalSince(p.sentAt) > 30 || !isActive {
            // Late (sent while offline) or app in background, where iOS won't play Core Haptics: keep it for later.
            missedPulses.append(p)
            if !isActive, settings.alertPulses {
                Notifier.post(title: "💓 \(settings.partnerName) sent a \(p.pattern.label)", body: "Open Red Thread to feel it.")
            }
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
            motion.stop()
            location.setTracking(.battery)
            sync?.sendLocation(LocationShare(userId: settings.deviceId, precision: .ghost))
        } else {
            settings.sharingEnabled = true
            location.start()
            if settings.shareActivity { motion.start() }
            updateTracking(activity: motion.activity)
            if let last = location.lastLocation { publish(last) }
        }
    }

    /// Precise GPS only in Live mode and only while moving; Fuzzy never needs better than 100 m.
    private func updateTracking(activity: PartnerActivity?) {
        guard settings.precision == .live else { return location.setTracking(.battery) }
        switch activity {
        case .walking?, .running?, .cycling?: location.setTracking(.walking)
        case .driving?, .train?: location.setTracking(.vehicle)
        default: location.setTracking(.battery) // still, or flying (GPS is useless in a plane)
        }
    }

    private func updateTracking(speed: Double) {
        guard speed >= 0 else { return }
        updateTracking(activity: speed > 7 ? .driving : speed > 0.8 ? .walking : nil)
    }

    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var trailingPublish: Task<Void, Never>?

    /// At most one write every 2 s while moving fast; the last fix is always sent (trailing edge).
    private func publish(_ loc: CLLocation) {
        trailingPublish?.cancel()
        let wait = 2 - Date().timeIntervalSince(lastPublish)
        guard wait > 0 else { return sendShare(loc) }
        trailingPublish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.sendShare(loc)
        }
    }

    private func sendShare(_ loc: CLLocation) {
        let mode = settings.precision
        guard mode != .ghost else { return }
        lastPublish = Date()
        let coord = mode == .fuzzy ? loc.coordinate.fuzzed() : loc.coordinate
        // Fuzzy hides saved-place badges and the neighborhood: they would undo the 3 km blur.
        let place = mode == .live ? savedPlaces.first { $0.coordinate.distance(to: loc.coordinate) <= $0.radius } : nil
        let city = mode == .fuzzy ? location.placeName?.components(separatedBy: ", ").last : location.placeName
        // Speed only in Live mode (it would hint at the route); stale GPS speeds are dropped.
        let speed = mode == .live && loc.speed >= 0 && Date().timeIntervalSince(loc.timestamp) < 60 ? loc.speed : nil
        sync?.sendLocation(LocationShare(userId: settings.deviceId, lat: coord.latitude, lng: coord.longitude,
                                         precision: mode, battery: batteryPercent,
                                         placeLabel: place.map { "At \($0.name)" }, city: city,
                                         activity: settings.shareActivity ? motion.activity : nil, speed: speed,
                                         course: mode == .live && loc.course >= 0 ? loc.course : nil,
                                         accuracy: mode == .live ? loc.horizontalAccuracy : nil))
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
