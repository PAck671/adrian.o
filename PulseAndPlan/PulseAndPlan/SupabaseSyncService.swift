import Foundation

/// Live Pair Mode: Supabase REST (PostgREST + Storage) for writes and catch-up, Realtime websocket
/// (Phoenix protocol, postgres_changes + broadcast presence pings) for live delivery.
@MainActor
final class SupabaseSyncService: SyncService {
    private typealias Row = [String: Any]

    enum SyncError: LocalizedError {
        case badURL
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .badURL: "Invalid SUPABASE_URL in Config.swift"
            case let .http(code, body): "HTTP \(code) \(body)"
            }
        }
    }

    var onEvent: ((SyncEvent) -> Void)?
    private let base: URL
    private let key: String
    private let code: String
    private let me: UUID
    private let myName: String
    private var socket: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var reconnectDelay = 2.0
    private var ref = 0
    private var joinRef = "1"
    private var lastPartnerPing = Date.distantPast
    private var partnerOnline = false
    private var stopped = false
    private var topic: String { "realtime:couple-\(code)" }

    private static let tables = ["couples", "pulses", "videos", "movie_swipes", "game_sessions", "events", "locations", "notes", "notices",
                                 "profiles"]

    init?(settings: AppSettings) {
        guard Config.isSupabaseConfigured, let url = URL(string: Config.SUPABASE_URL),
              settings.coupleCode.count == 6 else { return nil }
        base = url
        key = Config.SUPABASE_ANON_KEY
        code = settings.coupleCode.uppercased()
        me = settings.deviceId
        myName = settings.myName
    }

    func start() {
        stopped = false
        emit(.status("Connecting to Supabase…"))
        connect()
        Task { await bootstrap() }
    }

    func stop() {
        stopped = true
        listener?.cancel()
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func emit(_ event: SyncEvent) { onEvent?(event) }

    // MARK: Catch-up over REST

    private func bootstrap() async {
        do {
            try await pair()
            for row in try await rows("pulses", ["seen": "eq.false", "sender_id": "neq.\(me.uuidString)", "order": "created_at.asc"]) {
                if let p = pulse(row) { emit(.pulse(p)) }
            }
            for row in try await rows("videos", ["order": "created_at.desc", "limit": "50"]) {
                if let v = video(row) { emit(.video(v)) }
            }
            for row in try await rows("movie_swipes", [:]) {
                if let s = swipe(row) { emit(.swipe(s)) }
            }
            for row in try await rows("events", [:]) {
                if let e = event(row) { emit(.eventUpserted(e)) }
            }
            for row in try await rows("locations", ["user_id": "neq.\(me.uuidString)"]) {
                if let l = location(row) { emit(.location(l)) }
            }
            for row in try await rows("notes", ["order": "updated_at.asc"]) {
                if let n = note(row) { emit(.noteUpserted(n)) }
            }
            for row in try await rows("profiles", ["user_id": "neq.\(me.uuidString)"]) {
                if let p = profile(row) { emit(.profile(userId: p.0, avatarURL: p.1)) }
            }
            emit(.status("Paired · code \(code)"))
        } catch {
            emit(.status("Sync error: \(error.localizedDescription)"))
        }
    }

    /// First phone to use a code creates the couple; the second claims the partner_b slot.
    private func pair() async throws {
        if let row = try await rows("couples", [:]).first {
            if uuid(row["partner_a"]) != me, row["partner_b"] is NSNull {
                try await send("PATCH", "couples", query: ["code": "eq.\(code)"],
                               body: json(["partner_b": me.uuidString, "partner_b_name": myName]))
            }
            if let v = visit(row) { emit(.visit(v)) }
        } else {
            try await send("POST", "couples", body: json(["code": code, "partner_a": me.uuidString, "partner_a_name": myName]))
        }
    }

    // MARK: Writes

    func sendPulse(_ p: Pulse) {
        write("POST", "pulses", body: ["id": p.id.uuidString, "couple_code": code, "sender_id": me.uuidString,
                                       "pattern": p.pattern.rawValue, "duration": p.duration, "created_at": Self.iso(p.sentAt)])
    }

    func markPulsesSeen(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        write("PATCH", "pulses", query: ["id": "in.(\(ids.map(\.uuidString).joined(separator: ",")))"], body: ["seen": true])
    }

    func sendVideo(_ clip: VideoClip) async throws {
        guard let file = clip.playbackURL else { return }
        let path = "\(code)/\(clip.id.uuidString).mov"
        var request = URLRequest(url: base.appending(path: "storage/v1/object/videos/\(path)"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try check(response, data)
        try await send("POST", "videos", body: json([
            "id": clip.id.uuidString, "couple_code": code, "sender_id": me.uuidString, "storage_path": path,
            "duration": clip.duration, "created_at": Self.iso(clip.createdAt),
        ]))
    }

    func react(clipId: UUID, reaction: String) {
        write("PATCH", "videos", query: ["id": "eq.\(clipId.uuidString)"], body: ["reaction": reaction])
    }

    func sendSwipe(_ s: MovieSwipe) {
        upsert("movie_swipes", conflict: "couple_code,user_id,movie_id",
               ["couple_code": code, "user_id": me.uuidString, "movie_id": s.movieId, "liked": s.liked])
    }

    func sendLocation(_ l: LocationShare) {
        upsert("locations", conflict: "couple_code,user_id", [
            "couple_code": code, "user_id": me.uuidString, "lat": orNull(l.lat), "lng": orNull(l.lng),
            "precision_mode": l.precision.rawValue, "battery_level": orNull(l.battery),
            "place_label": orNull(l.placeLabel), "city": orNull(l.city), "updated_at": Self.iso(l.updatedAt),
            "activity": orNull(l.activity?.rawValue), "speed": orNull(l.speed), "location_off": l.locationOff ?? false,
        ])
    }

    /// Uploads (or replaces) your square profile photo, then points your profiles row at it.
    func sendAvatar(_ jpeg: Data) async throws {
        let path = "\(code)/\(me.uuidString).jpg"
        var request = URLRequest(url: base.appending(path: "storage/v1/object/avatars/\(path)"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await URLSession.shared.upload(for: request, from: jpeg)
        try check(response, data)
        try await send("POST", "profiles", query: ["on_conflict": "couple_code,user_id"],
                       body: json(["couple_code": code, "user_id": me.uuidString, "name": myName,
                                   "avatar_path": path, "updated_at": Self.iso(Date())]),
                       prefer: "resolution=merge-duplicates,return=minimal")
    }

    private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    func saveEvent(_ e: SharedEvent) {
        upsert("events", conflict: "id", [
            "id": e.id.uuidString, "couple_code": code, "title": e.title, "kind": e.kind.rawValue,
            "starts_at": Self.iso(e.start), "ends_at": Self.iso(e.end), "created_by": e.createdBy.uuidString,
        ])
    }

    func deleteEvent(_ id: UUID) {
        write("DELETE", "events", query: ["id": "eq.\(id.uuidString)"], body: nil)
    }

    func sendGame(_ g: GameState) {
        guard let data = try? JSONEncoder().encode(g), let state = try? JSONSerialization.jsonObject(with: data) else { return }
        upsert("game_sessions", conflict: "couple_code,game_code,game", [
            "couple_code": code, "game_code": g.code, "game": g.game.rawValue, "state": state,
            "updated_by": me.uuidString, "updated_at": Self.iso(Date()),
        ])
    }

    func saveVisit(_ v: Visit) {
        write("PATCH", "couples", query: ["code": "eq.\(code)"], body: [
            "visit_date": Self.iso(v.date), "visit_destination": v.destination, "visit_theme": v.theme.rawValue,
        ])
    }

    func sendNotice(_ n: PartnerNotice) {
        write("POST", "notices", body: ["id": n.id.uuidString, "couple_code": code, "sender_id": me.uuidString,
                                        "kind": n.kind.rawValue, "text": n.text, "created_at": Self.iso(n.sentAt)])
    }

    func saveNote(_ n: SharedNote) {
        upsert("notes", conflict: "id", [
            "id": n.id.uuidString, "couple_code": code, "author_id": n.authorId.uuidString, "text": n.text,
            "color": n.color.rawValue, "pinned": n.pinned, "updated_at": Self.iso(n.updatedAt),
        ])
    }

    func deleteNote(_ id: UUID) {
        write("DELETE", "notes", query: ["id": "eq.\(id.uuidString)"], body: nil)
    }

    private func upsert(_ table: String, conflict: String, _ body: Row) {
        write("POST", table, query: ["on_conflict": conflict], body: body, prefer: "resolution=merge-duplicates,return=minimal")
    }

    private func write(_ method: String, _ table: String, query: [String: String] = [:], body: Row?, prefer: String = "return=minimal") {
        let data = body.flatMap(json) // serialize now so only Sendable Data crosses into the task
        Task {
            do { try await send(method, table, query: query, body: data, prefer: prefer) }
            catch { emit(.status("Sync error: \(error.localizedDescription)")) }
        }
    }

    // MARK: REST plumbing

    private func json(_ object: Row) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    private func authorize(_ request: inout URLRequest) {
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SyncError.http(status, String(decoding: data.prefix(200), as: UTF8.self)) }
    }

    @discardableResult
    private func send(_ method: String, _ table: String, query: [String: String] = [:], body: Data? = nil,
                      prefer: String = "return=minimal") async throws -> Data {
        guard var comps = URLComponents(url: base.appending(path: "rest/v1/\(table)"), resolvingAgainstBaseURL: false)
        else { throw SyncError.badURL }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw SyncError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(prefer, forHTTPHeaderField: "Prefer")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    private func rows(_ table: String, _ filters: [String: String]) async throws -> [Row] {
        var query = filters
        query[table == "couples" ? "code" : "couple_code"] = "eq.\(code)"
        query["select"] = "*"
        let data = try await send("GET", table, query: query)
        return (try JSONSerialization.jsonObject(with: data) as? [Row]) ?? []
    }

    // MARK: Realtime websocket

    private func connect() {
        guard !stopped, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        comps.scheme = base.scheme == "http" ? "ws" : "wss"
        comps.path = "/realtime/v1/websocket"
        comps.queryItems = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let url = comps.url else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()

        let changes = Self.tables.map { table in
            ["event": "*", "schema": "public", "table": table,
             "filter": "\(table == "couples" ? "code" : "couple_code")=eq.\(code)"]
        }
        joinRef = String(ref + 1)
        push("phx_join", ["config": ["broadcast": ["self": false], "presence": ["key": ""], "postgres_changes": changes],
                          "access_token": key])

        listener?.cancel()
        listener = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handle(message)
                } catch {
                    self?.scheduleReconnect(from: task)
                    return
                }
            }
        }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                self?.beat()
                try? await Task.sleep(for: .seconds(25))
            }
        }
    }

    private func push(_ event: String, _ payload: Row, topic: String? = nil) {
        ref += 1
        var frame: Row = ["topic": topic ?? self.topic, "event": event, "payload": payload, "ref": String(ref)]
        if topic == nil { frame["join_ref"] = joinRef }
        guard let data = json(frame), let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    /// Phoenix heartbeat + presence ping. Partner counts as online if we heard a ping in the last 70 s.
    private func beat() {
        push("heartbeat", [:], topic: "phoenix")
        push("broadcast", ["type": "broadcast", "event": "ping", "payload": ["sender": me.uuidString]])
        let online = Date().timeIntervalSince(lastPartnerPing) < 70
        if online != partnerOnline {
            partnerOnline = online
            emit(.presence(online: online))
        }
    }

    private func scheduleReconnect(from task: URLSessionWebSocketTask?) {
        guard !stopped, task === socket else { return }
        socket?.cancel()
        socket = nil
        heartbeat?.cancel()
        if partnerOnline {
            partnerOnline = false
            emit(.presence(online: false))
        }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        emit(.status("Realtime offline · retrying in \(Int(delay))s"))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.connect()
            await self?.bootstrap() // pick up anything sent while we were disconnected
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case let .string(text): data = text.data(using: .utf8)
        case let .data(raw): data = raw
        @unknown default: data = nil
        }
        guard let data, let frame = (try? JSONSerialization.jsonObject(with: data)) as? Row,
              let event = frame["event"] as? String, let payload = frame["payload"] as? Row else { return }

        switch event {
        case "phx_reply":
            if payload["status"] as? String == "ok" {
                reconnectDelay = 2
            } else {
                emit(.status("Realtime: \(String(describing: payload["response"] ?? ""))"))
            }
        case "broadcast":
            guard let inner = payload["payload"] as? Row, inner["sender"] as? String != me.uuidString else { return }
            lastPartnerPing = Date()
            if !partnerOnline {
                partnerOnline = true
                emit(.presence(online: true))
            }
        case "postgres_changes":
            guard let change = payload["data"] as? Row, let table = change["table"] as? String,
                  let type = change["type"] as? String else { return }
            if type == "DELETE" {
                guard let id = uuid((change["old_record"] as? Row)?["id"]) else { return }
                if table == "events" { emit(.eventDeleted(id)) }
                if table == "notes" { emit(.noteDeleted(id)) }
            } else if let record = change["record"] as? Row {
                route(table, record)
            }
        case "phx_error", "phx_close":
            scheduleReconnect(from: socket)
        default:
            break
        }
    }

    private func route(_ table: String, _ r: Row) {
        switch table {
        case "pulses":
            if let p = pulse(r), p.senderId != me, r["seen"] as? Bool != true { emit(.pulse(p)) }
        case "videos":
            if let v = video(r) { emit(.video(v)) }
        case "movie_swipes":
            if let s = swipe(r) { emit(.swipe(s)) }
        case "events":
            if let e = event(r) { emit(.eventUpserted(e)) }
        case "locations":
            if let l = location(r), l.userId != me { emit(.location(l)) }
        case "game_sessions":
            if let g = game(r), g.updatedBy != me { emit(.game(g)) }
        case "couples":
            if let v = visit(r) { emit(.visit(v)) }
        case "notes":
            if let n = note(r) { emit(.noteUpserted(n)) }
        case "notices":
            if let n = notice(r), n.senderId != me, Date().timeIntervalSince(n.sentAt) < 600 { emit(.notice(n)) }
        case "profiles":
            if let p = profile(r), p.0 != me { emit(.profile(userId: p.0, avatarURL: p.1)) }
        default:
            break
        }
    }

    private func note(_ r: Row) -> SharedNote? {
        guard let id = uuid(r["id"]), let author = uuid(r["author_id"]), let text = r["text"] as? String else { return nil }
        return SharedNote(id: id, text: text, color: (r["color"] as? String).flatMap(NoteColor.init(rawValue:)) ?? .yellow,
                          pinned: r["pinned"] as? Bool ?? false, authorId: author, updatedAt: date(r["updated_at"]) ?? Date())
    }

    /// Public avatar URL, versioned by updated_at so a new photo isn't served from cache.
    private func profile(_ r: Row) -> (UUID, URL)? {
        guard let user = uuid(r["user_id"]), let path = r["avatar_path"] as? String else { return nil }
        let version = Int(date(r["updated_at"])?.timeIntervalSince1970 ?? 0)
        let url = base.appending(path: "storage/v1/object/public/avatars/\(path)")
            .appending(queryItems: [URLQueryItem(name: "v", value: String(version))])
        return (user, url)
    }

    private func notice(_ r: Row) -> PartnerNotice? {
        guard let id = uuid(r["id"]), let sender = uuid(r["sender_id"]), let text = r["text"] as? String else { return nil }
        return PartnerNotice(id: id, senderId: sender, kind: (r["kind"] as? String).flatMap(NoticeKind.init(rawValue:)) ?? .custom,
                             text: text, sentAt: date(r["created_at"]) ?? Date())
    }

    // MARK: Row decoding

    private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private func date(_ value: Any?) -> Date? { (value as? String).flatMap(Self.parseDate) }
    private func number(_ value: Any?) -> NSNumber? { value as? NSNumber }

    private func pulse(_ r: Row) -> Pulse? {
        guard let id = uuid(r["id"]), let sender = uuid(r["sender_id"]),
              let pattern = (r["pattern"] as? String).flatMap(PulsePattern.init(rawValue:)) else { return nil }
        return Pulse(id: id, senderId: sender, pattern: pattern, duration: number(r["duration"])?.doubleValue ?? 0,
                     sentAt: date(r["created_at"]) ?? Date())
    }

    private func video(_ r: Row) -> VideoClip? {
        guard let id = uuid(r["id"]), let sender = uuid(r["sender_id"]), let path = r["storage_path"] as? String else { return nil }
        return VideoClip(id: id, senderId: sender, localName: nil,
                         remoteURL: base.appending(path: "storage/v1/object/public/videos/\(path)"),
                         createdAt: date(r["created_at"]) ?? Date(), duration: number(r["duration"])?.doubleValue ?? 0,
                         reaction: r["reaction"] as? String)
    }

    private func swipe(_ r: Row) -> MovieSwipe? {
        guard let user = uuid(r["user_id"]), let movie = number(r["movie_id"])?.intValue, let liked = r["liked"] as? Bool else { return nil }
        return MovieSwipe(userId: user, movieId: movie, liked: liked)
    }

    private func event(_ r: Row) -> SharedEvent? {
        guard let id = uuid(r["id"]), let title = r["title"] as? String,
              let kind = (r["kind"] as? String).flatMap(EventKind.init(rawValue:)),
              let start = date(r["starts_at"]), let end = date(r["ends_at"]), let by = uuid(r["created_by"]) else { return nil }
        return SharedEvent(id: id, title: title, kind: kind, start: start, end: end, createdBy: by)
    }

    private func location(_ r: Row) -> LocationShare? {
        guard let user = uuid(r["user_id"]),
              let precision = (r["precision_mode"] as? String).flatMap(PrecisionMode.init(rawValue:)) else { return nil }
        return LocationShare(userId: user, lat: number(r["lat"])?.doubleValue, lng: number(r["lng"])?.doubleValue,
                             precision: precision, battery: number(r["battery_level"])?.intValue,
                             placeLabel: r["place_label"] as? String, city: r["city"] as? String,
                             updatedAt: date(r["updated_at"]) ?? Date(),
                             activity: (r["activity"] as? String).flatMap(PartnerActivity.init(rawValue:)),
                             speed: number(r["speed"])?.doubleValue, locationOff: r["location_off"] as? Bool)
    }

    private func game(_ r: Row) -> GameState? {
        guard let state = r["state"], let data = try? JSONSerialization.data(withJSONObject: state) else { return nil }
        return try? JSONDecoder().decode(GameState.self, from: data)
    }

    private func visit(_ r: Row) -> Visit? {
        guard let when = date(r["visit_date"]) else { return nil }
        return Visit(date: when, destination: r["visit_destination"] as? String ?? "",
                     theme: (r["visit_theme"] as? String).flatMap(VisitTheme.init(rawValue:)) ?? .sunset)
    }

    // MARK: Dates

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Accepts Postgres/PostgREST/Realtime timestamp shapes: microseconds, "+00", space separator.
    nonisolated static func parseDate(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: " ", with: "T")
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = String(s[r].dropFirst().prefix(3))
            s.replaceSubrange(r, with: "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        if s.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil { s += ":00" }
        if !s.hasSuffix("Z"), s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil { s += "Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: s)
    }
}
